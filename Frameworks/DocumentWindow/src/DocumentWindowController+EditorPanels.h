#import "DocumentWindowController.h"

@class OakEditorPanelsView;

// The container holding the editor and the panels docked to its edges (agent
// chat, Markdown preview). It replaces the editor as the layout view’s
// document view.

@interface DocumentWindowController (EditorPanels)
@property (nonatomic, readonly) OakEditorPanelsView* editorPanelsView;
- (void)setupEditorPanels; // once, after the layout view exists
@end
