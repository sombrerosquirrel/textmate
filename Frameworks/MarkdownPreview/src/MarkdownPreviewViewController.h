// A read-only, rendered view of a Markdown document, shown beside the editor.
// It doesn’t know about documents or windows: the window controller feeds it
// Markdown text and decides what links do.

@class MarkdownPreviewViewController;

@protocol MarkdownPreviewDelegate <NSObject>
- (void)markdownPreview:(MarkdownPreviewViewController*)preview openURL:(NSURL*)url;
@end

@interface MarkdownPreviewViewController : NSViewController
@property (nonatomic, weak) id<MarkdownPreviewDelegate> delegate;

// `baseURL` (the document’s file URL) resolves relative links and images.
// Re-rendering keeps the scroll position, so this can be called as the user types.
- (void)showMarkdown:(NSString*)markdown baseURL:(NSURL*)baseURL;
- (void)showPlaceholder:(NSString*)message;

@property (nonatomic, readonly) NSString* renderedText; // what’s shown, for tests
@property (nonatomic) CGFloat scrollFraction;           // 0 at the top, 1 at the bottom
@end
