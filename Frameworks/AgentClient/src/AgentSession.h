#import "AgentConnection.h"

// One Agent Client Protocol (ACP) session with an agent: the initialize
// handshake, session/new, prompt turns, cancellation, and dispatch of
// requests from the agent.
//
// A session is confined to its connection’s callbackQueue (the main queue in
// TextMate): public methods may be called from any thread and are performed
// on that queue; delegate methods and completion handlers run on it.

extern NSInteger const AgentClientProtocolVersion;

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
	AgentSessionStateFailed,
	AgentSessionStateTerminated,
};

@class AgentSession;

@protocol AgentSessionDelegate <NSObject>
@optional
- (void)agentSessionDidChangeState:(AgentSession*)session;
// The `update` object of a session/update notification for this session.
- (void)agentSession:(AgentSession*)session didReceiveUpdate:(NSDictionary*)update;
// Notifications other than session/update, e.g. vendor extensions.
- (void)agentSession:(AgentSession*)session didReceiveNotification:(NSString*)method params:(id)params;
// Params of session/request_permission. Reply with the `outcome` object, e.g.
// @{ @"outcome": @"selected", @"optionId": … } or @{ @"outcome": @"cancelled" }.
// Unimplemented: every request is answered as cancelled.
- (void)agentSession:(AgentSession*)session requestPermission:(NSDictionary*)params reply:(void(^)(NSDictionary* outcome))reply;
// Other requests from the agent (fs/*, terminal/*). Unimplemented: “method not found”.
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

@property (nonatomic, readonly) AgentSessionState state;
@property (nonatomic, readonly) NSError* error; // reason for AgentSessionStateFailed
@property (nonatomic, readonly) NSString* sessionId;
@property (nonatomic, readonly) NSDictionary* agentInfo;
@property (nonatomic, readonly) NSDictionary* agentCapabilities;
@property (nonatomic, readonly) NSArray<NSDictionary*>* authMethods;

// Launches the agent, then initialize and session/new.
- (void)startWithCompletion:(void(^)(NSError* error))completion;
// `prompt` is an array of ACP content blocks, e.g. @[ @{ @"type": @"text", @"text": … } ].
- (void)sendPrompt:(NSArray<NSDictionary*>*)prompt completion:(void(^)(NSString* stopReason, NSError* error))completion;
// Cancels the current prompt turn; its completion reports stop reason “cancelled”.
- (void)cancel;
// Terminates the agent.
- (void)close;
@end
