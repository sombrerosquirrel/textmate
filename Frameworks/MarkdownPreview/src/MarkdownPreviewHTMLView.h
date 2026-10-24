// Shows HTML from the GitHub renderer in a web view with GitHub’s styles.
//
// Web content can’t run JavaScript; only our own scripts (updating the content
// and scrolling) run, in a separate world. Local files, such as images, are
// served from below `readAccessURL` only, through a private URL scheme.

@class MarkdownPreviewHTMLView;

@protocol MarkdownPreviewHTMLViewDelegate <NSObject>
- (void)HTMLView:(MarkdownPreviewHTMLView*)view openURL:(NSURL*)url; // file URLs for local links
@optional
- (void)HTMLViewDidUpdateAnchors:(MarkdownPreviewHTMLView*)view;
- (void)HTMLView:(MarkdownPreviewHTMLView*)view didScrollToPosition:(CGFloat)y fraction:(CGFloat)fraction; // by the user or a link, not by the methods below
@end

@interface MarkdownPreviewHTMLView : NSView
@property (nonatomic, weak) id<MarkdownPreviewHTMLViewDelegate> delegate;

// `body` is the HTML for the document at `documentURL` (a file URL, or nil if
// unsaved). Showing a new body for the same document keeps the scroll position.
- (void)showHTML:(NSString*)body documentURL:(NSURL*)documentURL readAccessURL:(NSURL*)readAccessURL;

// Where source lines start on the page, as NSPoint (x: line, y: position),
// ascending; empty without source positions. Updated after the content
// changes and when the layout does, e.g. as images load.
@property (nonatomic, readonly) NSArray<NSValue*>* anchors;

// Scrolls so `y` is at the top of the page, or `fraction` (0–1) of the way
// down. Animated, jumps of more than half the view ease there.
- (void)scrollToPosition:(CGFloat)y animated:(BOOL)animated;
- (void)scrollToFraction:(CGFloat)fraction animated:(BOOL)animated;

// For tests: calls `completion` once the latest HTML is shown
- (void)evaluateJavaScript:(NSString*)script completionHandler:(void(^)(id result, NSError* error))completion;
@end
