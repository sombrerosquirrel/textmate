// JSON-RPC 2.0 connection to an Agent Client Protocol (ACP) agent running as
// a subprocess. Messages are newline-delimited JSON on the agent's stdin and
// stdout; stderr is free-form logging.
//
// All pipe I/O and bookkeeping happen on a private serial queue. Delegate
// methods and completion handlers are invoked on `callbackQueue` (the main
// queue unless changed before -launch:).

extern NSErrorDomain const AgentConnectionErrorDomain;

typedef NS_ERROR_ENUM(AgentConnectionErrorDomain, AgentConnectionErrorCode) {
	AgentConnectionErrorLaunchFailed     = 1,
	AgentConnectionErrorNotRunning       = 2,
	AgentConnectionErrorTerminated       = 3,
	AgentConnectionErrorInvalidMessage   = 4,
};

// JSON-RPC error codes, used both for errors received from the agent
// (NSError.code) and for replying to requests from the agent.
typedef NS_ENUM(NSInteger, AgentJSONRPCErrorCode) {
	AgentJSONRPCErrorParseError     = -32700,
	AgentJSONRPCErrorInvalidRequest = -32600,
	AgentJSONRPCErrorMethodNotFound = -32601,
	AgentJSONRPCErrorInvalidParams  = -32602,
	AgentJSONRPCErrorInternalError  = -32603,
};

extern NSErrorDomain const AgentJSONRPCErrorDomain;
extern NSString* const AgentJSONRPCErrorDataKey;

@class AgentConnection;

typedef void(^AgentResponseHandler)(id result, NSError* error);
typedef void(^AgentReplyHandler)(id result, NSError* error); // pass an error in AgentJSONRPCErrorDomain to reply with a JSON-RPC error

@protocol AgentConnectionDelegate <NSObject>
@optional
- (void)agentConnection:(AgentConnection*)connection didReceiveNotification:(NSString*)method params:(id)params;
// Must call reply exactly once. Unimplemented: replies with “method not found”.
- (void)agentConnection:(AgentConnection*)connection didReceiveRequest:(NSString*)method params:(id)params reply:(AgentReplyHandler)reply;
- (void)agentConnection:(AgentConnection*)connection didReceiveStandardError:(NSString*)text;
// Every message sent or received, for logging and debugging.
- (void)agentConnection:(AgentConnection*)connection didTransferMessage:(NSDictionary*)message outgoing:(BOOL)outgoing;
- (void)agentConnectionDidTerminate:(AgentConnection*)connection;
@end

@interface AgentConnection : NSObject
- (instancetype)initWithExecutable:(NSString*)executablePath arguments:(NSArray<NSString*>*)arguments environment:(NSDictionary<NSString*, NSString*>*)environment workingDirectory:(NSString*)workingDirectory;

@property (nonatomic, weak) id<AgentConnectionDelegate> delegate;
@property (nonatomic) dispatch_queue_t callbackQueue;

@property (nonatomic, readonly) NSString* executablePath;
@property (nonatomic, readonly) NSArray<NSString*>* arguments;
@property (nonatomic, readonly) NSDictionary<NSString*, NSString*>* environment;
@property (nonatomic, readonly, getter = isRunning) BOOL running;
@property (nonatomic, readonly) int terminationStatus;

- (BOOL)launch:(NSError**)error;
- (void)sendRequest:(NSString*)method params:(id)params completion:(AgentResponseHandler)handler;
- (void)sendNotification:(NSString*)method params:(id)params;

// Closes the agent's stdin and sends SIGTERM, then SIGKILL if it hasn't
// exited after `gracePeriod` seconds. Pending requests fail with
// AgentConnectionErrorTerminated.
- (void)terminateWithGracePeriod:(NSTimeInterval)gracePeriod;
@end
