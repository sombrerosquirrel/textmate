// What the agent panels exchanged with their agents, for Window ▸ Agent Log:
// JSON-RPC messages, the agents’ standard error, and starts and exits. Kept
// for the whole app (all windows), oldest entries dropped past a limit.

typedef NS_ENUM(NSInteger, AgentLogEntryKind) {
	AgentLogEntryKindSent = 0,      // JSON-RPC message to the agent
	AgentLogEntryKindReceived,      // JSON-RPC message from the agent
	AgentLogEntryKindStandardError, // the agent’s standard error
	AgentLogEntryKindEvent,         // started, exited, …
};

@interface AgentLogEntry : NSObject
@property (nonatomic, readonly) NSUInteger serialNumber; // increases with each entry
@property (nonatomic, readonly) NSDate* date;
@property (nonatomic, readonly) NSString* source;        // e.g. “textmate — Claude Code”
@property (nonatomic, readonly) AgentLogEntryKind kind;
@property (nonatomic, readonly) NSDictionary* message;   // sent and received entries
@property (nonatomic, readonly) NSString* text;          // other entries
// One line, e.g. “→ session/prompt #3” or “← session/update agent_message_chunk”.
@property (nonatomic, readonly) NSString* summary;
// The message as compact JSON (cut off after `limit` characters), or the text.
- (NSString*)detailWithLimit:(NSUInteger)limit;
- (BOOL)matchesSearchString:(NSString*)searchString; // summary or full detail, ignoring case
@end

extern NSNotificationName const AgentLogDidChangeNotification; // entries added or cleared, posted at most once per run loop cycle

@interface AgentLog : NSObject
@property (class, readonly) AgentLog* sharedLog;
@property (nonatomic) NSUInteger maximumEntries; // default 5,000
@property (nonatomic, readonly) NSArray<AgentLogEntry*>* entries;
@property (nonatomic, readonly) NSArray<NSString*>* sources;      // in order of first appearance

- (void)addMessage:(NSDictionary*)message outgoing:(BOOL)outgoing source:(NSString*)source;
- (void)addStandardError:(NSString*)text source:(NSString*)source;
- (void)addEvent:(NSString*)text source:(NSString*)source;
- (void)clear;
@end
