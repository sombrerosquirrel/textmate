// Inline chat: a small prompt shown in a popover at the editor’s caret. The
// agent panel sends the request in its chat and reports back here: progress,
// permission requests (the panel may be hidden), and the outcome with the
// files that changed. Both show the changes’ diffs.

@class AgentInlinePromptController;

@protocol AgentInlinePromptDelegate <NSObject>
- (void)inlinePrompt:(AgentInlinePromptController*)inlinePrompt submitText:(NSString*)text;
- (void)inlinePromptStop:(AgentInlinePromptController*)inlinePrompt;
- (void)inlinePrompt:(AgentInlinePromptController*)inlinePrompt answerPermission:(BOOL)allow;
- (void)inlinePromptKeepChanges:(AgentInlinePromptController*)inlinePrompt;
- (void)inlinePromptUndoChanges:(AgentInlinePromptController*)inlinePrompt;
- (void)inlinePromptShowChat:(AgentInlinePromptController*)inlinePrompt;
@end

@interface AgentInlinePromptController : NSViewController
- (instancetype)initWithAgentName:(NSString*)agentName context:(NSString*)context; // context: e.g. “main.cc:12–20”
@property (nonatomic, weak) id<AgentInlinePromptDelegate> delegate;

- (void)showInPopoverRelativeToRect:(NSRect)rect ofView:(NSView*)view;
- (void)close;
@property (nonatomic, readonly, getter = isShown) BOOL shown;

- (void)showWorking:(NSString*)status;                 // e.g. the running tool call’s title
// A file’s change, as in an ACP diff: “path” (here a display name), “oldText”
// (absent for a new file) and “newText” (absent for a deleted one)
- (void)showPermissionRequest:(NSString*)title changes:(NSArray<NSDictionary*>*)changes;
// `changes` can be undone; `reply` is the agent’s answer.
- (void)showFinishedWithChanges:(NSArray<NSDictionary*>*)changes reply:(NSString*)reply;
- (void)showFailure:(NSString*)message;
@end
