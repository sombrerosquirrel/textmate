#import "DocumentWindowController.h"

// A rendered preview of the selected Markdown document, docked on any edge of
// the editor (by default opposite the agent panel). It updates as you type,
// from the unsaved text, and scrolls with the editor. While a non-Markdown
// document is selected the panel is suspended (hidden, keeping its place and
// size), like any preview panel.

extern NSString* const kUserDefaultsMarkdownPreviewPlacementKey; // @"auto" (default), @"left", @"right", @"top" or @"bottom"

@interface DocumentWindowController (MarkdownPreview)
@property (nonatomic) BOOL markdownPreviewVisible;
@property (nonatomic, readonly) BOOL markdownPreviewHasFocus;

- (void)updateMarkdownPreviewPlacement; // after user defaults change
- (void)shutdownMarkdownPreview;        // when the window closes
- (BOOL)isMarkdownPreviewMenuItem:(NSMenuItem*)menuItem;
- (BOOL)validateMarkdownPreviewMenuItem:(NSMenuItem*)menuItem;

- (IBAction)toggleMarkdownPreview:(id)sender;
- (IBAction)takeMarkdownPreviewPlacementFrom:(id)sender; // sender’s tag: 0 automatic, 1 left, 2 right, 3 top, 4 bottom
@end
