#import "MarkdownPreviewViewController.h"
#import <OakMarkdown/OakMarkdown.h>

static CGFloat const kTextInset = 16;

@interface MarkdownPreviewViewController () <NSTextViewDelegate>
{
	NSScrollView* _scrollView;
	NSTextView* _textView;
	NSTextField* _placeholder;
	OakMarkdownStyle* _style;

	NSString* _markdown;
	NSURL* _baseURL;
	CGFloat _renderedWidth;
}
@end

@implementation MarkdownPreviewViewController
- (void)loadView
{
	_style = [OakMarkdownStyle defaultStyle];
	_style.font     = [NSFont systemFontOfSize:NSFont.systemFontSize + 1];
	_style.codeFont = [NSFont monospacedSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];

	_scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
	_scrollView.hasVerticalScroller   = YES;
	_scrollView.hasHorizontalScroller = NO;
	_scrollView.borderType            = NSNoBorder;
	_scrollView.drawsBackground       = YES;
	_scrollView.backgroundColor       = NSColor.textBackgroundColor;
	_scrollView.autoresizingMask      = NSViewWidthSizable|NSViewHeightSizable;

	NSTextStorage* textStorage     = [[NSTextStorage alloc] init];
	NSLayoutManager* layoutManager = [[NSLayoutManager alloc] init];
	[textStorage addLayoutManager:layoutManager];

	// TextKit 1 is required for NSTextBlock backgrounds and NSTextTable
	NSTextContainer* textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(_scrollView.contentSize.width, CGFLOAT_MAX)];
	textContainer.widthTracksTextView = YES;
	[layoutManager addTextContainer:textContainer];

	_textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, _scrollView.contentSize.width, _scrollView.contentSize.height) textContainer:textContainer];
	_textView.minSize               = NSMakeSize(0, _scrollView.contentSize.height);
	_textView.maxSize               = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
	_textView.verticallyResizable   = YES;
	_textView.horizontallyResizable = NO;
	_textView.autoresizingMask      = NSViewWidthSizable;
	_textView.editable              = NO;
	_textView.selectable            = YES;
	_textView.richText              = YES;
	_textView.usesFindBar           = YES;
	_textView.incrementalSearchingEnabled = YES;
	_textView.drawsBackground       = YES;
	_textView.backgroundColor       = NSColor.textBackgroundColor;
	_textView.textContainerInset    = NSMakeSize(kTextInset, kTextInset);
	_textView.linkTextAttributes    = @{ NSForegroundColorAttributeName: NSColor.linkColor, NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle), NSCursorAttributeName: NSCursor.pointingHandCursor };
	_textView.delegate              = self;
	_scrollView.documentView = _textView;

	_placeholder = [NSTextField wrappingLabelWithString:@""];
	_placeholder.textColor = NSColor.secondaryLabelColor;
	_placeholder.alignment = NSTextAlignmentCenter;
	_placeholder.translatesAutoresizingMaskIntoConstraints = NO;
	_placeholder.hidden = YES;

	NSView* view = [[NSView alloc] initWithFrame:_scrollView.frame];
	[view addSubview:_scrollView];
	[view addSubview:_placeholder];
	[NSLayoutConstraint activateConstraints:@[
		[_placeholder.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
		[_placeholder.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
		[_placeholder.widthAnchor constraintLessThanOrEqualToAnchor:view.widthAnchor constant:-2*kTextInset],
	]];
	self.view = view;
}

- (NSString*)renderedText
{
	[self view];
	return _placeholder.hidden ? _textView.string : _placeholder.stringValue;
}

// =============
// = Rendering =
// =============

- (void)showMarkdown:(NSString*)markdown baseURL:(NSURL*)baseURL
{
	[self view];
	_markdown = [markdown copy];
	_baseURL  = baseURL;
	[self render];
}

- (void)showPlaceholder:(NSString*)message
{
	[self view];
	_markdown = nil;
	_baseURL  = nil;
	_placeholder.stringValue = message;
	_placeholder.hidden = NO;
	_scrollView.hidden  = YES;
	[_textView.textStorage setAttributedString:[[NSAttributedString alloc] init]];
}

- (CGFloat)availableWidth
{
	return MAX(0, NSWidth(_textView.frame) - 2*kTextInset - 2*_textView.textContainer.lineFragmentPadding);
}

- (void)render
{
	if(!_markdown)
		return;

	_placeholder.hidden = YES;
	_scrollView.hidden  = NO;

	_renderedWidth = [self availableWidth];
	_style.maximumImageWidth = _renderedWidth;

	NSPoint scrollOrigin = _scrollView.contentView.bounds.origin;
	[_textView.textStorage setAttributedString:[OakMarkdownRenderer attributedStringFromMarkdown:_markdown style:_style baseURL:_baseURL codeBlocks:nullptr codeBlockFooter:nil]];

	// Keep the scroll position, so the preview doesn’t jump while typing
	[_textView.layoutManager ensureLayoutForTextContainer:_textView.textContainer];
	[_textView sizeToFit];
	CGFloat maxY = MAX(0, NSHeight(_textView.frame) - NSHeight(_scrollView.contentView.bounds));
	[_scrollView.contentView scrollToPoint:NSMakePoint(0, MIN(scrollOrigin.y, maxY))];
	[_scrollView reflectScrolledClipView:_scrollView.contentView];
}

// Images are scaled to the width, so re-render when it changes
- (void)viewDidLayout
{
	[super viewDidLayout];
	if(_markdown && fabs([self availableWidth] - _renderedWidth) >= 1)
	{
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(render) object:nil];
		[self performSelector:@selector(render) withObject:nil afterDelay:0.1];
	}
}

// =============
// = Scrolling =
// =============

- (CGFloat)scrollableHeight
{
	return MAX(0, NSHeight(_textView.frame) - NSHeight(_scrollView.contentView.bounds));
}

- (CGFloat)scrollFraction
{
	CGFloat height = [self scrollableHeight];
	return height > 0 ? MIN(MAX(NSMinY(_scrollView.contentView.bounds) / height, 0), 1) : 0;
}

- (void)setScrollFraction:(CGFloat)fraction
{
	[self view];
	CGFloat y = round(MIN(MAX(fraction, 0), 1) * [self scrollableHeight]);
	[_scrollView.contentView scrollToPoint:NSMakePoint(0, y)];
	[_scrollView reflectScrolledClipView:_scrollView.contentView];
}

// =========
// = Links =
// =========

- (BOOL)textView:(NSTextView*)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex
{
	NSURL* url = [link isKindOfClass:[NSURL class]] ? link : [NSURL URLWithString:[link description] relativeToURL:_baseURL];
	if(url)
		[self.delegate markdownPreview:self openURL:url.absoluteURL];
	return YES;
}
@end
