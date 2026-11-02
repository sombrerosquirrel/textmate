// Shows HTML from the GitHub renderer in a web view with GitHub’s styles.
//
// Web content can’t run JavaScript; only our own scripts (updating the content
// and reporting its layout) run, in a separate world. Local files, such as images, are
// served from below `readAccessURL` only, through a private URL scheme.
//
// The web view is as tall as the page, in a scroll view, so the preview scrolls
// it as it does the built-in view: with the editor, in the app. A web view
// scrolling itself does so in another process, frames behind and unevenly.

// Key equivalents reach every view and the menus before keyDown:, and some use
// these scrolling keys, e.g. ⌘↑ for Go ▸ Enclosing Folder, so the previews take
// them first while they have focus. Space with or without shift, ⌘↑, ⌘↓.
inline BOOL MarkdownPreviewIsScrollKeyEquivalent (NSEvent* anEvent)
{
	NSEventModifierFlags const modifiers = anEvent.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl);
	NSString* key = anEvent.charactersIgnoringModifiers;
	if(modifiers == 0)
		return [key isEqualToString:@" "];
	return modifiers == NSEventModifierFlagCommand && key.length == 1 && ([key characterAtIndex:0] == NSUpArrowFunctionKey || [key characterAtIndex:0] == NSDownArrowFunctionKey);
}

@class MarkdownPreviewHTMLView;

@protocol MarkdownPreviewHTMLViewDelegate <NSObject>
- (void)HTMLView:(MarkdownPreviewHTMLView*)view openURL:(NSURL*)url; // file URLs for local links
@optional
- (void)HTMLViewDidUpdateAnchors:(MarkdownPreviewHTMLView*)view;
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

@property (nonatomic, readonly) NSScrollView* scrollView;
@property (nonatomic, readonly, getter = isResizing) BOOL resizing; // the page’s height is changing, so scrolling isn’t the user’s

// For tests: calls `completion` once the latest HTML is shown
- (void)evaluateJavaScript:(NSString*)script completionHandler:(void(^)(id result, NSError* error))completion;
@end
