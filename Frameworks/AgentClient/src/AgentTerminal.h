#import "AgentConnection.h"

// The client side of ACP’s terminal/* methods: commands the agent runs in
// the project, with their output shown in the agent’s tool calls.
//
// A command with `args` runs that program (looked up in PATH); without, the
// command line runs through the user’s shell. Each command gets its own
// process group so kill and release also stop the processes it started.
// Output (stdout and stderr together) keeps the newest `outputByteLimit`
// bytes, cut at a character boundary.
//
// Not thread-safe: use it on the queue given at creation (the session’s
// callback queue), where delegate methods are also called.

@interface AgentTerminal : NSObject
@property (nonatomic, readonly) NSString* terminalId;
@property (nonatomic, readonly) NSString* commandLine;   // for display
@property (nonatomic, readonly) NSString* output;
@property (nonatomic, readonly, getter = isTruncated) BOOL truncated;
@property (nonatomic, readonly, getter = hasExited) BOOL exited;
@property (nonatomic, readonly) NSNumber* exitCode;      // nil if ended by a signal
@property (nonatomic, readonly) NSString* signal;        // e.g. “SIGTERM”; nil if it exited normally
@property (nonatomic, readonly, getter = isReleased) BOOL released;
@end

@class AgentTerminalManager;

@protocol AgentTerminalManagerDelegate <NSObject>
@optional
// New output, exit, or release.
- (void)agentTerminalManager:(AgentTerminalManager*)manager didUpdateTerminal:(AgentTerminal*)terminal;
@end

@interface AgentTerminalManager : NSObject
- (instancetype)initWithWorkingDirectory:(NSString*)workingDirectory queue:(dispatch_queue_t)queue;

@property (nonatomic, readonly) NSString* workingDirectory;
// Base environment of commands, e.g. the login shell’s.
@property (nonatomic) NSDictionary<NSString*, NSString*>* environment;
@property (nonatomic, weak) id<AgentTerminalManagerDelegate> delegate;

// Includes released terminals, so their output can still be shown.
- (AgentTerminal*)terminalWithIdentifier:(NSString*)terminalId;

// Handles terminal/create, output, wait_for_exit, kill and release.
- (void)handleRequest:(NSString*)method params:(NSDictionary*)params reply:(AgentReplyHandler)reply;

// SIGTERM to the command’s process group, then SIGKILL if it hasn’t exited after a few seconds.
- (void)killTerminal:(AgentTerminal*)terminal;
// Kills every running command; call when the session ends.
- (void)killAll;
@end
