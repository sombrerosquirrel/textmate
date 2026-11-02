#import "OakCodeView.h"
#import "OakTextView_Private.h"
#import <document/OakDocument.h>
#import <ns/ns.h>

static void* kNaturalHeightContext = &kNaturalHeightContext;

// Scrolls sideways itself; vertical scrolling goes to the enclosing scroll view
@interface OakCodeScrollView : NSScrollView
@end

@implementation OakCodeScrollView
- (void)scrollWheel:(NSEvent*)anEvent
{
	BOOL scrollsSideways = NSWidth(self.documentView.frame) > NSWidth(self.contentView.bounds) && fabs(anEvent.scrollingDeltaX) > fabs(anEvent.scrollingDeltaY);
	if(scrollsSideways)
			[super scrollWheel:anEvent];
	else	[self.nextResponder scrollWheel:anEvent];
}
@end

@implementation OakCodeView
{
	NSScrollView* _scrollView;
	OakDocument* _document;
}

- (instancetype)initWithCode:(NSString*)code fileType:(NSString*)fileType
{
	if(self = [super initWithFrame:NSMakeRect(0, 0, 300, 100)])
	{
		_code = [code copy] ?: @"";

		self.wantsLayer          = YES;
		self.layer.cornerRadius  = 4;
		self.layer.masksToBounds = YES;

		_textView = [[OakTextView alloc] initWithFrame:NSZeroRect];
		_textView.readOnly = YES;

		_scrollView = [[OakCodeScrollView alloc] initWithFrame:self.bounds];
		_scrollView.autoresizingMask      = NSViewWidthSizable|NSViewHeightSizable;
		_scrollView.hasVerticalScroller   = NO;
		_scrollView.hasHorizontalScroller = YES;
		_scrollView.autohidesScrollers    = YES;
		_scrollView.borderType            = NSNoBorder;
		_scrollView.drawsBackground       = NO;
		_scrollView.documentView          = _textView;
		[self addSubview:_scrollView];

		_document = [OakDocument documentWithString:_code fileType:fileType customName:@"Code"];
		[_document loadModalForWindow:nil completionHandler:nullptr];
		_textView.document = _document;
		_textView.softWrap = NO;

		[_textView addObserver:self forKeyPath:@"naturalHeight" options:0 context:kNaturalHeightContext];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(textViewFrameDidChange:) name:NSViewFrameDidChangeNotification object:_textView];
		[self updateFittingHeight];
	}
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
	[_textView removeObserver:self forKeyPath:@"naturalHeight" context:kNaturalHeightContext];
	_textView.document = nil;
	[_document close];
}

- (void)setCode:(NSString*)newCode
{
	newCode = newCode ?: @"";
	if([_code isEqualToString:newCode])
		return;

	// Replace only what changed, so a streaming reply appends to the text
	std::string const oldText = to_s(_code), newText = to_s(newCode);
	size_t prefix = 0, suffix = 0;
	while(prefix < oldText.size() && prefix < newText.size() && oldText[prefix] == newText[prefix])
		++prefix;
	while(suffix < oldText.size() - prefix && suffix < newText.size() - prefix && oldText[oldText.size() - 1 - suffix] == newText[newText.size() - 1 - suffix])
		++suffix;
	// Keep UTF-8 sequences whole
	while(prefix && prefix < oldText.size() && (oldText[prefix] & 0xC0) == 0x80)
		--prefix;
	while(suffix && (oldText[oldText.size() - suffix] & 0xC0) == 0x80)
		--suffix;

	_code = [newCode copy];
	[_document performReplacements:{ { { prefix, oldText.size() - suffix }, newText.substr(prefix, newText.size() - suffix - prefix) } } checksum:0];

	// The replacement isn’t one of the view’s own edits, so it doesn’t refresh itself
	[_textView reflectDocumentSize];
	_textView.needsDisplay = YES;
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if(context == kNaturalHeightContext)
			[self updateFittingHeight];
	else	[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)textViewFrameDidChange:(NSNotification*)aNotification
{
	[self updateFittingHeight];
}

- (void)updateFittingHeight
{
	CGFloat height = _textView.naturalHeight;
	if(_scrollView.scrollerStyle == NSScrollerStyleLegacy && NSWidth(_textView.frame) > NSWidth(_scrollView.contentView.bounds) + 0.5)
		height += [NSScroller scrollerWidthForControlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleLegacy];
	height = ceil(height);

	if(_fittingHeight != height)
	{
		[self willChangeValueForKey:@"fittingHeight"];
		_fittingHeight = height;
		[self didChangeValueForKey:@"fittingHeight"];
	}
}
@end
