#import "AgentTerminal.h"
#import "AgentEnvironment.h"
#include <spawn.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <string>
#include <vector>

static NSTimeInterval const kKillGracePeriod = 3;

static NSError* InvalidParams (NSString* description)
{
	return [NSError errorWithDomain:AgentJSONRPCErrorDomain code:AgentJSONRPCErrorInvalidParams userInfo:@{ NSLocalizedDescriptionKey: description }];
}

// UTF-8 text of `bytes`; invalid sequences (e.g. binary output) become U+FFFD
static NSString* DecodeUTF8 (std::string const& bytes)
{
	if(NSString* res = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding])
		return res;

	NSMutableString* res = [NSMutableString string];
	size_t i = 0, runStart = 0;
	auto flush = [&](size_t end){
		if(end > runStart)
			[res appendString:[[NSString alloc] initWithBytes:bytes.data() + runStart length:end - runStart encoding:NSUTF8StringEncoding] ?: @""];
	};
	while(i < bytes.size())
	{
		unsigned char ch = bytes[i];
		size_t len = ch < 0x80 ? 1 : ((ch & 0xE0) == 0xC0 ? 2 : ((ch & 0xF0) == 0xE0 ? 3 : ((ch & 0xF8) == 0xF0 ? 4 : 0)));
		bool valid = len && i + len <= bytes.size();
		for(size_t j = 1; valid && j < len; ++j)
			valid = (bytes[i + j] & 0xC0) == 0x80;
		if(valid && len > 1)
			valid = [[NSString alloc] initWithBytes:bytes.data() + i length:len encoding:NSUTF8StringEncoding] != nil; // overlong forms, surrogates

		if(valid)
		{
			i += len;
		}
		else
		{
			flush(i);
			[res appendString:@"�"];
			runStart = ++i;
		}
	}
	flush(i);
	return res;
}

static NSString* SignalName (int signal)
{
	if(signal > 0 && signal < NSIG)
		return [@"SIG" stringByAppendingString:[@(sys_signame[signal]) uppercaseString]];
	return [NSString stringWithFormat:@"%d", signal];
}

// Quotes an argument for display only, e.g. `grep "a b" file`
static NSString* DisplayArgument (NSString* arg)
{
	if(arg.length && [arg rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\n\"'\\$`*?;&|<>()"]].location == NSNotFound)
		return arg;
	return [NSString stringWithFormat:@"'%@'", [arg stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

@interface AgentTerminal ()
{
	@public
	std::string _buffer;
	size_t _outputByteLimit;
	pid_t _pid;
	dispatch_source_t _readSource;
	dispatch_source_t _exitSource;
	NSMutableArray<AgentReplyHandler>* _exitWaiters;
}
@property (nonatomic, readwrite) NSString* terminalId;
@property (nonatomic, readwrite) NSString* commandLine;
@property (nonatomic, readwrite) BOOL truncated;
@property (nonatomic, readwrite) BOOL exited;
@property (nonatomic, readwrite) NSNumber* exitCode;
@property (nonatomic, readwrite) NSString* signal;
@property (nonatomic, readwrite) BOOL released;
@end

@implementation AgentTerminal
- (void)dealloc
{
	if(_readSource)
		dispatch_source_cancel(_readSource);
	if(_exitSource)
	{
		dispatch_source_cancel(_exitSource);
		// Nobody is left to collect the exit status; reap it once it ends (killAll sent SIGTERM, then SIGKILL)
		pid_t pid = _pid;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			int status;
			waitpid(pid, &status, 0);
		});
	}
}

- (NSString*)output
{
	return DecodeUTF8(_buffer);
}

- (NSDictionary*)exitStatus
{
	return @{ @"exitCode": _exitCode ?: (id)[NSNull null], @"signal": _signal ?: (id)[NSNull null] };
}

- (void)appendBytes:(char const*)bytes length:(size_t)length
{
	_buffer.append(bytes, length);
	if(_outputByteLimit && _buffer.size() > _outputByteLimit)
	{
		// Drop the oldest output, then any partial character at the new start
		size_t start = _buffer.size() - _outputByteLimit;
		while(start < _buffer.size() && (_buffer[start] & 0xC0) == 0x80)
			++start;
		_buffer.erase(0, start);
		_truncated = YES;
	}
}
@end

@implementation AgentTerminalManager
{
	dispatch_queue_t _queue;
	NSMutableDictionary<NSString*, AgentTerminal*>* _terminals;
	NSUInteger _nextIdentifier;
}

- (instancetype)initWithWorkingDirectory:(NSString*)workingDirectory queue:(dispatch_queue_t)queue
{
	if(self = [super init])
	{
		_workingDirectory = workingDirectory;
		_queue            = queue ?: dispatch_get_main_queue();
		_environment      = NSProcessInfo.processInfo.environment;
		_terminals        = [NSMutableDictionary dictionary];
	}
	return self;
}

- (void)dealloc
{
	[self killAll];
}

- (AgentTerminal*)terminalWithIdentifier:(NSString*)terminalId
{
	return [terminalId isKindOfClass:[NSString class]] ? _terminals[terminalId] : nil;
}

- (void)terminalDidChange:(AgentTerminal*)terminal
{
	if([_delegate respondsToSelector:@selector(agentTerminalManager:didUpdateTerminal:)])
		[_delegate agentTerminalManager:self didUpdateTerminal:terminal];
}

// ==========
// = Launch =
// ==========

- (AgentTerminal*)createTerminalWithParams:(NSDictionary*)params error:(NSError**)error
{
	NSString* command = [params[@"command"] isKindOfClass:[NSString class]] ? params[@"command"] : nil;
	NSArray* args     = [params[@"args"] isKindOfClass:[NSArray class]] ? params[@"args"] : @[ ];
	NSString* cwd     = [params[@"cwd"] isKindOfClass:[NSString class]] ? params[@"cwd"] : _workingDirectory;
	NSUInteger limit  = [params[@"outputByteLimit"] isKindOfClass:[NSNumber class]] ? MAX([params[@"outputByteLimit"] integerValue], 0) : 0;

	if(!command.length)
		return *error = InvalidParams(@"Missing command"), nil;
	if(![cwd hasPrefix:@"/"])
		return *error = InvalidParams([NSString stringWithFormat:@"Working directory must be an absolute path: %@", cwd]), nil;
	for(id arg in args)
	{
		if(![arg isKindOfClass:[NSString class]])
			return *error = InvalidParams(@"Arguments must be strings"), nil;
	}

	NSMutableDictionary<NSString*, NSString*>* environment = [NSMutableDictionary dictionaryWithDictionary:_environment ?: @{ }];
	environment[@"TERM"] = @"dumb"; // the output isn’t shown in a terminal emulator
	for(NSDictionary* variable in [params[@"env"] isKindOfClass:[NSArray class]] ? params[@"env"] : @[ ])
	{
		if([variable isKindOfClass:[NSDictionary class]] && [variable[@"name"] isKindOfClass:[NSString class]] && [variable[@"value"] isKindOfClass:[NSString class]])
			environment[variable[@"name"]] = variable[@"value"];
	}

	// Without arguments the command is a command line for the shell (“npm test && npm run lint”)
	NSString* executable;
	NSArray<NSString*>* argv;
	NSString* commandLine;
	if(args.count)
	{
		executable  = [AgentEnvironment executablePathForCommand:command environment:environment];
		argv        = [@[ command ] arrayByAddingObjectsFromArray:args];
		NSMutableArray* displayArgs = [NSMutableArray array];
		for(NSString* arg in argv)
			[displayArgs addObject:DisplayArgument(arg)];
		commandLine = [displayArgs componentsJoinedByString:@" "];
		if(!executable)
			return *error = [NSError errorWithDomain:AgentJSONRPCErrorDomain code:AgentJSONRPCErrorInternalError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Command not found: %@", command] }], nil;
	}
	else
	{
		NSString* shell = environment[@"SHELL"];
		executable  = [shell hasPrefix:@"/"] && [NSFileManager.defaultManager isExecutableFileAtPath:shell] ? shell : @"/bin/sh";
		argv        = @[ executable.lastPathComponent, @"-c", command ];
		commandLine = command;
	}

	int fds[2];
	if(pipe(fds) != 0)
		return *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil], nil;

	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
	posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
	posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
	posix_spawn_file_actions_addchdir_np(&actions, cwd.fileSystemRepresentation);

	sigset_t noSignals, defaultSignals;
	sigemptyset(&noSignals);
	sigfillset(&defaultSignals);

	posix_spawnattr_t attributes;
	posix_spawnattr_init(&attributes);
	// Own process group, so kill reaches everything the command starts;
	// close all other descriptors; default signal handling (TextMate ignores SIGPIPE)
	posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
	posix_spawnattr_setpgroup(&attributes, 0);
	posix_spawnattr_setsigmask(&attributes, &noSignals);
	posix_spawnattr_setsigdefault(&attributes, &defaultSignals);

	std::vector<std::string> argStrings, envStrings;
	for(NSString* arg in argv)
		argStrings.emplace_back(arg.UTF8String);
	for(NSString* key in environment)
		envStrings.emplace_back(std::string(key.UTF8String) + "=" + environment[key].UTF8String);

	std::vector<char*> cArgv, cEnvp;
	for(auto& str : argStrings)
		cArgv.push_back(&str[0]);
	cArgv.push_back(nullptr);
	for(auto& str : envStrings)
		cEnvp.push_back(&str[0]);
	cEnvp.push_back(nullptr);

	pid_t pid = 0;
	int rc = posix_spawn(&pid, executable.fileSystemRepresentation, &actions, &attributes, cArgv.data(), cEnvp.data());
	posix_spawn_file_actions_destroy(&actions);
	posix_spawnattr_destroy(&attributes);
	close(fds[1]);

	if(rc != 0)
	{
		close(fds[0]);
		NSString* description = [NSString stringWithFormat:@"Unable to run %@: %s", commandLine, strerror(rc)];
		return *error = [NSError errorWithDomain:AgentJSONRPCErrorDomain code:AgentJSONRPCErrorInternalError userInfo:@{ NSLocalizedDescriptionKey: description }], nil;
	}

	AgentTerminal* terminal = [[AgentTerminal alloc] init];
	terminal.terminalId      = [NSString stringWithFormat:@"term-%lu", ++_nextIdentifier];
	terminal.commandLine     = commandLine;
	terminal->_outputByteLimit = limit;
	terminal->_pid             = pid;
	terminal->_exitWaiters     = [NSMutableArray array];
	_terminals[terminal.terminalId] = terminal;

	[self observeOutputOfTerminal:terminal fileDescriptor:fds[0]];
	[self observeExitOfTerminal:terminal];
	return terminal;
}

- (void)readAvailableOutputOfTerminal:(AgentTerminal*)terminal fileDescriptor:(int)fd
{
	char buf[16384];
	ssize_t len;
	BOOL changed = NO;
	while((len = read(fd, buf, sizeof(buf))) > 0)
	{
		[terminal appendBytes:buf length:len];
		changed = YES;
	}

	if(len == 0 || (len < 0 && errno != EAGAIN && errno != EINTR))
	{
		if(terminal->_readSource)
			dispatch_source_cancel(terminal->_readSource);
		terminal->_readSource = nil;
	}
	if(changed)
		[self terminalDidChange:terminal];
}

- (void)observeOutputOfTerminal:(AgentTerminal*)terminal fileDescriptor:(int)fd
{
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
	fcntl(fd, F_SETFD, FD_CLOEXEC);

	__weak AgentTerminalManager* weakSelf = self;
	__weak AgentTerminal* weakTerminal    = terminal;
	dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _queue);
	dispatch_source_set_event_handler(source, ^{
		if(AgentTerminal* terminal = weakTerminal)
			[weakSelf readAvailableOutputOfTerminal:terminal fileDescriptor:fd];
	});
	dispatch_source_set_cancel_handler(source, ^{
		close(fd);
	});
	terminal->_readSource = source;
	dispatch_resume(source);
}

- (void)observeExitOfTerminal:(AgentTerminal*)terminal
{
	pid_t pid = terminal->_pid;
	__weak AgentTerminalManager* weakSelf = self;
	__weak AgentTerminal* weakTerminal    = terminal;
	dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, _queue);
	dispatch_source_set_event_handler(source, ^{
		int status = 0;
		if(waitpid(pid, &status, WNOHANG) != pid)
			return;
		dispatch_source_cancel(source);
		if(AgentTerminal* terminal = weakTerminal)
			[weakSelf terminal:terminal didExitWithStatus:status];
	});
	terminal->_exitSource = source;
	dispatch_resume(source);

	// A command that exited before the source was set up may never fire it
	dispatch_async(_queue, ^{
		int status = 0;
		if(waitpid(pid, &status, WNOHANG) != pid)
			return;
		dispatch_source_cancel(source);
		if(AgentTerminal* terminal = weakTerminal)
			[weakSelf terminal:terminal didExitWithStatus:status];
	});
}

- (void)terminal:(AgentTerminal*)terminal didExitWithStatus:(int)status
{
	// Output written just before exiting may not have been read yet
	if(terminal->_readSource)
		[self readAvailableOutputOfTerminal:terminal fileDescriptor:(int)dispatch_source_get_handle(terminal->_readSource)];

	terminal->_exitSource = nil; // already cancelled
	terminal.exitCode = WIFEXITED(status) ? @(WEXITSTATUS(status)) : nil;
	terminal.signal   = WIFSIGNALED(status) ? SignalName(WTERMSIG(status)) : nil;
	terminal.exited   = YES;

	NSArray<AgentReplyHandler>* waiters = [terminal->_exitWaiters copy];
	[terminal->_exitWaiters removeAllObjects];
	for(AgentReplyHandler reply in waiters)
		reply(terminal.exitStatus, nil);

	[self terminalDidChange:terminal];
}

// ========
// = Kill =
// ========

- (void)killTerminal:(AgentTerminal*)terminal
{
	if(terminal.exited || terminal->_pid <= 0)
		return;

	pid_t pid = terminal->_pid;
	killpg(pid, SIGTERM);

	__weak AgentTerminal* weakTerminal = terminal;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKillGracePeriod * NSEC_PER_SEC)), _queue, ^{
		AgentTerminal* terminal = weakTerminal;
		if(terminal && !terminal.exited)
			killpg(pid, SIGKILL);
	});
}

- (void)killAll
{
	for(AgentTerminal* terminal in _terminals.allValues)
	{
		if(!terminal.exited && terminal->_pid > 0)
		{
			killpg(terminal->_pid, SIGTERM);
			// We may be going away; make sure it doesn’t outlive us
			pid_t pid = terminal->_pid;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKillGracePeriod * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				if(killpg(pid, 0) == 0)
					killpg(pid, SIGKILL);
			});
		}
	}
}

// ============
// = Requests =
// ============

- (void)handleRequest:(NSString*)method params:(NSDictionary*)params reply:(AgentReplyHandler)reply
{
	NSDictionary* dict = [params isKindOfClass:[NSDictionary class]] ? params : @{ };

	if([method isEqualToString:@"terminal/create"])
	{
		NSError* error;
		AgentTerminal* terminal = [self createTerminalWithParams:dict error:&error];
		reply(terminal ? @{ @"terminalId": terminal.terminalId } : nil, error);
		if(terminal)
			[self terminalDidChange:terminal];
		return;
	}

	AgentTerminal* terminal = [self terminalWithIdentifier:dict[@"terminalId"]];
	if(!terminal || terminal.released)
		return reply(nil, InvalidParams([NSString stringWithFormat:@"Unknown terminal: %@", dict[@"terminalId"]]));

	if([method isEqualToString:@"terminal/output"])
	{
		NSMutableDictionary* result = [NSMutableDictionary dictionaryWithDictionary:@{ @"output": terminal.output, @"truncated": @(terminal.truncated) }];
		if(terminal.exited)
			result[@"exitStatus"] = terminal.exitStatus;
		reply(result, nil);
	}
	else if([method isEqualToString:@"terminal/wait_for_exit"])
	{
		if(terminal.exited)
				reply(terminal.exitStatus, nil);
		else	[terminal->_exitWaiters addObject:reply];
	}
	else if([method isEqualToString:@"terminal/kill"])
	{
		[self killTerminal:terminal];
		reply(@{ }, nil);
	}
	else if([method isEqualToString:@"terminal/release"])
	{
		[self killTerminal:terminal];
		terminal.released = YES;
		reply(@{ }, nil);
		[self terminalDidChange:terminal];
	}
	else
	{
		reply(nil, [NSError errorWithDomain:AgentJSONRPCErrorDomain code:AgentJSONRPCErrorMethodNotFound userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Method not found: %@", method] }]);
	}
}
@end
