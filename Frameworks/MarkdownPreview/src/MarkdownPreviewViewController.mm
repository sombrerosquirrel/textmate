#import "MarkdownPreviewViewController.h"
#import "MarkdownPreviewHTMLView.h"
#import "MarkdownPreviewInterpolation.h"
#import <OakMarkdown/OakMarkdown.h>
#import <OakFoundation/OakStringListTransformer.h>
#import <Preferences/Keys.h>

static CGFloat const kTextInset = 16;
static NSString* const kRendererTransformerName = @"OakMarkdownPreviewRendererSettingsTransformer";

@interface MarkdownPreviewViewController () <NSTextViewDelegate, MarkdownPreviewHTMLViewDelegate>
{
	NSView* _contentView; // below the header
	NSScrollView* _scrollView;
	NSTextView* _textView;
	MarkdownPreviewHTMLView* _htmlView;
	NSTextField* _placeholder;
	OakMarkdownStyle* _style;

	NSPopUpButton* _rendererPopUp;
	NSTextField* _noticeLabel;
	NSButton* _noticeButton;

	NSString* _markdown;
	NSURL* _baseURL;
	CGFloat _renderedWidth;
	std::vector<std::pair<CGFloat, CGFloat>> _anchors; // source line → y in the text view, both increasing
}
@end

@implementation MarkdownPreviewViewController
+ (void)initialize
{
	[OakStringListTransformer createTransformerWithName:kRendererTransformerName andObjectsArray:@[ @"builtin", @"github" ]];
}

- (NSView*)makeHeaderView
{
	_rendererPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_rendererPopUp.bordered    = NO;
	_rendererPopUp.controlSize = NSControlSizeSmall;
	_rendererPopUp.font        = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	_rendererPopUp.toolTip     = @"Renderer: built-in, or GitHub’s parser (cmark-gfm)";
	[_rendererPopUp addItemsWithTitles:@[ @"Built-in", @"GitHub" ]];
	_rendererPopUp.itemArray[0].tag = 0;
	_rendererPopUp.itemArray[1].tag = 1;
	[_rendererPopUp bind:NSSelectedTagBinding toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:[@"values." stringByAppendingString:kUserDefaultsMarkdownPreviewRendererKey] options:@{ NSValueTransformerNameBindingOption: kRendererTransformerName }];

	_noticeLabel = [NSTextField labelWithString:@""];
	_noticeLabel.font          = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	_noticeLabel.textColor     = NSColor.secondaryLabelColor;
	_noticeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
	[_noticeLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

	_noticeButton = [NSButton buttonWithTitle:@"" target:self action:@selector(performNoticeAction:)];
	_noticeButton.controlSize = NSControlSizeSmall;
	_noticeButton.font        = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];

	NSStackView* noticeStack = [NSStackView stackViewWithViews:@[ _noticeLabel, _noticeButton ]];
	noticeStack.spacing = 6;
	noticeStack.detachesHiddenViews = YES;
	noticeStack.hidden = YES;

	NSBox* divider = [[NSBox alloc] initWithFrame:NSZeroRect];
	divider.boxType = NSBoxSeparator;

	NSView* header = [[NSView alloc] initWithFrame:NSZeroRect];
	for(NSView* view in @[ noticeStack, _rendererPopUp, divider ])
	{
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[header addSubview:view];
	}
	[NSLayoutConstraint activateConstraints:@[
		[header.heightAnchor constraintEqualToConstant:26],
		[noticeStack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:10],
		[noticeStack.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
		[noticeStack.trailingAnchor constraintLessThanOrEqualToAnchor:_rendererPopUp.leadingAnchor constant:-8],
		[_rendererPopUp.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-6],
		[_rendererPopUp.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
		[divider.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
		[divider.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
		[divider.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
	]];
	return header;
}

- (void)loadView
{
	_style = [OakMarkdownStyle defaultStyle];
	_style.font     = [NSFont systemFontOfSize:NSFont.systemFontSize + 1];
	_style.codeFont = [NSFont monospacedSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
	_style.marksSourceLines = YES;

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

	_contentView = [[NSView alloc] initWithFrame:_scrollView.frame];
	_contentView.translatesAutoresizingMaskIntoConstraints = NO;
	[_contentView addSubview:_scrollView];
	[_contentView addSubview:_placeholder];

	NSView* header = [self makeHeaderView];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSView* view = [[NSView alloc] initWithFrame:_scrollView.frame];
	[view addSubview:header];
	[view addSubview:_contentView];
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor constraintEqualToAnchor:view.topAnchor],
		[header.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
		[header.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
		[_contentView.topAnchor constraintEqualToAnchor:header.bottomAnchor],
		[_contentView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
		[_contentView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
		[_contentView.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
		[_placeholder.centerXAnchor constraintEqualToAnchor:_contentView.centerXAnchor],
		[_placeholder.centerYAnchor constraintEqualToAnchor:_contentView.centerYAnchor],
		[_placeholder.widthAnchor constraintLessThanOrEqualToAnchor:_contentView.widthAnchor constant:-2*kTextInset],
	]];
	self.view = view;
}

- (void)dealloc
{
	[_rendererPopUp unbind:NSSelectedTagBinding];
}

- (NSString*)renderedText
{
	[self view];
	return _placeholder.hidden ? _textView.string : _placeholder.stringValue;
}

- (NSString*)notice
{
	[self view];
	return _noticeLabel.superview.hidden ? nil : _noticeLabel.stringValue;
}

- (BOOL)showsHTML
{
	return _htmlView && !_htmlView.hidden;
}

// ==========
// = Header =
// ==========

- (void)showNotice:(NSString*)notice actionTitle:(NSString*)actionTitle
{
	[self view];
	_noticeLabel.stringValue  = notice ?: @"";
	_noticeLabel.toolTip      = notice;
	_noticeButton.title       = actionTitle ?: @"";
	_noticeButton.hidden      = !actionTitle;
	_noticeLabel.superview.hidden = !notice;
}

- (void)performNoticeAction:(id)sender
{
	if([self.delegate respondsToSelector:@selector(markdownPreviewPerformNoticeAction:)])
		[self.delegate markdownPreviewPerformNoticeAction:self];
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

- (void)showHTML:(NSString*)html documentURL:(NSURL*)documentURL readAccessURL:(NSURL*)readAccessURL
{
	[self view];
	_markdown = nil;
	_baseURL  = nil;
	[_textView.textStorage setAttributedString:[[NSAttributedString alloc] init]];

	if(!_htmlView)
	{
		_htmlView = [[MarkdownPreviewHTMLView alloc] initWithFrame:_contentView.bounds];
		_htmlView.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
		_htmlView.delegate = self;
		[_contentView addSubview:_htmlView positioned:NSWindowBelow relativeTo:_placeholder];
	}

	_placeholder.hidden = YES;
	_scrollView.hidden  = YES;
	_htmlView.hidden    = NO;
	[_htmlView showHTML:html documentURL:documentURL readAccessURL:readAccessURL];
}

- (void)showPlaceholder:(NSString*)message
{
	[self view];
	_markdown = nil;
	_baseURL  = nil;
	_placeholder.stringValue = message;
	_placeholder.hidden = NO;
	_scrollView.hidden  = YES;
	_htmlView.hidden    = YES;
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
	_htmlView.hidden    = YES;

	_renderedWidth = [self availableWidth];
	_style.maximumImageWidth = _renderedWidth;

	NSPoint scrollOrigin = _scrollView.contentView.bounds.origin;
	[_textView.textStorage setAttributedString:[OakMarkdownRenderer attributedStringFromMarkdown:_markdown style:_style baseURL:_baseURL codeBlocks:nullptr codeBlockFooter:nil]];

	// Keep the scroll position, so the preview doesn’t jump while typing
	[_textView.layoutManager ensureLayoutForTextContainer:_textView.textContainer];
	[_textView sizeToFit];
	[self updateAnchors];
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

// Where the text from each marked source line starts; between two of them,
// positions are interpolated, so the view scrolls continuously with the editor
- (void)updateAnchors
{
	_anchors.clear();
	_anchors.emplace_back(1, 0);

	NSTextStorage* textStorage     = _textView.textStorage;
	NSLayoutManager* layoutManager = _textView.layoutManager;
	CGFloat const inset = _textView.textContainerOrigin.y;
	__block CGFloat lastLine = 1;
	auto anchorsPtr = &_anchors;
	[textStorage enumerateAttribute:OakMarkdownSourceLineAttributeName inRange:NSMakeRange(0, textStorage.length) options:0 usingBlock:^(NSNumber* line, NSRange range, BOOL* stop){
		if(!line)
			return;
		NSUInteger glyphIndex = [layoutManager glyphIndexForCharacterAtIndex:range.location];
		CGFloat y = NSMinY([layoutManager lineFragmentRectForGlyphAtIndex:glyphIndex effectiveRange:nullptr]) + inset;
		if(line.doubleValue > anchorsPtr->back().first && y > anchorsPtr->back().second)
			anchorsPtr->emplace_back(line.doubleValue, y);
		lastLine = MAX(lastLine, line.doubleValue);
	}];

	// The last line maps to the end of the text
	CGFloat bottom = NSHeight(_textView.frame);
	if(_anchors.size() > 1 && bottom > _anchors.back().second)
		_anchors.emplace_back(lastLine + 1, bottom);

	if([self.delegate respondsToSelector:@selector(markdownPreviewDidUpdateAnchorLines:)])
		[self.delegate markdownPreviewDidUpdateAnchorLines:self];
}

- (NSArray<NSNumber*>*)anchorLines
{
	if(self.showsHTML)
		return _htmlView.anchorLines ?: @[ ];
	if(_anchors.size() < 3)
		return @[ ];

	NSMutableArray* res = [NSMutableArray array];
	for(auto const& anchor : _anchors)
		[res addObject:@(anchor.first)];
	return res;
}

- (void)HTMLViewDidUpdateAnchorLines:(MarkdownPreviewHTMLView*)view
{
	if([self.delegate respondsToSelector:@selector(markdownPreviewDidUpdateAnchorLines:)])
		[self.delegate markdownPreviewDidUpdateAnchorLines:self];
}

- (void)scrollToSourceLine:(CGFloat)line fraction:(CGFloat)fraction
{
	if(self.showsHTML)
		return [_htmlView scrollToSourceLine:line fraction:fraction];
	if(_anchors.size() < 3)
		return [self setScrollFraction:fraction];

	// Fractional positions, aligned to the screen’s pixels, so slow scrolling doesn’t move in whole points
	CGFloat const scale = _scrollView.window.backingScaleFactor ?: 2;
	CGFloat y = MarkdownPreviewInterpolate(_anchors, line);
	y = round(MIN(MAX(y, 0), [self scrollableHeight]) * scale) / scale;
	[_scrollView.contentView scrollToPoint:NSMakePoint(0, y)];
	[_scrollView reflectScrolledClipView:_scrollView.contentView];
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

- (void)HTMLView:(MarkdownPreviewHTMLView*)view openURL:(NSURL*)url
{
	[self.delegate markdownPreview:self openURL:url];
}

- (BOOL)textView:(NSTextView*)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex
{
	NSURL* url = [link isKindOfClass:[NSURL class]] ? link : [NSURL URLWithString:[link description] relativeToURL:_baseURL];
	if(url.fragment && [self scrollToAnchor:url.fragment ofURL:url])
		return YES;
	if(url)
		[self.delegate markdownPreview:self openURL:url.absoluteURL];
	return YES;
}

// Links within the document, e.g. to footnotes and back, scroll the preview
// (not the editor, as with the GitHub renderer)
- (BOOL)scrollToAnchor:(NSString*)anchor ofURL:(NSURL*)url
{
	BOOL sameDocument = url.absoluteURL.isFileURL ? [url.absoluteURL.path isEqualToString:_baseURL.path] : !url.absoluteURL.scheme;
	if(!sameDocument)
		return NO;

	NSTextStorage* textStorage = _textView.textStorage;
	__block NSUInteger index = NSNotFound;
	[textStorage enumerateAttribute:OakMarkdownAnchorAttributeName inRange:NSMakeRange(0, textStorage.length) options:0 usingBlock:^(NSString* value, NSRange range, BOOL* stop){
		if([value isEqualToString:anchor])
		{
			index = range.location;
			*stop = YES;
		}
	}];
	if(index == NSNotFound)
		return NO;

	NSLayoutManager* layoutManager = _textView.layoutManager;
	NSRect rect = [layoutManager lineFragmentRectForGlyphAtIndex:[layoutManager glyphIndexForCharacterAtIndex:index] effectiveRange:nullptr];
	CGFloat y = MIN(MAX(NSMinY(rect) + _textView.textContainerOrigin.y - 8, 0), [self scrollableHeight]);
	[_scrollView.contentView scrollToPoint:NSMakePoint(0, y)];
	[_scrollView reflectScrolledClipView:_scrollView.contentView];
	return YES;
}
@end
