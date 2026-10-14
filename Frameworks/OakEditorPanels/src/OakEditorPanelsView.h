// Holds the editor and any panels docked to its edges (agent chat, Markdown
// preview, …). Used in place of the editor view in the project window, so the
// file browser stays outside and panels stack next to the editor.
//
// Left and right panels span the full height; top and bottom panels span the
// editor column only. Panels on the same edge are ordered outermost first:
//
//   [left₁ | left₂ | [top₁ / editor / bottom₁] | right₂ | right₁]
//
// Uses Auto Layout constraints (like ProjectLayoutView) rather than
// NSSplitView, because the editor (OakDocumentView) is laid out with
// constraints and has required minimum sizes.

typedef NS_ENUM(NSUInteger, OakEditorPanelEdge) {
	OakEditorPanelEdgeLeft,
	OakEditorPanelEdgeRight,
	OakEditorPanelEdgeTop,
	OakEditorPanelEdgeBottom,
};

@interface OakEditorPanel : NSObject
- (instancetype)initWithView:(NSView*)view edge:(OakEditorPanelEdge)edge;
@property (nonatomic, readonly) NSView* view;
@property (nonatomic) OakEditorPanelEdge edge;

// Preferred sizes. The editor’s minimum size always wins, and the window is
// never forced to grow to fit a panel.
@property (nonatomic) CGFloat width;          // used on the left or right
@property (nonatomic) CGFloat height;         // used on the top or bottom
@property (nonatomic) CGFloat minimumWidth;   // default 200
@property (nonatomic) CGFloat minimumHeight;  // default 100

// When set, the sizes are read from and saved to user defaults as
// ‹autosaveName›Width and ‹autosaveName›Height
@property (nonatomic, copy) NSString* autosaveName;
@end

@interface OakEditorPanelsView : NSView
- (instancetype)initWithEditorView:(NSView*)editorView;
@property (nonatomic, readonly) NSView* editorView;
@property (nonatomic, readonly) NSArray<OakEditorPanel*>* panels;

- (void)addPanel:(OakEditorPanel*)panel;      // placed inside earlier panels on the same edge
- (void)removePanel:(OakEditorPanel*)panel;
@end
