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
	AgentTranscriptItemKindPermission,
	AgentTranscriptItemKindWaiting,     // says what’s awaited until something else shows; empty after that
};

@interface AgentTranscriptItem : NSObject
@property (nonatomic, readonly) AgentTranscriptItemKind kind;
@property (nonatomic, readonly) NSString* identifier;      // unique within the transcript
@property (nonatomic, readonly) NSString* text;            // Markdown for agent and thought items, plain text otherwise
@property (nonatomic, readonly) NSArray<NSString*>* attachmentNames;   // user items
@property (nonatomic, readonly) NSDictionary* toolCall;    // tool call items: merged tool_call / tool_call_update fields
@property (nonatomic, readonly) NSArray<NSDictionary*>* planEntries;  // plan items: { content, priority, status }
@property (nonatomic) BOOL expanded;                       // thought items: show the thinking text; tool calls: the whole diff or output
@property (nonatomic) BOOL folded;                         // agent, tool call and plan items: shown as one line
@property (nonatomic) BOOL foldsWhenPassed;                // agent items: fold once newer replies have passed them

// Permission items: the session/request_permission params ({ toolCall, options }),
// and the user’s answer once given (selectedOptionId nil means cancelled).
@property (nonatomic, readonly) NSDictionary* permissionRequest;
@property (nonatomic, readonly, getter = isPermissionResolved) BOOL permissionResolved;
@property (nonatomic, readonly) NSString* selectedOptionId;
// The option ↩ / ⎋ choose: allow_once / reject_once, or else the first that
// allows / rejects; nil if there is none.
- (NSString*)permissionOptionIdAllowing:(BOOL)allow;
// Notice and error items: links shown below the text, { action, title },
// e.g. @{ @"action": @"signIn", @"title": @"Sign In" }.
@property (nonatomic, copy) NSArray<NSDictionary<NSString*, NSString*>*>* actions;
@end

// Output of a command the agent runs itself, reported in its tool call’s
// `_meta` (Claude Code: terminal_info, terminal_output(_delta), terminal_exit).
@interface AgentTranscriptTerminal : NSObject
@property (nonatomic, readonly) NSString* terminalId;
@property (nonatomic, readonly) NSString* output;
@property (nonatomic, readonly, getter = hasExited) BOOL exited;
@property (nonatomic, readonly) NSNumber* exitCode;
@property (nonatomic, readonly) NSString* signal;
@end

@interface AgentTranscript : NSObject
@property (nonatomic, readonly) NSArray<AgentTranscriptItem*>* items;
@property (nonatomic) BOOL foldsNewItems; // items to come start folded, but replies only once newer ones pass them

- (AgentTranscriptItem*)addUserMessage:(NSString*)text attachmentNames:(NSArray<NSString*>*)attachmentNames;
- (AgentTranscriptItem*)addNotice:(NSString*)text;
- (AgentTranscriptItem*)addError:(NSString*)text;
- (AgentTranscriptItem*)addWaitingLine:(NSString*)text;
- (void)endWaitingLine:(AgentTranscriptItem*)item;
- (AgentTranscriptItem*)addNotice:(NSString*)text actions:(NSArray<NSDictionary<NSString*, NSString*>*>*)actions;
- (AgentTranscriptItem*)addError:(NSString*)text actions:(NSArray<NSDictionary<NSString*, NSString*>*>*)actions;
- (AgentTranscriptItem*)addPermissionRequest:(NSDictionary*)params;
// `optionId` nil: the request was cancelled.
- (void)resolvePermissionItem:(AgentTranscriptItem*)item selectedOptionId:(NSString*)optionId;
@property (nonatomic, readonly) NSArray<AgentTranscriptItem*>* pendingPermissionItems;

// Applies the `update` object of a session/update notification. Returns the
// item that was created or changed, or nil if the update isn’t shown in the
// transcript (e.g. available_commands_update).
- (AgentTranscriptItem*)applyUpdate:(NSDictionary*)update;

- (AgentTranscriptTerminal*)terminalWithIdentifier:(NSString*)terminalId;

// Folds the agent, tool call and plan items before `item` (all of them
// if nil) and closes their thinking, e.g. when a new message is sent.
- (void)foldItemsBeforeItem:(AgentTranscriptItem*)item;
- (AgentTranscriptItem*)toolCallItemWithIdentifier:(NSString*)toolCallId;
// Folds the replies with foldsWhenPassed that newer replies have passed and
// returns them
- (NSArray<AgentTranscriptItem*>*)foldPassedReplies;
// Folds or opens every item with a ▾ / ▸
- (void)setAllItemsFolded:(BOOL)flag;
// The item of the last user message, nil if there is none.
@property (nonatomic, readonly) AgentTranscriptItem* lastUserItem;

- (void)removeAllItems;
@end
