// Holds the editor and, when shown, the agent panel beside it — on the left
// or right. Used in place of the editor view in the project window, so the
// file browser (outside) and the agent panel (next to the editor) stack.

extern NSString* const kUserDefaultsAgentPanelPlacementKey; // @"left" or @"right" (default)
extern NSString* const kUserDefaultsAgentPanelWidthKey;

@interface AgentEditorSplitView : NSSplitView
- (instancetype)initWithEditorView:(NSView*)editorView;
@property (nonatomic, readonly) NSView* editorView;
@property (nonatomic) NSView* panelView;          // nil hides the panel
@property (nonatomic) BOOL panelOnRight;
@end
