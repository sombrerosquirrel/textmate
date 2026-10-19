#import "AgentConnection.h"
#import "AgentFileSystem.h"
#import "AgentTerminal.h"

// One Agent Client Protocol (ACP) session with an agent: the initialize
// handshake, session/new, prompt turns, cancellation, and dispatch of
// requests from the agent.
//
// A session is confined to its connection’s callbackQueue (the main queue in
// TextMate): public methods may be called from any thread and are performed
// on that queue; delegate methods and completion handlers run on it.

extern NSInteger const AgentClientProtocolVersion;

// The agent refused a request because the user isn’t signed in (ACP error -32000).
BOOL AgentErrorIsAuthenticationRequired (NSError* error);

extern NSErrorDomain const AgentSessionErrorDomain;

typedef NS_ERROR_ENUM(AgentSessionErrorDomain, AgentSessionErrorCode) {
	AgentSessionErrorInvalidState               = 1,
	AgentSessionErrorUnsupportedProtocolVersion = 2,
	AgentSessionErrorInvalidResponse            = 3,
};

typedef NS_ENUM(NSInteger, AgentSessionState) {
	AgentSessionStateIdle = 0,
	AgentSessionStateStarting,
	AgentSessionStateReady,
	AgentSessionStatePrompting,
	AgentSessionStateLoading,   // session/load: the agent replays the chat as session/update notifications
	AgentSessionStateFailed,
	AgentSessionStateTerminated,
};

@class AgentSession;

@protocol AgentSessionDelegate <NSObject>
@optional
- (void)agentSessionDidChangeState:(AgentSession*)session;
// configOptions, modes, or availableCommands changed.
- (void)agentSessionDidChangeConfiguration:(AgentSession*)session;
// The `update` object of a session/update notification for this session.
- (void)agentSession:(AgentSession*)session didReceiveUpdate:(NSDictionary*)update;
// Notifications other than session/update, e.g. vendor extensions.
- (void)agentSession:(AgentSession*)session didReceiveNotification:(NSString*)method params:(id)params;
// Params of session/request_permission. Reply with the `outcome` object, e.g.
// @{ @"outcome": @"selected", @"optionId": … } or @{ @"outcome": @"cancelled" }.
// Unimplemented: every request is answered as cancelled.
- (void)agentSession:(AgentSession*)session requestPermission:(NSDictionary*)params reply:(void(^)(NSDictionary* outcome))reply;
// Other requests from the agent, e.g. fs/* without a fileSystem. Unimplemented: “method not found”.
- (void)agentSession:(AgentSession*)session didReceiveRequest:(NSString*)method params:(id)params reply:(AgentReplyHandler)reply;
- (void)agentSession:(AgentSession*)session didReceiveStandardError:(NSString*)text;
- (void)agentSession:(AgentSession*)session didTransferMessage:(NSDictionary*)message outgoing:(BOOL)outgoing;
@end

@interface AgentSession : NSObject
- (instancetype)initWithConnection:(AgentConnection*)connection workingDirectory:(NSString*)workingDirectory;

@property (nonatomic, weak) id<AgentSessionDelegate> delegate;
@property (nonatomic, readonly) AgentConnection* connection;
@property (nonatomic, readonly) NSString* workingDirectory;

// Capabilities advertised in initialize, e.g. @{ @"fs": @{ @"readTextFile": @YES } }.
// Set before -startWithCompletion:. Default: none.
@property (nonatomic) NSDictionary* clientCapabilities;

// Handles fs/* requests when set before -startWithCompletion:, which then
// also advertises the fs capabilities.
@property (nonatomic) AgentFileSystem* fileSystem;
// Handles terminal/* requests when set before -startWithCompletion:, which
// then also advertises the terminal capability. Its commands are killed
// when the session closes or the agent exits.
@property (nonatomic) AgentTerminalManager* terminals;

// ACP McpServer objects sent with session/new and session/load. Servers
// whose transport the agent doesn’t support (mcpCapabilities http, sse) are
// left out and added to skippedMCPServers as { name, reason }, after any
// the caller put there (e.g. a command that wasn’t found).
@property (nonatomic, copy) NSArray<NSDictionary*>* mcpServers;
@property (nonatomic, copy) NSArray<NSDictionary<NSString*, NSString*>*>* skippedMCPServers;

// Set before -startWithCompletion: to continue an earlier chat: if the agent
// supports loadSession, start sends session/load instead of session/new.
// If loading fails, start falls back to session/new and sets loadError.
@property (nonatomic, copy) NSString* sessionIdToLoad;
@property (nonatomic, readonly) NSError* loadError;

@property (nonatomic, readonly) AgentSessionState state;
@property (nonatomic, readonly) NSError* error; // reason for AgentSessionStateFailed
// The agent’s last few lines of standard error, which often explain why it
// failed or exited; nil if it wrote none.
@property (nonatomic, readonly) NSString* recentStandardError;
@property (nonatomic, readonly) NSString* sessionId;
@property (nonatomic, readonly) NSDictionary* agentInfo;
@property (nonatomic, readonly) NSDictionary* agentCapabilities;
@property (nonatomic, readonly) NSArray<NSDictionary*>* authMethods;
// The command that signs in from a terminal, from the first auth method
// that has one (Copilot: `_meta.terminal-auth`; ACP: type “terminal”, which
// runs the agent with extra arguments); nil if none does.
@property (nonatomic, readonly) NSArray<NSString*>* signInArguments;
+ (NSArray<NSString*>*)signInArgumentsFromAuthMethods:(NSArray<NSDictionary*>*)authMethods agentArguments:(NSArray<NSString*>*)agentArguments;

// Agent-provided controls, kept current from session/new and session/update.
// configOptions: ACP config options (mode, model, effort, …); modes: the older
// `modes` object, for agents without configOptions; availableCommands: slash
// commands ({ name, description, input: { hint } }).
@property (nonatomic, readonly) NSArray<NSDictionary*>* configOptions;
@property (nonatomic, readonly) NSDictionary* modes;
@property (nonatomic, readonly) NSArray<NSDictionary*>* availableCommands;

// The agent announces session/list and session/load.
@property (nonatomic, readonly) BOOL canListSessions;
@property (nonatomic, readonly) BOOL canLoadSessions;

// Launches the agent, then initialize and session/new (or session/load).
- (void)startWithCompletion:(void(^)(NSError* error))completion;
// `prompt` is an array of ACP content blocks, e.g. @[ @{ @"type": @"text", @"text": … } ].
- (void)sendPrompt:(NSArray<NSDictionary*>*)prompt completion:(void(^)(NSString* stopReason, NSError* error))completion;
// Cancels the current prompt turn; its completion reports stop reason “cancelled”.
- (void)cancel;
// session/set_config_option; on success configOptions holds the agent’s new state.
- (void)setConfigOption:(NSString*)configId value:(id)value completion:(void(^)(NSError* error))completion;
// session/set_mode, for agents that only provide `modes`.
- (void)setMode:(NSString*)modeId completion:(void(^)(NSError* error))completion;
// session/list for the working directory, newest first as the agent sends
// them: { sessionId, title, updatedAt, … }. Only the first page.
- (void)listSessionsWithCompletion:(void(^)(NSArray<NSDictionary*>* sessions, NSError* error))completion;
// Switches a ready session to an earlier chat with session/load; the
// delegate receives the replayed chat as updates, then the completion runs.
// The previous chat is closed if the agent supports session/close.
- (void)loadSession:(NSString*)sessionId completion:(void(^)(NSError* error))completion;
// Terminates the agent.
- (void)close;
@end
