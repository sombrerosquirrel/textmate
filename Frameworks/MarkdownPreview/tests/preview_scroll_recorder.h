#ifndef PREVIEW_SCROLL_RECORDER_H_4A9E03
#define PREVIEW_SCROLL_RECORDER_H_4A9E03

#import <MarkdownPreview/MarkdownPreviewViewController.h>
#import <MarkdownPreview/MarkdownPreviewHTMLView.h>

// Records the scroll positions the preview reports (test runner bodies can’t declare classes)
@interface PreviewScrollRecorder : NSObject <MarkdownPreviewDelegate, MarkdownPreviewHTMLViewDelegate>
@property (nonatomic) NSMutableArray<NSNumber*>* positions;
@end

@implementation PreviewScrollRecorder
- (void)markdownPreview:(MarkdownPreviewViewController*)preview openURL:(NSURL*)url { }
- (void)markdownPreview:(MarkdownPreviewViewController*)preview didScrollToPosition:(CGFloat)y fraction:(CGFloat)fraction
{
	[_positions addObject:@(y)];
}

- (void)HTMLView:(MarkdownPreviewHTMLView*)view openURL:(NSURL*)url { }
- (void)HTMLView:(MarkdownPreviewHTMLView*)view didScrollToPosition:(CGFloat)y fraction:(CGFloat)fraction
{
	[_positions addObject:@(y)];
}
@end

#endif /* end of include guard: PREVIEW_SCROLL_RECORDER_H_4A9E03 */
