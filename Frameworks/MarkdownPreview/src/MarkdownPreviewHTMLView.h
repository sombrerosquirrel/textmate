// Shows HTML from the GitHub renderer in a web view with GitHub’s styles.
//
// Web content can’t run JavaScript; only our own scripts (updating the content
// and scrolling) run, in a separate world. Local files, such as images, are
// served from below `readAccessURL` only, through a private URL scheme.

@class MarkdownPreviewHTMLView;

@protocol MarkdownPreviewHTMLViewDelegate <NSObject>
- (void)HTMLView:(MarkdownPreviewHTMLView*)view openURL:(NSURL*)url; // file URLs for local links
@optional
- (void)HTMLViewDidUpdateAnchorLines:(MarkdownPreviewHTMLView*)view;
@end

@interface MarkdownPreviewHTMLView : NSView
@property (nonatomic, weak) id<MarkdownPreviewHTMLViewDelegate> delegate;

// `body` is the HTML for the document at `documentURL` (a file URL, or nil if
// unsaved). Showing a new body for the same document keeps the scroll position.
- (void)showHTML:(NSString*)body documentURL:(NSURL*)documentURL readAccessURL:(NSURL*)readAccessURL;

// `line` is 1-based and may be fractional; it’s matched to the elements’
// source positions. Without source positions, `fraction` of the page is used.
- (void)scrollToSourceLine:(CGFloat)line fraction:(CGFloat)fraction;

// The source lines whose position on the page is known, ascending; empty
// without source positions. Updated after the content changes.
@property (nonatomic, readonly) NSArray<NSNumber*>* anchorLines;

// For tests: calls `completion` once the latest HTML is shown
- (void)evaluateJavaScript:(NSString*)script completionHandler:(void(^)(id result, NSError* error))completion;
@end
