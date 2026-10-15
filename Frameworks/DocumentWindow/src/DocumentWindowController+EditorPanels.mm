#import "DocumentWindowController+EditorPanels.h"
#import "ProjectLayoutView.h"
#import <OakEditorPanels/OakEditorPanelsView.h>
#import <OakTextView/OakDocumentView.h>

// Private properties of DocumentWindowController, defined in its main file
@interface DocumentWindowController (EditorPanelsPrivate)
@property (nonatomic) ProjectLayoutView* layoutView;
@property (nonatomic) OakDocumentView* documentView;
@end

@implementation DocumentWindowController (EditorPanels)
- (OakEditorPanelsView*)editorPanelsView
{
	return [self.layoutView.documentView isKindOfClass:[OakEditorPanelsView class]] ? (OakEditorPanelsView*)self.layoutView.documentView : nil;
}

- (void)setupEditorPanels
{
	if(!self.editorPanelsView)
		self.layoutView.documentView = [[OakEditorPanelsView alloc] initWithEditorView:self.documentView];
}
@end
