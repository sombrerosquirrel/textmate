// Inline chat: a small prompt shown in a popover at the editor’s caret. The
// agent panel sends the request in its chat and reports back here: progress,
// permission requests (the panel may be hidden), and the outcome with the
// files that changed.

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
- (void)showPermissionRequest:(NSString*)title;
// `changedFiles` (display names) can be undone; `reply` is the agent’s answer.
- (void)showFinishedWithChangedFiles:(NSArray<NSString*>*)changedFiles reply:(NSString*)reply;
- (void)showFailure:(NSString*)message;
@end
