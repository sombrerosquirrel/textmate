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
- (void)markdownPreviewDidUpdateAnchorLines:(MarkdownPreviewViewController*)preview; // re-sync the scroll position
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

// `line` (1-based, may be fractional) is the editor’s first visible line;
// the HTML view uses it when the renderer gives source positions. The
// built-in view scrolls by `fraction` (0 at the top, 1 at the bottom).
- (void)scrollToSourceLine:(CGFloat)line fraction:(CGFloat)fraction;

// Source lines whose position in the preview is known, ascending (empty if
// none). Between two of them the preview interpolates, so the editor can map
// its own position between the same lines by pixels, for even scrolling.
@property (nonatomic, readonly) NSArray<NSNumber*>* anchorLines;

@property (nonatomic, readonly) NSString* renderedText; // what’s shown, for tests
@property (nonatomic, readonly) NSString* notice;       // for tests
@property (nonatomic, readonly) BOOL showsHTML;         // for tests
@property (nonatomic) CGFloat scrollFraction;           // built-in view: 0 at the top, 1 at the bottom
@end
