// Conversation model for the agent panel: turns ACP session/update
// notifications into a list of items (messages, thinking, tool calls, plans,
// notices) that the transcript view renders.

typedef NS_ENUM(NSInteger, AgentTranscriptItemKind) {
	AgentTranscriptItemKindUser = 0,
	AgentTranscriptItemKindAgent,
	AgentTranscriptItemKindThought,
	AgentTranscriptItemKindToolCall,
	AgentTranscriptItemKindPlan,
	AgentTranscriptItemKindNotice,
	AgentTranscriptItemKindError,
};

@interface AgentTranscriptItem : NSObject
@property (nonatomic, readonly) AgentTranscriptItemKind kind;
@property (nonatomic, readonly) NSString* identifier;      // unique within the transcript
@property (nonatomic, readonly) NSString* text;            // Markdown for agent and thought items, plain text otherwise
@property (nonatomic, readonly) NSArray<NSString*>* attachmentNames;   // user items
@property (nonatomic, readonly) NSDictionary* toolCall;    // tool call items: merged tool_call / tool_call_update fields
@property (nonatomic, readonly) NSArray<NSDictionary*>* planEntries;  // plan items: { content, priority, status }
@property (nonatomic) BOOL expanded;                       // thought items: show the thinking text
@end

@interface AgentTranscript : NSObject
@property (nonatomic, readonly) NSArray<AgentTranscriptItem*>* items;

- (AgentTranscriptItem*)addUserMessage:(NSString*)text attachmentNames:(NSArray<NSString*>*)attachmentNames;
- (AgentTranscriptItem*)addNotice:(NSString*)text;
- (AgentTranscriptItem*)addError:(NSString*)text;

// Applies the `update` object of a session/update notification. Returns the
// item that was created or changed, or nil if the update isn’t shown in the
// transcript (e.g. available_commands_update).
- (AgentTranscriptItem*)applyUpdate:(NSDictionary*)update;

- (void)removeAllItems;
@end
