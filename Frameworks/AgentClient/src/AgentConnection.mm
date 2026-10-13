#import "AgentConnection.h"
#import <fcntl.h>
#import <signal.h>
#import <atomic>

NSErrorDomain const AgentConnectionErrorDomain = @"AgentConnectionErrorDomain";
NSErrorDomain const AgentJSONRPCErrorDomain    = @"AgentJSONRPCErrorDomain";
NSString* const AgentJSONRPCErrorDataKey       = @"AgentJSONRPCErrorData";

// After the process exits we wait this long for its pipes to reach EOF (a
// grandchild may keep them open) before reporting termination.
static NSTimeInterval const kPipeDrainTimeout = 1;

static NSString* StringFromData (NSData* data)
{
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}

static NSError* ConnectionError (AgentConnectionErrorCode code, NSString* description, NSError* underlyingError = nil)
{
	NSMutableDictionary* userInfo = [NSMutableDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
	if(underlyingError)
		userInfo[NSUnderlyingErrorKey] = underlyingError;
	return [NSError errorWithDomain:AgentConnectionErrorDomain code:code userInfo:userInfo];
}

static NSError* ErrorFromJSONRPCError (id error)
{
	NSDictionary* dict = [error isKindOfClass:[NSDictionary class]] ? error : @{ };
	NSInteger code     = [dict[@"code"] respondsToSelector:@selector(integerValue)] ? [dict[@"code"] integerValue] : AgentJSONRPCErrorInternalError;
	NSString* message  = [dict[@"message"] isKindOfClass:[NSString class]] ? dict[@"message"] : @"Unknown error";

	NSMutableDictionary* userInfo = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
	if(dict[@"data"])
		userInfo[AgentJSONRPCErrorDataKey] = dict[@"data"];
	return [NSError errorWithDomain:AgentJSONRPCErrorDomain code:code userInfo:userInfo];
}

static NSDictionary* JSONRPCErrorFromError (NSError* error)
{
	NSInteger code = [error.domain isEqualToString:AgentJSONRPCErrorDomain] ? error.code : AgentJSONRPCErrorInternalError;
	NSMutableDictionary* res = [NSMutableDictionary dictionaryWithDictionary:@{ @"code": @(code), @"message": error.localizedDescription ?: @"" }];
	if(id data = error.userInfo[AgentJSONRPCErrorDataKey])
		res[@"data"] = data;
	return res;
}

@interface AgentConnection ()
{
	dispatch_queue_t _queue;      // state and incoming data
	dispatch_queue_t _writeQueue; // writes may block when the agent isn't reading

	NSDictionary<NSString*, NSString*>* _environment;
	NSString* _workingDirectory;

	NSTask* _task;
	NSFileHandle* _stdinHandle;
	NSFileHandle* _stdoutHandle;
	NSFileHandle* _stderrHandle;
	NSMutableData* _stdoutBuffer;
	NSMutableData* _stderrBuffer;

	NSInteger _nextRequestId;
	NSMutableDictionary<NSNumber*, AgentResponseHandler>* _pendingRequests;

	BOOL _processExited;
	BOOL _stdoutClosed;
	BOOL _stderrClosed;
	BOOL _didFinish;

	std::atomic<bool> _running;
	std::atomic<int> _terminationStatus;
}
@end

@implementation AgentConnection
- (instancetype)initWithExecutable:(NSString*)executablePath arguments:(NSArray<NSString*>*)arguments environment:(NSDictionary<NSString*, NSString*>*)environment workingDirectory:(NSString*)workingDirectory
{
	if(self = [super init])
	{
		_executablePath   = executablePath;
		_arguments        = arguments ?: @[ ];
		_environment      = environment;
		_workingDirectory = workingDirectory;
		_callbackQueue    = dispatch_get_main_queue();

		_queue      = dispatch_queue_create("org.macromates.TextMate.AgentConnection", DISPATCH_QUEUE_SERIAL);
		_writeQueue = dispatch_queue_create("org.macromates.TextMate.AgentConnection.write", DISPATCH_QUEUE_SERIAL);

		_stdoutBuffer    = [NSMutableData data];
		_stderrBuffer    = [NSMutableData data];
		_nextRequestId   = 1;
		_pendingRequests = [NSMutableDictionary dictionary];

		_running           = false;
		_terminationStatus = 0;
	}
	return self;
}

- (void)dealloc
{
	_stdoutHandle.readabilityHandler = nil;
	_stderrHandle.readabilityHandler = nil;
	if(_task.isRunning)
		[_task terminate];
}

- (BOOL)isRunning           { return _running; }
- (int)terminationStatus    { return _terminationStatus; }

// ===========
// = Process =
// ===========

- (BOOL)launch:(NSError**)error
{
	NSAssert(!_task, @"Connection can only be launched once");

	NSPipe* stdinPipe  = [NSPipe pipe];
	NSPipe* stdoutPipe = [NSPipe pipe];
	NSPipe* stderrPipe = [NSPipe pipe];

	// Writing to an agent that has exited must fail with EPIPE rather than raise SIGPIPE
	fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1);

	_task = [[NSTask alloc] init];
	_task.executableURL  = [NSURL fileURLWithPath:_executablePath];
	_task.arguments      = _arguments;
	_task.standardInput  = stdinPipe;
	_task.standardOutput = stdoutPipe;
	_task.standardError  = stderrPipe;
	if(_environment)
		_task.environment = _environment;
	if(_workingDirectory)
		_task.currentDirectoryURL = [NSURL fileURLWithPath:_workingDirectory isDirectory:YES];

	__weak AgentConnection* weakSelf = self;
	dispatch_queue_t queue = _queue;

	_task.terminationHandler = ^(NSTask* task){
		int status = task.terminationStatus;
		dispatch_async(queue, ^{
			[weakSelf processDidExitWithStatus:status];
		});
	};

	_stdinHandle  = stdinPipe.fileHandleForWriting;
	_stdoutHandle = stdoutPipe.fileHandleForReading;
	_stderrHandle = stderrPipe.fileHandleForReading;

	_stdoutHandle.readabilityHandler = ^(NSFileHandle* handle){
		NSData* data = handle.availableData;
		if(data.length == 0)
			handle.readabilityHandler = nil;
		dispatch_async(queue, ^{
			[weakSelf didReadStandardOutput:data];
		});
	};

	_stderrHandle.readabilityHandler = ^(NSFileHandle* handle){
		NSData* data = handle.availableData;
		if(data.length == 0)
			handle.readabilityHandler = nil;
		dispatch_async(queue, ^{
			[weakSelf didReadStandardError:data];
		});
	};

	NSError* launchError;
	if(![_task launchAndReturnError:&launchError])
	{
		_stdoutHandle.readabilityHandler = nil;
		_stderrHandle.readabilityHandler = nil;
		if(error)
			*error = ConnectionError(AgentConnectionErrorLaunchFailed, [NSString stringWithFormat:@"Unable to launch “%@”: %@", _executablePath, launchError.localizedDescription], launchError);
		return NO;
	}

	// The parent must not keep the child’s ends of the pipes open, otherwise we never see EOF
	[stdinPipe.fileHandleForReading closeFile];
	[stdoutPipe.fileHandleForWriting closeFile];
	[stderrPipe.fileHandleForWriting closeFile];

	_running = true;
	return YES;
}

- (void)terminateWithGracePeriod:(NSTimeInterval)gracePeriod
{
	dispatch_async(_queue, ^{
		if(!_running || _processExited)
			return;

		NSFileHandle* stdinHandle = _stdinHandle;
		dispatch_async(_writeQueue, ^{
			[stdinHandle closeAndReturnError:nil];
		});

		[_task terminate];

		pid_t pid = _task.processIdentifier;
		__weak AgentConnection* weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gracePeriod * NSEC_PER_SEC)), _queue, ^{
			AgentConnection* strongSelf = weakSelf;
			if(strongSelf && !strongSelf->_processExited)
				kill(pid, SIGKILL);
		});
	});
}

- (void)processDidExitWithStatus:(int)status
{
	_processExited     = YES;
	_terminationStatus = status;

	if(_stdoutClosed && _stderrClosed)
		return [self finish];

	__weak AgentConnection* weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPipeDrainTimeout * NSEC_PER_SEC)), _queue, ^{
		[weakSelf finish];
	});
}

- (void)finish
{
	if(_didFinish)
		return;
	_didFinish = YES;
	_running   = false;

	_stdoutHandle.readabilityHandler = nil;
	_stderrHandle.readabilityHandler = nil;

	if(_stderrBuffer.length)
	{
		[self deliverStandardError:StringFromData(_stderrBuffer)];
		_stderrBuffer.length = 0;
	}

	NSDictionary<NSNumber*, AgentResponseHandler>* pending = [_pendingRequests copy];
	[_pendingRequests removeAllObjects];

	NSError* error = ConnectionError(AgentConnectionErrorTerminated, [NSString stringWithFormat:@"Agent exited with status %d", (int)_terminationStatus]);
	dispatch_async(_callbackQueue, ^{
		for(NSNumber* requestId in [pending.allKeys sortedArrayUsingSelector:@selector(compare:)])
			pending[requestId](nil, error);
		if([self.delegate respondsToSelector:@selector(agentConnectionDidTerminate:)])
			[self.delegate agentConnectionDidTerminate:self];
	});
}

// ===========
// = Reading =
// ===========

- (void)didReadStandardOutput:(NSData*)data
{
	if(data.length == 0)
	{
		_stdoutClosed = YES;
		if(_processExited && _stderrClosed)
			[self finish];
		return;
	}

	[_stdoutBuffer appendData:data];

	char const* bytes = (char const*)_stdoutBuffer.bytes;
	size_t const length = _stdoutBuffer.length;
	size_t start = 0;
	while(char const* eol = (char const*)memchr(bytes + start, '\n', length - start))
	{
		size_t lineLength = eol - (bytes + start);
		if(lineLength && bytes[start + lineLength - 1] == '\r')
			--lineLength;
		if(lineLength)
			[self handleLine:[NSData dataWithBytes:bytes + start length:lineLength]];
		start = eol - bytes + 1;
	}

	if(start)
		[_stdoutBuffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
}

- (void)didReadStandardError:(NSData*)data
{
	if(data.length == 0)
	{
		_stderrClosed = YES;
		if(_stderrBuffer.length)
		{
			[self deliverStandardError:StringFromData(_stderrBuffer)];
			_stderrBuffer.length = 0;
		}
		if(_processExited && _stdoutClosed)
			[self finish];
		return;
	}

	[_stderrBuffer appendData:data];

	// Deliver complete lines only, so a message split across reads isn’t broken up
	char const* bytes = (char const*)_stderrBuffer.bytes;
	for(size_t i = _stderrBuffer.length; i > 0; --i)
	{
		if(bytes[i-1] == '\n')
		{
			[self deliverStandardError:StringFromData([_stderrBuffer subdataWithRange:NSMakeRange(0, i)])];
			[_stderrBuffer replaceBytesInRange:NSMakeRange(0, i) withBytes:NULL length:0];
			break;
		}
	}
}

- (void)deliverStandardError:(NSString*)text
{
	if(!text.length)
		return;
	dispatch_async(_callbackQueue, ^{
		if([self.delegate respondsToSelector:@selector(agentConnection:didReceiveStandardError:)])
			[self.delegate agentConnection:self didReceiveStandardError:text];
	});
}

- (void)handleLine:(NSData*)line
{
	NSError* error;
	id message = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
	if(![message isKindOfClass:[NSDictionary class]])
	{
		[self deliverStandardError:[NSString stringWithFormat:@"Ignoring invalid message from agent: %@\n", StringFromData(line)]];
		return;
	}

	NSDictionary* dict = message;
	dispatch_async(_callbackQueue, ^{
		if([self.delegate respondsToSelector:@selector(agentConnection:didTransferMessage:outgoing:)])
			[self.delegate agentConnection:self didTransferMessage:dict outgoing:NO];
	});

	id messageId = dict[@"id"];
	id method    = dict[@"method"];

	if([method isKindOfClass:[NSString class]])
	{
		if(messageId && messageId != [NSNull null])
				[self handleRequest:method params:dict[@"params"] requestId:messageId];
		else	[self handleNotification:method params:dict[@"params"]];
	}
	else if([messageId isKindOfClass:[NSNumber class]])
	{
		[self handleResponse:dict requestId:messageId];
	}
	else
	{
		[self deliverStandardError:[NSString stringWithFormat:@"Ignoring unexpected message from agent: %@\n", StringFromData(line)]];
	}
}

- (void)handleResponse:(NSDictionary*)response requestId:(NSNumber*)requestId
{
	AgentResponseHandler handler = _pendingRequests[requestId];
	if(!handler)
		return;
	[_pendingRequests removeObjectForKey:requestId];

	id result      = response[@"result"];
	NSError* error = response[@"error"] && response[@"error"] != [NSNull null] ? ErrorFromJSONRPCError(response[@"error"]) : nil;
	dispatch_async(_callbackQueue, ^{
		handler(error ? nil : result, error);
	});
}

- (void)handleNotification:(NSString*)method params:(id)params
{
	dispatch_async(_callbackQueue, ^{
		if([self.delegate respondsToSelector:@selector(agentConnection:didReceiveNotification:params:)])
			[self.delegate agentConnection:self didReceiveNotification:method params:params];
	});
}

- (void)handleRequest:(NSString*)method params:(id)params requestId:(id)requestId
{
	__weak AgentConnection* weakSelf = self;
	dispatch_queue_t queue = _queue;
	__block BOOL didReply = NO;

	AgentReplyHandler reply = ^(id result, NSError* error){
		dispatch_async(queue, ^{
			if(didReply)
				return;
			didReply = YES;

			NSMutableDictionary* response = [NSMutableDictionary dictionaryWithDictionary:@{ @"jsonrpc": @"2.0", @"id": requestId }];
			if(error)
					response[@"error"]  = JSONRPCErrorFromError(error);
			else	response[@"result"] = result ?: [NSNull null];
			[weakSelf writeMessage:response];
		});
	};

	dispatch_async(_callbackQueue, ^{
		if([self.delegate respondsToSelector:@selector(agentConnection:didReceiveRequest:params:reply:)])
			[self.delegate agentConnection:self didReceiveRequest:method params:params reply:reply];
		else	reply(nil, [NSError errorWithDomain:AgentJSONRPCErrorDomain code:AgentJSONRPCErrorMethodNotFound userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Method not found: %@", method] }]);
	});
}

// ===========
// = Writing =
// ===========

- (void)sendRequest:(NSString*)method params:(id)params completion:(AgentResponseHandler)handler
{
	dispatch_async(_queue, ^{
		if(!_running)
		{
			NSError* error = ConnectionError(AgentConnectionErrorNotRunning, @"Agent is not running");
			dispatch_async(_callbackQueue, ^{
				if(handler)
					handler(nil, error);
			});
			return;
		}

		NSNumber* requestId = @(_nextRequestId++);
		_pendingRequests[requestId] = handler ?: ^(id, NSError*){ };

		NSMutableDictionary* message = [NSMutableDictionary dictionaryWithDictionary:@{ @"jsonrpc": @"2.0", @"id": requestId, @"method": method }];
		if(params)
			message[@"params"] = params;
		[self writeMessage:message];
	});
}

- (void)sendNotification:(NSString*)method params:(id)params
{
	dispatch_async(_queue, ^{
		if(!_running)
			return;

		NSMutableDictionary* message = [NSMutableDictionary dictionaryWithDictionary:@{ @"jsonrpc": @"2.0", @"method": method }];
		if(params)
			message[@"params"] = params;
		[self writeMessage:message];
	});
}

// Called on _queue
- (void)writeMessage:(NSDictionary*)message
{
	NSError* error;
	NSData* json = [NSJSONSerialization dataWithJSONObject:message options:NSJSONWritingWithoutEscapingSlashes error:&error];
	if(!json)
	{
		[self deliverStandardError:[NSString stringWithFormat:@"Unable to encode message for agent: %@\n", error.localizedDescription]];
		if(NSNumber* requestId = message[@"method"] ? message[@"id"] : nil)
		{
			if(AgentResponseHandler handler = _pendingRequests[requestId])
			{
				[_pendingRequests removeObjectForKey:requestId];
				NSError* invalid = ConnectionError(AgentConnectionErrorInvalidMessage, error.localizedDescription, error);
				dispatch_async(_callbackQueue, ^{
					handler(nil, invalid);
				});
			}
		}
		return;
	}

	dispatch_async(_callbackQueue, ^{
		if([self.delegate respondsToSelector:@selector(agentConnection:didTransferMessage:outgoing:)])
			[self.delegate agentConnection:self didTransferMessage:message outgoing:YES];
	});

	// NSJSONSerialization never emits raw newlines, so one message is one line
	NSMutableData* line = [json mutableCopy];
	[line appendBytes:"\n" length:1];

	NSFileHandle* stdinHandle = _stdinHandle;
	dispatch_async(_writeQueue, ^{
		NSError* writeError;
		if(![stdinHandle writeData:line error:&writeError])
			[self deliverStandardError:[NSString stringWithFormat:@"Unable to write to agent: %@\n", writeError.localizedDescription]];
	});
}
@end
