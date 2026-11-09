// Inline chat: a small prompt shown in a popover at the editor’s caret. The
// agent panel sends the request in its chat and reports back here: progress,
// permission requests (the panel may be hidden), and the outcome with the
// files that changed. Both show the changes’ diffs.

@class AgentInlinePromptController;

typedef NS_ENUM(NSInteger, AgentInlineInsertMode) {
	AgentInlineInsertAtCursor,
	AgentInlineInsertReplacingSelection, // the selection the request was about
	AgentInlineInsertAfterLastInsertion, // a further insert, on the line after the previous one
};

@protocol AgentInlinePromptDelegate <NSObject>
- (void)inlinePrompt:(AgentInlinePromptController*)inlinePrompt submitText:(NSString*)text;
- (void)inlinePromptStop:(AgentInlinePromptController*)inlinePrompt;
- (void)inlinePrompt:(AgentInlinePromptController*)inlinePrompt answerPermission:(BOOL)allow;
- (void)inlinePromptKeepChanges:(AgentInlinePromptController*)inlinePrompt;
- (void)inlinePromptUndoChanges:(AgentInlinePromptController*)inlinePrompt;
- (void)inlinePromptShowChat:(AgentInlinePromptController*)inlinePrompt;
// The reply’s code. The popover stays open, so this can come again.
- (void)inlinePrompt:(AgentInlinePromptController*)inlinePrompt insertText:(NSString*)text mode:(AgentInlineInsertMode)mode;
@end

@interface AgentInlinePromptController : NSViewController
- (instancetype)initWithAgentName:(NSString*)agentName context:(NSString*)context; // context: e.g. “main.cc:12–20”
@property (nonatomic, weak) id<AgentInlinePromptDelegate> delegate;
@property (nonatomic) BOOL replacesSelection; // the request is about a selection: offer Replace Selection, not Insert at Cursor

- (void)showInPopoverRelativeToRect:(NSRect)rect ofView:(NSView*)view;
- (void)close;
- (void)moveToRect:(NSRect)rect; // to the line of `rect` (in the view it was shown for), keeping its x; ignored if empty
@property (nonatomic, readonly, getter = isShown) BOOL shown;

- (void)showWorking:(NSString*)status;                 // e.g. the running tool call’s title
// A file’s change, as in an ACP diff: “path” (here a display name), “oldText”
// (absent for a new file) and “newText” (absent for a deleted one)
- (void)showPermissionRequest:(NSString*)title changes:(NSArray<NSDictionary*>*)changes;
// `changes` can be undone; `reply` is the agent’s answer, as Markdown. Its code
// blocks can be copied and, with no changes, inserted, as often as wanted;
// with several, checkboxes choose which. Text selected in the reply wins.
- (void)showFinishedWithChanges:(NSArray<NSDictionary*>*)changes reply:(NSString*)reply;
- (void)showFailure:(NSString*)message;
@end
