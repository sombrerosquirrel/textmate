// A read-only, rendered view of a Markdown document, shown beside the editor.
// It doesn’t know about documents or windows: the window controller feeds it
// Markdown text (built-in renderer) or HTML (GitHub renderer) and decides what
// links do.
//
// The header has a popup for the renderer, bound to the user defaults, and a
// line for notices such as “cmark-gfm isn’t installed”.

@class MarkdownPreviewViewController;

@protocol MarkdownPreviewDelegate <NSObject>
- (void)markdownPreview:(MarkdownPreviewViewController*)preview openURL:(NSURL*)url;
@optional
- (void)markdownPreviewPerformNoticeAction:(MarkdownPreviewViewController*)preview;
- (void)markdownPreviewDidUpdateAnchors:(MarkdownPreviewViewController*)preview; // re-sync the scroll position
@end

@interface MarkdownPreviewViewController : NSViewController
@property (nonatomic, weak) id<MarkdownPreviewDelegate> delegate;

// `baseURL` (the document’s file URL) resolves relative links and images.
// Re-rendering keeps the scroll position, so this can be called as the user types.
- (void)showMarkdown:(NSString*)markdown baseURL:(NSURL*)baseURL;
// HTML from the GitHub renderer. Local files are only loaded from below `readAccessURL`.
- (void)showHTML:(NSString*)html documentURL:(NSURL*)documentURL readAccessURL:(NSURL*)readAccessURL;
- (void)showPlaceholder:(NSString*)message;

// A notice in the header, with an optional button that calls the delegate. Pass nil to hide it.
- (void)showNotice:(NSString*)notice actionTitle:(NSString*)actionTitle;

// Where each source line with a known position starts in the preview, as
// NSPoint: x is the 1-based line, y the position from the top; both
// ascending. Empty without source positions (e.g. output of a TM_MARKDOWN
// command). The editor maps its own scroll position through these.
@property (nonatomic, readonly) NSArray<NSValue*>* anchors;

// Scrolls so `y` (as in `anchors`) is at the top. Animated, a jump of more
// than half the view (e.g. Page Down in the editor) eases there over a few
// frames; smaller steps, as when scrolling, are followed exactly.
- (void)scrollToPosition:(CGFloat)y animated:(BOOL)animated;
// Without anchors: 0 at the top, 1 at the bottom
- (void)scrollToFraction:(CGFloat)fraction animated:(BOOL)animated;

@property (nonatomic, readonly) NSString* renderedText; // what’s shown, for tests
@property (nonatomic, readonly) NSString* notice;       // for tests
@property (nonatomic, readonly) BOOL showsHTML;         // for tests
@property (nonatomic) CGFloat scrollFraction;           // built-in view: 0 at the top, 1 at the bottom
@end
