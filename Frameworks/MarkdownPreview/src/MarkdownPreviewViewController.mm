#import "MarkdownPreviewViewController.h"
#import "MarkdownPreviewHTMLView.h"
#import "MarkdownPreviewScrollMap.h"
#import <OakMarkdown/OakMarkdown.h>
#import <OakFoundation/OakStringListTransformer.h>
#import <Preferences/Keys.h>
#import <QuartzCore/QuartzCore.h>

static CGFloat const kTextInset = 16;
static NSString* const kRendererTransformerName = @"OakMarkdownPreviewRendererSettingsTransformer";

@interface MarkdownPreviewTextView : NSTextView
@end

@implementation MarkdownPreviewTextView
// ⌘↑ and ⌘↓ come here, ahead of anything else that wants them
- (BOOL)performKeyEquivalent:(NSEvent*)anEvent
{
	return (self.window.firstResponder == self && [self scrollForEvent:anEvent]) || [super performKeyEquivalent:anEvent];
}

// Space comes here; the text isn’t editable, so it would do nothing
- (void)keyDown:(NSEvent*)anEvent
{
	if(![self scrollForEvent:anEvent])
		[super keyDown:anEvent];
}

- (BOOL)scrollForEvent:(NSEvent*)anEvent
{
	if(!MarkdownPreviewIsScrollKeyEquivalent(anEvent))
		return NO;

	BOOL shift = (anEvent.modifierFlags & NSEventModifierFlagShift) != 0;
	unichar key = [anEvent.charactersIgnoringModifiers characterAtIndex:0];
	if(key != ' ' && shift)
		return NO; // ⇧⌘↑ extends the selection

	NSScrollView* scrollView = self.enclosingScrollView;
	NSClipView* clipView = scrollView.contentView;
	CGFloat const page = NSHeight(clipView.bounds) - scrollView.verticalPageScroll;
	CGFloat const maxY = MAX(0, NSHeight(self.frame) - NSHeight(clipView.bounds));

	CGFloat y;
	if(key == ' ')
		y = NSMinY(clipView.bounds) + (shift ? -page : page);
	else	y = key == NSUpArrowFunctionKey ? 0 : maxY;

	[clipView scrollToPoint:NSMakePoint(0, MIN(MAX(y, 0), maxY))];
	[scrollView reflectScrolledClipView:clipView];
	return YES;
}
@end

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
	NSMutableSet<NSNumber*>* _toggledDetails; // <details> opened or closed by the user
	CGFloat _renderedWidth;
	std::vector<std::pair<CGFloat, CGFloat>> _anchors; // source line → y in the text view, both increasing

	CADisplayLink* _displayLink; // while easing towards _targetY
	CGFloat _scrollY;
	CGFloat _targetY;
	CFTimeInterval _lastFrame;

	BOOL _settingScroll;  // scrolls we make aren’t reported to the delegate
	NSSize _clipSize;     // nor are those from resizing
	BOOL _focusWhenShown; // asked for focus while there was no content
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

	_textView = [[MarkdownPreviewTextView alloc] initWithFrame:NSMakeRect(0, 0, _scrollView.contentSize.width, _scrollView.contentSize.height) textContainer:textContainer];
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

	_scrollView.contentView.postsBoundsChangedNotifications = YES;
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewBoundsDidChange:) name:NSViewBoundsDidChangeNotification object:_scrollView.contentView];

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
	[NSNotificationCenter.defaultCenter removeObserver:self];
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

- (BOOL)hasFocus
{
	id responder = self.view.window.firstResponder;
	return [responder isKindOfClass:[NSView class]] && [responder isDescendantOf:_contentView];
}

// The content may not be there yet, e.g. coming back from a non-Markdown document
- (void)focus
{
	if(!_placeholder.hidden)
	{
		_focusWhenShown = YES;
		return;
	}
	[self.view.window makeFirstResponder:self.showsHTML ? _htmlView.scrollView.documentView : _textView];
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
	if(!_toggledDetails || !(baseURL == _baseURL || [baseURL isEqual:_baseURL]))
		_toggledDetails = [NSMutableSet set];
	_markdown = [markdown copy];
	_baseURL  = baseURL;
	[self render];
}

- (void)showHTML:(NSString*)html documentURL:(NSURL*)documentURL readAccessURL:(NSURL*)readAccessURL
{
	[self view];
	BOOL hadFocus = self.hasFocus || _focusWhenShown; // hiding a view moves focus somewhere else
	_focusWhenShown = NO;
	_markdown = nil;
	_baseURL  = nil;
	_settingScroll = YES;
	[_textView.textStorage setAttributedString:[[NSAttributedString alloc] init]];
	_settingScroll = NO;

	if(!_htmlView)
	{
		_htmlView = [[MarkdownPreviewHTMLView alloc] initWithFrame:_contentView.bounds];
		_htmlView.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
		_htmlView.delegate = self;
		_htmlView.scrollView.contentView.postsBoundsChangedNotifications = YES;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewBoundsDidChange:) name:NSViewBoundsDidChangeNotification object:_htmlView.scrollView.contentView];
		[_contentView addSubview:_htmlView positioned:NSWindowBelow relativeTo:_placeholder];
	}

	_placeholder.hidden = YES;
	_scrollView.hidden  = YES;
	_htmlView.hidden    = NO;
	[_htmlView showHTML:html documentURL:documentURL readAccessURL:readAccessURL];
	if(hadFocus)
		[self focus];
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

	BOOL hadFocus = self.hasFocus || _focusWhenShown; // hiding a view moves focus somewhere else
	_focusWhenShown = NO;
	_placeholder.hidden = YES;
	_scrollView.hidden  = NO;
	_htmlView.hidden    = YES;
	if(hadFocus)
		[self focus];

	_renderedWidth = [self availableWidth];
	_style.maximumImageWidth = _renderedWidth;
	_style.toggledDetails    = _toggledDetails;

	NSPoint scrollOrigin = _scrollView.contentView.bounds.origin;
	_settingScroll = YES;
	[_textView.textStorage setAttributedString:[OakMarkdownRenderer attributedStringFromMarkdown:_markdown style:_style baseURL:_baseURL codeBlocks:nullptr codeBlockFooter:nil]];

	// Keep the scroll position, so the preview doesn’t jump while typing
	[_textView.layoutManager ensureLayoutForTextContainer:_textView.textContainer];
	[_textView sizeToFit];
	[self updateAnchors];
	CGFloat maxY = MAX(0, NSHeight(_textView.frame) - NSHeight(_scrollView.contentView.bounds));
	[_scrollView.contentView scrollToPoint:NSMakePoint(0, MIN(scrollOrigin.y, maxY))];
	[_scrollView reflectScrolledClipView:_scrollView.contentView];
	_settingScroll = NO;

	// Last, so the editor’s position wins: coming from the GitHub view, what we kept is the empty text’s
	if([self.delegate respondsToSelector:@selector(markdownPreviewDidUpdateAnchors:)])
		[self.delegate markdownPreviewDidUpdateAnchors:self];
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

// The built-in view’s, or the GitHub view’s: both scroll the same way
- (NSScrollView*)activeScrollView
{
	return self.showsHTML ? _htmlView.scrollView : _scrollView;
}

- (CGFloat)scrollableHeight
{
	NSScrollView* scrollView = self.activeScrollView;
	return MAX(0, NSHeight(scrollView.documentView.frame) - NSHeight(scrollView.contentView.bounds));
}

- (CGFloat)scrollFraction
{
	CGFloat height = [self scrollableHeight];
	return height > 0 ? MIN(MAX(NSMinY(self.activeScrollView.contentView.bounds) / height, 0), 1) : 0;
}

- (void)setScrollFraction:(CGFloat)fraction
{
	[self view];
	[self scrollToFraction:fraction animated:NO];
}

// Where the text from each marked source line starts
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
}

- (NSArray<NSValue*>*)anchors
{
	if(self.showsHTML)
		return _htmlView.anchors ?: @[ ];
	if(_anchors.size() < 3)
		return @[ ];

	NSMutableArray* res = [NSMutableArray array];
	for(auto const& [line, y] : _anchors)
		[res addObject:[NSValue valueWithPoint:NSMakePoint(line, y)]];
	return res;
}

- (void)HTMLViewDidUpdateAnchors:(MarkdownPreviewHTMLView*)view
{
	if([self.delegate respondsToSelector:@selector(markdownPreviewDidUpdateAnchors:)])
		[self.delegate markdownPreviewDidUpdateAnchors:self];
}

- (void)scrollToPosition:(CGFloat)y animated:(BOOL)animated
{
	NSScrollView* scrollView = self.activeScrollView;
	_targetY = MIN(MAX(y, 0), [self scrollableHeight]);
	BOOL jump = fabs(_targetY - NSMinY(scrollView.contentView.bounds)) > NSHeight(scrollView.contentView.bounds) / 2;
	if(!animated || !scrollView.window || (!_displayLink && !jump))
	{
		[self stopScrollAnimation];
		return [self setScrollY:_targetY];
	}

	if(!_displayLink)
	{
		_scrollY     = NSMinY(scrollView.contentView.bounds);
		_lastFrame   = 0;
		_displayLink = [scrollView displayLinkWithTarget:self selector:@selector(scrollAnimationStep:)];
		[_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	}
}

- (void)scrollToFraction:(CGFloat)fraction animated:(BOOL)animated
{
	[self scrollToPosition:MIN(MAX(fraction, 0), 1) * [self scrollableHeight] animated:animated];
}

- (void)scrollAnimationStep:(CADisplayLink*)displayLink
{
	CFTimeInterval elapsed = _lastFrame ? displayLink.targetTimestamp - _lastFrame : displayLink.targetTimestamp - displayLink.timestamp;
	_lastFrame = displayLink.targetTimestamp;

	_scrollY = MarkdownPreviewEase(_scrollY, _targetY, elapsed);
	if(fabs(_scrollY - _targetY) < 0.1)
	{
		_scrollY = _targetY;
		[self stopScrollAnimation];
	}
	[self setScrollY:_scrollY];
}

- (void)stopScrollAnimation
{
	[_displayLink invalidate];
	_displayLink = nil;
}

- (void)viewDidDisappear
{
	[super viewDidDisappear];
	if(_displayLink)
	{
		[self stopScrollAnimation];
		[self setScrollY:_targetY];
	}
}

// Fractional positions, aligned to the screen’s pixels, so slow scrolling doesn’t move in whole points
- (void)setScrollY:(CGFloat)y
{
	NSScrollView* scrollView = self.activeScrollView;
	CGFloat const scale = scrollView.window.backingScaleFactor ?: 2;
	_settingScroll = YES;
	[scrollView.contentView scrollToPoint:NSMakePoint(0, round(y * scale) / scale)];
	[scrollView reflectScrolledClipView:scrollView.contentView];
	_settingScroll = NO;
}

// Scrolled by the user (wheel, scroller, keys, find, links): the editor follows
- (void)clipViewBoundsDidChange:(NSNotification*)aNotification
{
	NSScrollView* scrollView = self.activeScrollView;
	if(aNotification.object != scrollView.contentView)
		return;

	NSRect bounds = scrollView.contentView.bounds;
	BOOL resized = !NSEqualSizes(bounds.size, _clipSize);
	_clipSize = bounds.size;
	if(_settingScroll || resized || scrollView.hidden || _htmlView.isResizing)
		return;

	[self stopScrollAnimation]; // the user takes over from an editor jump
	if([self.delegate respondsToSelector:@selector(markdownPreview:didScrollToPosition:fraction:)])
		[self.delegate markdownPreview:self didScrollToPosition:NSMinY(bounds) fraction:self.scrollFraction];
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

	// A <details> summary: open or close it
	NSInteger details = OakMarkdownDetailsIndexForURL(url);
	if(details >= 0)
	{
		NSNumber* index = @(details);
		if([_toggledDetails containsObject:index])
			[_toggledDetails removeObject:index];
		else	[_toggledDetails addObject:index];
		[self render];
		return YES;
	}
	if(url.fragment && [self scrollToAnchor:url.fragment ofURL:url])
		return YES;
	if(url)
		[self.delegate markdownPreview:self openURL:url.absoluteURL];
	return YES;
}

// Links within the document, e.g. a table of contents or footnotes, scroll
// the preview, and the editor follows, as with the GitHub renderer. One that
// goes nowhere does nothing, rather than reopen the document.
- (BOOL)scrollToAnchor:(NSString*)anchor ofURL:(NSURL*)url
{
	BOOL sameDocument = url.absoluteURL.isFileURL ? [url.absoluteURL.path isEqualToString:_baseURL.path] : !url.absoluteURL.scheme;
	if(!sameDocument)
		return NO;

	// “#user-content-intro”, as GitHub prefixes ids, also works there without its script
	anchor = anchor.stringByRemovingPercentEncoding ?: anchor;
	if([anchor hasPrefix:@"user-content-"])
		anchor = [anchor substringFromIndex:13];

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
		return YES;

	NSLayoutManager* layoutManager = _textView.layoutManager;
	NSRect rect = [layoutManager lineFragmentRectForGlyphAtIndex:[layoutManager glyphIndexForCharacterAtIndex:index] effectiveRange:nullptr];
	CGFloat y = MIN(MAX(NSMinY(rect) + _textView.textContainerOrigin.y - 8, 0), [self scrollableHeight]);
	[self stopScrollAnimation];
	[_scrollView.contentView scrollToPoint:NSMakePoint(0, y)];
	[_scrollView reflectScrolledClipView:_scrollView.contentView];
	return YES;
}
@end
