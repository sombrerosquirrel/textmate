#import "AgentSession.h"

NSInteger const AgentClientProtocolVersion   = 1;
NSErrorDomain const AgentSessionErrorDomain = @"AgentSessionErrorDomain";

static NSTimeInterval const kTerminationGracePeriod = 2;

static NSError* SessionError (AgentSessionErrorCode code, NSString* description)
{
	return [NSError errorWithDomain:AgentSessionErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: description }];
}

static NSString* ClientVersion ()
{
	return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev";
}

@interface AgentSession () <AgentConnectionDelegate>
{
	// Replies for permission requests still waiting on the delegate; answered as cancelled by -cancel and on termination
	NSMutableDictionary<NSUUID*, void(^)(NSDictionary*)>* _pendingPermissionReplies;
}
@property (nonatomic, readwrite) AgentSessionState state;
@property (nonatomic, readwrite) NSError* error;
@property (nonatomic, readwrite) NSString* sessionId;
@property (nonatomic, readwrite) NSDictionary* agentInfo;
@property (nonatomic, readwrite) NSDictionary* agentCapabilities;
@property (nonatomic, readwrite) NSArray<NSDictionary*>* authMethods;
@property (nonatomic, readwrite) NSArray<NSDictionary*>* configOptions;
@property (nonatomic, readwrite) NSDictionary* modes;
@property (nonatomic, readwrite) NSArray<NSDictionary*>* availableCommands;
@end

static NSUInteger const kMaxStandardErrorLines      = 10;
static NSUInteger const kMaxStandardErrorLineLength = 300;

@implementation AgentSession
{
	NSMutableArray<NSString*>* _standardErrorLines;
}

- (instancetype)initWithConnection:(AgentConnection*)connection workingDirectory:(NSString*)workingDirectory
{
	if(self = [super init])
	{
		_connection         = connection;
		_workingDirectory   = workingDirectory;
		_clientCapabilities = @{ };
		_pendingPermissionReplies = [NSMutableDictionary dictionary];

		_connection.delegate = self;
	}
	return self;
}

- (void)performOnQueue:(void(^)())block
{
	dispatch_async(_connection.callbackQueue, block);
}

- (void)setState:(AgentSessionState)newState
{
	if(_state == newState)
		return;
	_state = newState;
	if([self.delegate respondsToSelector:@selector(agentSessionDidChangeState:)])
		[self.delegate agentSessionDidChangeState:self];
}

- (void)failWithError:(NSError*)error
{
	self.error = error;
	self.state = AgentSessionStateFailed;
	[_connection terminateWithGracePeriod:kTerminationGracePeriod];
}

// =============
// = Lifecycle =
// =============

- (void)startWithCompletion:(void(^)(NSError* error))completion
{
	[self performOnQueue:^{
		if(self.state != AgentSessionStateIdle)
		{
			if(completion)
				completion(SessionError(AgentSessionErrorInvalidState, @"Session has already been started"));
			return;
		}

		self.state = AgentSessionStateStarting;

		NSError* launchError;
		if(![_connection launch:&launchError])
		{
			[self failWithError:launchError];
			if(completion)
				completion(launchError);
			return;
		}

		NSDictionary* params = @{
			@"protocolVersion":    @(AgentClientProtocolVersion),
			@"clientCapabilities": self.clientCapabilities ?: @{ },
			@"clientInfo":         @{ @"name": @"textmate", @"title": @"TextMate", @"version": ClientVersion() },
		};

		[_connection sendRequest:@"initialize" params:params completion:^(id result, NSError* error){
			if(!error && ![result isKindOfClass:[NSDictionary class]])
				error = SessionError(AgentSessionErrorInvalidResponse, @"Invalid response to initialize");
			if(!error && [result[@"protocolVersion"] integerValue] != AgentClientProtocolVersion)
				error = SessionError(AgentSessionErrorUnsupportedProtocolVersion, [NSString stringWithFormat:@"Agent uses unsupported protocol version %@ (expected %ld)", result[@"protocolVersion"], AgentClientProtocolVersion]);

			if(error)
			{
				[self failWithError:error];
				if(completion)
					completion(error);
				return;
			}

			NSDictionary* dict = result;
			self.agentInfo         = [dict[@"agentInfo"] isKindOfClass:[NSDictionary class]] ? dict[@"agentInfo"] : nil;
			self.agentCapabilities = [dict[@"agentCapabilities"] isKindOfClass:[NSDictionary class]] ? dict[@"agentCapabilities"] : @{ };
			self.authMethods       = [dict[@"authMethods"] isKindOfClass:[NSArray class]] ? dict[@"authMethods"] : @[ ];

			[self createSessionWithCompletion:completion];
		}];
	}];
}

- (void)createSessionWithCompletion:(void(^)(NSError* error))completion
{
	NSDictionary* params = @{ @"cwd": _workingDirectory, @"mcpServers": @[ ] };
	[_connection sendRequest:@"session/new" params:params completion:^(id result, NSError* error){
		NSString* sessionId = [result isKindOfClass:[NSDictionary class]] && [result[@"sessionId"] isKindOfClass:[NSString class]] ? result[@"sessionId"] : nil;
		if(!error && !sessionId)
			error = SessionError(AgentSessionErrorInvalidResponse, @"Invalid response to session/new");

		if(error)
		{
			[self failWithError:error];
			if(completion)
				completion(error);
			return;
		}

		self.sessionId = sessionId;
		[self updateConfigurationFromDictionary:result];
		self.state     = AgentSessionStateReady;
		if(completion)
			completion(nil);
	}];
}

- (void)close
{
	[self performOnQueue:^{
		[self answerPendingPermissionRequestsAsCancelled];
		[_connection terminateWithGracePeriod:kTerminationGracePeriod];
	}];
}

// ================
// = Prompt Turns =
// ================

- (void)sendPrompt:(NSArray<NSDictionary*>*)prompt completion:(void(^)(NSString* stopReason, NSError* error))completion
{
	[self performOnQueue:^{
		if(self.state != AgentSessionStateReady)
		{
			if(completion)
				completion(nil, SessionError(AgentSessionErrorInvalidState, self.state == AgentSessionStatePrompting ? @"A prompt is already in progress" : @"Session is not ready"));
			return;
		}

		self.state = AgentSessionStatePrompting;
		[_connection sendRequest:@"session/prompt" params:@{ @"sessionId": self.sessionId, @"prompt": prompt } completion:^(id result, NSError* error){
			NSString* stopReason = [result isKindOfClass:[NSDictionary class]] && [result[@"stopReason"] isKindOfClass:[NSString class]] ? result[@"stopReason"] : nil;
			if(!error && !stopReason)
				error = SessionError(AgentSessionErrorInvalidResponse, @"Invalid response to session/prompt");

			if(self.state == AgentSessionStatePrompting)
				self.state = AgentSessionStateReady;
			if(completion)
				completion(error ? nil : stopReason, error);
		}];
	}];
}

- (void)cancel
{
	[self performOnQueue:^{
		if(self.state != AgentSessionStatePrompting)
			return;
		[_connection sendNotification:@"session/cancel" params:@{ @"sessionId": self.sessionId }];
		[self answerPendingPermissionRequestsAsCancelled];
	}];
}

// =================
// = Configuration =
// =================

// Accepts a session/new or session/set_config_option result, or the update of
// a config_option_update / current_mode_update / available_commands_update.
- (void)updateConfigurationFromDictionary:(NSDictionary*)dict
{
	BOOL changed = NO;
	if([dict[@"configOptions"] isKindOfClass:[NSArray class]])
	{
		self.configOptions = dict[@"configOptions"];
		changed = YES;
	}
	if([dict[@"modes"] isKindOfClass:[NSDictionary class]])
	{
		self.modes = dict[@"modes"];
		changed = YES;
	}
	if([dict[@"currentModeId"] isKindOfClass:[NSString class]] && self.modes)
	{
		NSMutableDictionary* modes = [self.modes mutableCopy];
		modes[@"currentModeId"] = dict[@"currentModeId"];
		self.modes = modes;
		changed = YES;
	}
	if([dict[@"availableCommands"] isKindOfClass:[NSArray class]])
	{
		self.availableCommands = dict[@"availableCommands"];
		changed = YES;
	}

	if(changed && [self.delegate respondsToSelector:@selector(agentSessionDidChangeConfiguration:)])
		[self.delegate agentSessionDidChangeConfiguration:self];
}

- (void)setConfigOption:(NSString*)configId value:(id)value completion:(void(^)(NSError* error))completion
{
	[self performOnQueue:^{
		if(!self.sessionId || self.state == AgentSessionStateFailed || self.state == AgentSessionStateTerminated)
		{
			if(completion)
				completion(SessionError(AgentSessionErrorInvalidState, @"Session is not ready"));
			return;
		}

		NSMutableDictionary* params = [NSMutableDictionary dictionaryWithDictionary:@{ @"sessionId": self.sessionId, @"configId": configId, @"value": value }];
		if([value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
			params[@"type"] = @"boolean";

		[_connection sendRequest:@"session/set_config_option" params:params completion:^(id result, NSError* error){
			if(!error && [result isKindOfClass:[NSDictionary class]])
				[self updateConfigurationFromDictionary:result];
			if(completion)
				completion(error);
		}];
	}];
}

- (void)setMode:(NSString*)modeId completion:(void(^)(NSError* error))completion
{
	[self performOnQueue:^{
		if(!self.sessionId || self.state == AgentSessionStateFailed || self.state == AgentSessionStateTerminated)
		{
			if(completion)
				completion(SessionError(AgentSessionErrorInvalidState, @"Session is not ready"));
			return;
		}

		[_connection sendRequest:@"session/set_mode" params:@{ @"sessionId": self.sessionId, @"modeId": modeId } completion:^(id result, NSError* error){
			if(!error)
				[self updateConfigurationFromDictionary:@{ @"currentModeId": modeId }];
			if(completion)
				completion(error);
		}];
	}];
}

- (void)answerPendingPermissionRequestsAsCancelled
{
	NSArray<void(^)(NSDictionary*)>* replies = _pendingPermissionReplies.allValues;
	[_pendingPermissionReplies removeAllObjects];
	for(void(^reply)(NSDictionary*) in replies)
		reply(@{ @"outcome": @"cancelled" });
}

// ==============================
// = AgentConnectionDelegate =
// ==============================

- (void)agentConnection:(AgentConnection*)connection didReceiveNotification:(NSString*)method params:(id)params
{
	if([method isEqualToString:@"session/update"])
	{
		NSDictionary* update = [params isKindOfClass:[NSDictionary class]] ? params[@"update"] : nil;
		if(![update isKindOfClass:[NSDictionary class]] || ![params[@"sessionId"] isEqual:self.sessionId])
			return;

		NSString* kind = update[@"sessionUpdate"];
		if([kind isEqualToString:@"config_option_update"] || [kind isEqualToString:@"current_mode_update"] || [kind isEqualToString:@"available_commands_update"])
			[self updateConfigurationFromDictionary:update];

		if([self.delegate respondsToSelector:@selector(agentSession:didReceiveUpdate:)])
			[self.delegate agentSession:self didReceiveUpdate:update];
	}
	else if([self.delegate respondsToSelector:@selector(agentSession:didReceiveNotification:params:)])
	{
		[self.delegate agentSession:self didReceiveNotification:method params:params];
	}
}

- (void)agentConnection:(AgentConnection*)connection didReceiveRequest:(NSString*)method params:(id)params reply:(AgentReplyHandler)reply
{
	if([method isEqualToString:@"session/request_permission"])
	{
		__block BOOL didReply = NO;
		__weak AgentSession* weakSelf = self;
		NSUUID* token = [NSUUID UUID];
		void(^permissionReply)(NSDictionary*) = ^(NSDictionary* outcome){
			[weakSelf performOnQueue:^{
				if(didReply)
					return;
				didReply = YES;
				[weakSelf removePendingPermissionReplyForToken:token];
				reply(@{ @"outcome": outcome ?: @{ @"outcome": @"cancelled" } }, nil);
			}];
		};

		if(self.state == AgentSessionStatePrompting && [params isKindOfClass:[NSDictionary class]] && [self.delegate respondsToSelector:@selector(agentSession:requestPermission:reply:)])
		{
			_pendingPermissionReplies[token] = permissionReply;
			[self.delegate agentSession:self requestPermission:params reply:permissionReply];
		}
		else
		{
			permissionReply(@{ @"outcome": @"cancelled" });
		}
	}
	else if([self.delegate respondsToSelector:@selector(agentSession:didReceiveRequest:params:reply:)])
	{
		[self.delegate agentSession:self didReceiveRequest:method params:params reply:reply];
	}
	else
	{
		reply(nil, [NSError errorWithDomain:AgentJSONRPCErrorDomain code:AgentJSONRPCErrorMethodNotFound userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Method not found: %@", method] }]);
	}
}

- (void)removePendingPermissionReplyForToken:(NSUUID*)token
{
	[_pendingPermissionReplies removeObjectForKey:token];
}

- (NSString*)recentStandardError
{
	return _standardErrorLines.count ? [_standardErrorLines componentsJoinedByString:@"\n"] : nil;
}

- (void)agentConnection:(AgentConnection*)connection didReceiveStandardError:(NSString*)text
{
	if(!_standardErrorLines)
		_standardErrorLines = [NSMutableArray array];
	for(NSString* line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
	{
		NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if(trimmed.length)
			[_standardErrorLines addObject:trimmed.length > kMaxStandardErrorLineLength ? [[trimmed substringToIndex:kMaxStandardErrorLineLength] stringByAppendingString:@"…"] : trimmed];
	}
	if(_standardErrorLines.count > kMaxStandardErrorLines)
		[_standardErrorLines removeObjectsInRange:NSMakeRange(0, _standardErrorLines.count - kMaxStandardErrorLines)];

	if([self.delegate respondsToSelector:@selector(agentSession:didReceiveStandardError:)])
		[self.delegate agentSession:self didReceiveStandardError:text];
}

- (void)agentConnection:(AgentConnection*)connection didTransferMessage:(NSDictionary*)message outgoing:(BOOL)outgoing
{
	if([self.delegate respondsToSelector:@selector(agentSession:didTransferMessage:outgoing:)])
		[self.delegate agentSession:self didTransferMessage:message outgoing:outgoing];
}

- (void)agentConnectionDidTerminate:(AgentConnection*)connection
{
	[self answerPendingPermissionRequestsAsCancelled];
	if(self.state == AgentSessionStateStarting)
		self.error = [NSError errorWithDomain:AgentConnectionErrorDomain code:AgentConnectionErrorTerminated userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Agent exited with status %d during startup", connection.terminationStatus] }];
	if(self.state != AgentSessionStateFailed)
		self.state = AgentSessionStateTerminated;
}
@end
