#import "AgentTranscriptView.h"
#import "AgentCodeLocation.h"
#import "AgentActivityView.h"
#import "AgentDiffText.h"
#import <OakMarkdown/OakMarkdown.h>
#import <AgentClient/AgentDiff.h>
#import <OakAppKit/NSColor Additions.h>

static NSString* const kActionScheme      = @"textmate-agent";
static NSTimeInterval const kCoalesceDelay = 0.05;
static NSTimeInterval const kScrollTimeConstant = 0.12; // the glide closes in on its target like this
static CGFloat const kScrollMaxSpeed = 2400;              // points per second, so a burst of text still slides
static NSTimeInterval const kScrollEaseIn = 0.12;         // from rest up to speed, rather than starting at it
static NSTimeInterval const kScrollGap = 0.4;             // moves closer together than this glide, as one
static NSTimeInterval const kScrollMaxTime = 0.4;         // but what’s far away doesn’t take longer than this
static NSUInteger const kDiffPreviewLines   = 12;
static NSUInteger const kOutputPreviewLines = 12;
static NSUInteger const kSummaryLength      = 90;  // characters of a folded item’s line
static NSUInteger const kFirstLineLength    = 40;  // characters of a code block’s first line, when its place isn’t known

static void* kFittingHeightContext = &kFittingHeightContext;

// On the attachment character of an unfolded code block: its key (item:index)
static NSAttributedStringKey const AgentCodeBlockKeyAttributeName = @"AgentCodeBlockKey";
// On the marker that blinks and the status of the item being worked on
static NSAttributedStringKey const AgentWorkingMarkerAttributeName = @"AgentWorkingMarker";
static NSAttributedStringKey const AgentWorkingStatusAttributeName = @"AgentWorkingStatus";
static NSTimeInterval const kWorkingBlinkInterval = 0.35; // faster than the working line’s dot
// On the question and options of an open permission card (its item’s
// identifier), to scroll them into view once
static NSAttributedStringKey const AgentPermissionOptionsAttributeName = @"AgentPermissionOptions";

static NSFont* SmallFont ()          { return [NSFont systemFontOfSize:NSFont.smallSystemFontSize]; }
static NSFont* SmallMonospaceFont () { return [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular]; }
static NSFont* DisclosureFont ()     { return [NSFont systemFontOfSize:NSFont.systemFontSize + 5]; }

static NSString* ToolStatusGlyph (NSString* status)
{
	if([status isEqualToString:@"completed"])   return @"✓";
	if([status isEqualToString:@"failed"])      return @"✗";
	if([status isEqualToString:@"in_progress"]) return @"◐";
	if([status isEqualToString:@"cancelled"])   return @"–";
	return @"○";
}

static NSColor* ToolStatusColor (NSString* status)
{
	if([status isEqualToString:@"completed"])   return NSColor.systemGreenColor;
	if([status isEqualToString:@"failed"])      return NSColor.systemRedColor;
	return NSColor.secondaryLabelColor;
}

static NSString* PlanStatusGlyph (NSString* status)
{
	if([status isEqualToString:@"completed"])   return @"☑";
	if([status isEqualToString:@"in_progress"]) return @"◐";
	return @"☐";
}

static NSString* PermissionOptionGlyph (NSString* kind)
{
	if([kind isEqualToString:@"allow_once"])    return @"✓";
	if([kind isEqualToString:@"allow_always"])  return @"✓✓";
	if([kind hasPrefix:@"reject"])              return @"✗";
	return @"•";
}

// The command of an execute tool call, from its raw input (agents differ:
// a string, or an array of arguments)
static NSString* CommandOfToolCall (NSDictionary* toolCall)
{
	NSDictionary* rawInput = [toolCall[@"rawInput"] isKindOfClass:[NSDictionary class]] ? toolCall[@"rawInput"] : nil;
	id command = rawInput[@"command"];
	if([command isKindOfClass:[NSArray class]])
		command = [command componentsJoinedByString:@" "];
	return [command isKindOfClass:[NSString class]] && [command length] ? command : nil;
}

// Terminal output as shown: escape sequences (colours, cursor movement)
// removed, and a line rewritten with carriage returns shows its last version
static NSString* DisplayTerminalOutput (NSString* output)
{
	static NSRegularExpression* const escapes = [NSRegularExpression regularExpressionWithPattern:@"\\x1B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)|[@-Z\\\\-_])" options:0 error:nullptr];
	output = [escapes stringByReplacingMatchesInString:output options:0 range:NSMakeRange(0, output.length) withTemplate:@""];

	NSMutableArray* lines = [NSMutableArray array];
	for(NSString* line in [output componentsSeparatedByString:@"\n"])
	{
		NSString* trimmed = [line hasSuffix:@"\r"] ? [line substringToIndex:line.length - 1] : line;
		NSRange lastReturn = [trimmed rangeOfString:@"\r" options:NSBackwardsSearch];
		[lines addObject:lastReturn.location != NSNotFound ? [trimmed substringFromIndex:NSMaxRange(lastReturn)] : trimmed];
	}
	return [lines componentsJoinedByString:@"\n"];
}

static NSString* PathFromURI (NSString* uri)
{
	NSURL* url = [NSURL URLWithString:uri];
	return url.isFileURL ? url.path : uri;
}

// The first non-blank line, cut to `length` characters
static NSString* FirstLine (NSString* text, NSUInteger length)
{
	for(NSString* line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
	{
		NSString* trimmed = [[line stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if(trimmed.length)
			return trimmed.length > length ? [[trimmed substringToIndex:length] stringByAppendingString:@"…"] : trimmed;
	}
	return @"";
}

static NSUInteger LineCount (NSString* code)
{
	return code.length ? [code componentsSeparatedByString:@"\n"].count : 0;
}

// Holds the place of a code block view, as wide as the line and as tall as
// the view’s code; the view is placed over it
@interface AgentCodeBlockAttachmentCell : NSTextAttachmentCell
@property (nonatomic) CGFloat height;
@end

@implementation AgentCodeBlockAttachmentCell
- (NSRect)cellFrameForTextContainer:(NSTextContainer*)textContainer proposedLineFragment:(NSRect)lineFrag glyphPosition:(NSPoint)position characterIndex:(NSUInteger)charIndex
{
	CGFloat width = floor(NSWidth(lineFrag) - position.x - 2 * textContainer.lineFragmentPadding);
	return NSMakeRect(0, 0, MAX(width, 40), MAX(_height, 1));
}

- (NSSize)cellSize                                                                     { return NSMakeSize(40, MAX(_height, 1)); }
- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView*)controlView                    { }
- (void)highlight:(BOOL)flag withFrame:(NSRect)cellFrame inView:(NSView*)controlView   { }
- (BOOL)wantsToTrackMouse                                                              { return NO; }
@end

@interface AgentTranscriptView () <NSTextViewDelegate, NSLayoutManagerDelegate>
{
	NSMutableDictionary<NSString*, NSNumber*>* _renderedLengths;
	NSMutableSet<NSString*>* _pendingIdentifiers;
	NSMutableDictionary<NSString*, NSArray<OakMarkdownCodeBlock*>*>* _codeBlocks;
	BOOL _flushScheduled;
	OakMarkdownStyle* _markdownStyle;

	// Code blocks, by key (item:index)
	NSMutableSet<NSString*>* _toggledCodeBlocks; // clicked open or folded, unlike foldsCodeBlocks says
	NSMutableDictionary<NSString*, NSView<AgentCodeBlockView>*>* _codeViews;
	NSCache<NSString*, id>* _codePlaces;          // item, info and code → { path, line, lastLine } or NSNull
	NSMutableDictionary<NSString*, id>* _fileTexts; // while rendering: path → text or NSNull
	BOOL _positioningCodeViews;
	BOOL _positionCodeViewsScheduled;

	CADisplayLink* _scrollLink;      // drives the glide while it’s under way
	CGFloat _scrollTarget;
	CGFloat _scrollPosition;         // where the glide left the clip view, to tell when the user scrolls
	CFTimeInterval _scrollTimestamp;
	CFTimeInterval _scrollStart;
	CFTimeInterval _lastScrollRequest;
	BOOL _scrollingToBottom;         // a glide to the end is under way
	BOOL _followsEnd;                // the user last left the chat scrolled to the end
	NSPoint _lastScrollOrigin;
	BOOL _makesRoomForReply;         // at the next update
	AgentTranscriptItem* _workingItem;
	NSDate* _workingStart;
	double _workingStartTokens;
	double _workingTokens;
	NSTimer* _workingBlinkTimer;
	NSTimer* _workingStatusTimer;
	BOOL _workingMarkerHidden;
	BOOL _reloading;                 // reloadData empties and refills the text
	NSString* _clickedIdentifier;    // at the next update: the item to keep where it is
	NSMutableSet<NSString*>* _scrolledToPermissionIds;
}
@end

@implementation AgentTranscriptView
+ (NSScrollView*)scrollableTranscriptView
{
	NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
	scrollView.hasVerticalScroller   = YES;
	scrollView.hasHorizontalScroller = NO;
	scrollView.borderType            = NSNoBorder;
	scrollView.drawsBackground       = YES; // fills below short transcripts, where the text view ends
	scrollView.backgroundColor       = NSColor.tmSidebarBackgroundColor;

	NSTextStorage* textStorage     = [[NSTextStorage alloc] init];
	NSLayoutManager* layoutManager = [[NSLayoutManager alloc] init];
	[textStorage addLayoutManager:layoutManager];

	// TextKit 1 is required for NSTextBlock backgrounds and NSTextTable
	NSTextContainer* textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(scrollView.contentSize.width, CGFLOAT_MAX)];
	textContainer.widthTracksTextView = YES;
	[layoutManager addTextContainer:textContainer];

	AgentTranscriptView* textView = [[self alloc] initWithFrame:NSMakeRect(0, 0, scrollView.contentSize.width, scrollView.contentSize.height) textContainer:textContainer];
	textView.minSize               = NSMakeSize(0, scrollView.contentSize.height);
	textView.maxSize               = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
	textView.verticallyResizable   = YES;
	textView.horizontallyResizable = NO;
	textView.autoresizingMask      = NSViewWidthSizable;

	scrollView.documentView = textView;
	return scrollView;
}

- (instancetype)initWithFrame:(NSRect)frame textContainer:(NSTextContainer*)textContainer
{
	if(self = [super initWithFrame:frame textContainer:textContainer])
	{
		_renderedLengths     = [NSMutableDictionary dictionary];
		_pendingIdentifiers  = [NSMutableSet set];
		_codeBlocks          = [NSMutableDictionary dictionary];
		_markdownStyle       = [OakMarkdownStyle defaultStyle];
		_toggledCodeBlocks  = [NSMutableSet set];
		_scrolledToPermissionIds = [NSMutableSet set];
		_followsEnd = YES;
		_codeViews           = [NSMutableDictionary dictionary];
		_codePlaces          = [[NSCache alloc] init];
		_codePlaces.countLimit = 500;

		self.editable           = NO;
		self.selectable         = YES;
		self.richText           = YES;
		self.drawsBackground    = YES;
		self.backgroundColor    = NSColor.tmSidebarBackgroundColor;
		self.textContainerInset = NSMakeSize(10, 10);
		self.delegate           = self;
		self.linkTextAttributes = @{ NSForegroundColorAttributeName: NSColor.linkColor, NSCursorAttributeName: NSCursor.pointingHandCursor };
		self.automaticLinkDetectionEnabled = NO;
		self.layoutManager.delegate = self;
	}
	return self;
}

- (void)dealloc
{
	[_workingBlinkTimer invalidate];
	[_workingStatusTimer invalidate];
	[self removeCodeViewsExcept:nil];
}

- (void)setTranscript:(AgentTranscript*)transcript
{
	_transcript = transcript;
	[_toggledCodeBlocks removeAllObjects];
	[self removeCodeViewsExcept:nil];
	[self reloadData];
}

- (void)setFoldsCodeBlocks:(BOOL)flag
{
	if(_foldsCodeBlocks == flag && !_toggledCodeBlocks.count)
		return;
	_foldsCodeBlocks = flag;
	[_toggledCodeBlocks removeAllObjects];
	[self reloadData];
}

- (void)setUsesGitHubStyle:(BOOL)flag
{
	if(_usesGitHubStyle == flag)
		return;
	_usesGitHubStyle = flag;

	OakMarkdownStyle* style = flag ? [OakMarkdownStyle githubStyle] : [OakMarkdownStyle defaultStyle];
	style.codeBlockBackgroundColor = _markdownStyle.codeBlockBackgroundColor;
	style.codeBlockTextColor       = _markdownStyle.codeBlockTextColor;
	style.codeHighlighter          = _markdownStyle.codeHighlighter;
	_markdownStyle = style;
	self.linkTextAttributes = @{ NSForegroundColorAttributeName: style.linkColor ?: NSColor.linkColor, NSCursorAttributeName: NSCursor.pointingHandCursor };
	[self reloadData];
}

- (void)setAllFolded:(BOOL)flag
{
	[_transcript setAllItemsFolded:flag];
	_foldsCodeBlocks = flag;
	[_toggledCodeBlocks removeAllObjects];
	[self reloadData];
}

- (void)setWorkingItem:(AgentTranscriptItem*)item tokens:(double)tokens
{
	_workingTokens = tokens;
	if(item == _workingItem)
		return (void)[self updateWorkingStatus];

	[self setNeedsDisplayItem:_workingItem];
	_workingItem        = item;
	_workingStart       = item ? [NSDate date] : nil;
	_workingStartTokens = tokens;
	[self setNeedsDisplayItem:item];

	[_workingBlinkTimer invalidate];
	[_workingStatusTimer invalidate];
	_workingBlinkTimer = _workingStatusTimer = nil;
	_workingMarkerHidden = NO;
	if(!item)
		return;

	__weak AgentTranscriptView* weakSelf = self;
	_workingStatusTimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer*){ [weakSelf updateWorkingStatus]; }];
	_workingStatusTimer.tolerance = 0.2;
	[NSRunLoop.mainRunLoop addTimer:_workingStatusTimer forMode:NSRunLoopCommonModes];
	if(!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion)
	{
		_workingBlinkTimer = [NSTimer timerWithTimeInterval:kWorkingBlinkInterval repeats:YES block:^(NSTimer*){ [weakSelf blinkWorkingMarker]; }];
		[NSRunLoop.mainRunLoop addTimer:_workingBlinkTimer forMode:NSRunLoopCommonModes];
	}
}

- (void)blinkWorkingMarker
{
	_workingMarkerHidden = !_workingMarkerHidden;
	NSTextStorage* storage = self.textStorage;
	[storage enumerateAttribute:AgentWorkingMarkerAttributeName inRange:NSMakeRange(0, storage.length) options:0 usingBlock:^(id value, NSRange range, BOOL* stop){
		if(!value)
			return;
		if(_workingMarkerHidden)
				[self.layoutManager addTemporaryAttribute:NSForegroundColorAttributeName value:NSColor.clearColor forCharacterRange:range];
		else	[self.layoutManager removeTemporaryAttribute:NSForegroundColorAttributeName forCharacterRange:range];
	}];
}

- (NSString*)workingStatusString
{
	NSMutableArray<NSString*>* parts = [NSMutableArray arrayWithObject:[AgentActivityView stringFromTimeInterval:-_workingStart.timeIntervalSinceNow]];
	double tokens = _workingTokens - _workingStartTokens;
	if(tokens > 0)
		[parts addObject:[NSString stringWithFormat:@"+%@ tokens", [AgentActivityView stringFromTokens:tokens]]];
	return [@"  ·  " stringByAppendingString:[parts componentsJoinedByString:@" · "]];
}

// Only the status changes, so what’s in the item isn’t rendered again
- (void)updateWorkingStatus
{
	if(!_workingItem)
		return;
	NSTextStorage* storage = self.textStorage;
	__block NSRange status = NSMakeRange(NSNotFound, 0);
	[storage enumerateAttribute:AgentWorkingStatusAttributeName inRange:NSMakeRange(0, storage.length) options:0 usingBlock:^(NSString* identifier, NSRange range, BOOL* stop){
		if([identifier isEqualToString:_workingItem.identifier]) // a former item’s stays until it’s rendered again
		{
			status = range;
			*stop = YES;
		}
	}];
	if(status.location == NSNotFound)
		return;

	NSAttributedString* text = [self workingStatusOfItem:_workingItem];
	[storage replaceCharactersInRange:status withAttributedString:text];
	_renderedLengths[_workingItem.identifier] = @(_renderedLengths[_workingItem.identifier].unsignedIntegerValue + text.length - status.length);
}

- (NSAttributedString*)workingStatusOfItem:(AgentTranscriptItem*)item
{
	if(item != _workingItem)
		return [[NSAttributedString alloc] init];
	NSMutableAttributedString* res = [[self text:self.workingStatusString font:SmallFont() color:NSColor.secondaryLabelColor] mutableCopy];
	[res addAttribute:AgentWorkingStatusAttributeName value:item.identifier range:NSMakeRange(0, res.length)];
	return res;
}

- (NSAttributedString*)workingMarker:(NSAttributedString*)marker item:(AgentTranscriptItem*)item
{
	if(item != _workingItem)
		return marker;
	NSMutableAttributedString* res = [marker mutableCopy];
	[res addAttribute:AgentWorkingMarkerAttributeName value:@YES range:NSMakeRange(0, 1)];
	return res;
}

- (void)setEmptyStateString:(NSString*)emptyStateString
{
	_emptyStateString = emptyStateString;
	self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)rect
{
	[super drawRect:rect];
	if(self.textStorage.length || !_emptyStateString.length)
		return;

	NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.alignment = NSTextAlignmentCenter;
	NSDictionary* attributes = @{ NSFontAttributeName: [NSFont systemFontOfSize:NSFont.systemFontSize], NSForegroundColorAttributeName: NSColor.tertiaryLabelColor, NSParagraphStyleAttributeName: paragraph };
	NSRect textRect = NSInsetRect(self.bounds, 24, 0);
	textRect.origin.y    = NSMinY(self.bounds) + 40;
	textRect.size.height = 200;
	[_emptyStateString drawWithRect:textRect options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes];
}

// ==========
// = Update =
// ==========

- (void)setNeedsDisplayItem:(AgentTranscriptItem*)item
{
	if(!item)
		return;
	[_pendingIdentifiers addObject:item.identifier];
	if(item.kind == AgentTranscriptItemKindPermission) // its tool call’s row shows details or not
	{
		NSDictionary* toolCall = item.permissionRequest[@"toolCall"];
		if(AgentTranscriptItem* toolCallItem = [toolCall isKindOfClass:[NSDictionary class]] ? [self toolCallItemWithIdentifier:toolCall[@"toolCallId"]] : nil)
			[_pendingIdentifiers addObject:toolCallItem.identifier];
	}
	if(_flushScheduled)
		return;

	_flushScheduled = YES;
	__weak AgentTranscriptView* weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCoalesceDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[weakSelf flushPendingItems];
	});
}

- (NSRect)rectOfRange:(NSRange)range
{
	NSRange glyphs = [self.layoutManager glyphRangeForCharacterRange:range actualCharacterRange:nullptr];
	NSRect rect = [self.layoutManager boundingRectForGlyphRange:glyphs inTextContainer:self.textContainer];
	return NSOffsetRect(rect, self.textContainerOrigin.x, self.textContainerOrigin.y);
}

// =====================
// = Following the end =
// =====================

// The chat gets shorter when e.g. the working line or the changed files show
// under it; if it was at the end, it stays there rather than hiding the end
- (void)viewWillMoveToSuperview:(NSView*)newSuperview
{
	[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewBoundsDidChangeNotification object:self.superview];
	[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:self.superview];
	[super viewWillMoveToSuperview:newSuperview];
}

- (void)viewDidMoveToSuperview
{
	[super viewDidMoveToSuperview];
	if(NSClipView* clipView = [self.superview isKindOfClass:[NSClipView class]] ? (NSClipView*)self.superview : nil)
	{
		clipView.postsBoundsChangedNotifications = YES;
		clipView.postsFrameChangedNotifications  = YES;
		_lastScrollOrigin = clipView.bounds.origin;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewBoundsDidChange:) name:NSViewBoundsDidChangeNotification object:clipView];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewFrameDidChange:) name:NSViewFrameDidChangeNotification object:clipView];
	}
}

// Only scrolling decides whether the chat follows the end, not resizing
- (void)clipViewBoundsDidChange:(NSNotification*)notification
{
	NSPoint origin = ((NSClipView*)notification.object).bounds.origin;
	if(NSEqualPoints(origin, _lastScrollOrigin))
		return;
	_lastScrollOrigin = origin;
	if(!_reloading)
		_followsEnd = [self isScrolledToBottom];
}

- (void)clipViewFrameDidChange:(NSNotification*)notification
{
	if(!_followsEnd || _scrollingToBottom)
		return;
	NSClipView* clipView = notification.object;
	NSPoint origin = NSMakePoint(NSMinX(clipView.bounds), MAX(0, NSHeight(self.frame) - NSHeight(clipView.bounds)));
	_lastScrollOrigin = origin;
	[clipView setBoundsOrigin:origin];
	[clipView.enclosingScrollView reflectScrolledClipView:clipView];
}

- (BOOL)isScrolledToBottom
{
	return _scrollingToBottom || NSMaxY(self.visibleRect) >= NSHeight(self.bounds) - 30;
}

// Moves the text up (or down) just enough to show `rect`, gliding when in a
// window and motion isn’t reduced. Text arriving while it moves retargets the
// glide, which carries on at its speed.
- (void)smoothlyScrollRectToVisible:(NSRect)rect toBottom:(BOOL)toBottom
{
	NSClipView* clipView = (NSClipView*)self.superview;
	if(![clipView isKindOfClass:[NSClipView class]])
		return (void)[self scrollRectToVisible:rect];

	NSRect visible = clipView.documentVisibleRect;
	CGFloat y = NSMinY(visible);
	if(NSMaxY(rect) > NSMaxY(visible))
		y = NSMaxY(rect) - NSHeight(visible);
	if(NSMinY(rect) < y)
		y = NSMinY(rect);
	y = MAX(0, MIN(y, NSHeight(self.frame) - NSHeight(visible)));
	if(y == NSMinY(visible) && !_scrollingToBottom)
		return;

	NSPoint origin = NSMakePoint(NSMinX(clipView.bounds), y);
	// What fits in the panel just shows, unless it’s one of a run of moves, which
	// would stutter; a glide under way carries on
	CFTimeInterval now = CACurrentMediaTime();
	BOOL inRun = now - _lastScrollRequest < kScrollGap;
	_lastScrollRequest = now;
	BOOL fits = !_scrollLink && !inRun && fabs(y - NSMinY(visible)) <= NSHeight(visible);
	if(!self.window || fits || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion)
	{
		[self stopGliding];
		[clipView setBoundsOrigin:origin];
		[clipView.enclosingScrollView reflectScrolledClipView:clipView];
		return;
	}

	_scrollTarget      = y;
	_scrollingToBottom = toBottom;
	if(_scrollLink)
		return;
	_scrollPosition  = NSMinY(visible);
	_scrollTimestamp = _scrollStart = 0;
	_scrollLink      = [self displayLinkWithTarget:self selector:@selector(glide:)];
	[_scrollLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)glide:(CADisplayLink*)link
{
	NSClipView* clipView = (NSClipView*)self.superview;
	CGFloat position = NSMinY(clipView.bounds);
	if(fabs(position - _scrollPosition) > 1) // the user scrolled: theirs now
	{
		[self stopGliding];
		_followsEnd = [self isScrolledToBottom];
		return;
	}

	CGFloat maxPosition = MAX(0, NSHeight(self.frame) - NSHeight(clipView.bounds));
	CGFloat target = _scrollingToBottom ? maxPosition : MIN(_scrollTarget, maxPosition);
	CFTimeInterval elapsed = _scrollTimestamp ? MIN(link.timestamp - _scrollTimestamp, 0.05) : link.duration;
	_scrollTimestamp = link.timestamp;
	_scrollStart     = _scrollStart ?: link.timestamp;

	CGFloat remaining = target - position;
	CGFloat step = remaining * (1 - exp(-elapsed / kScrollTimeConstant));
	CGFloat limit = MAX(kScrollMaxSpeed, fabs(remaining) / kScrollMaxTime) * elapsed;
	step = MAX(-limit, MIN(step, limit));
	CGFloat progress = MIN(1, (link.timestamp + elapsed - _scrollStart) / kScrollEaseIn);
	step *= progress * progress * (3 - 2 * progress); // smoothstep
	// The clip view keeps to whole pixels, so smaller steps would never arrive
	CGFloat pixel = 1 / (self.window.backingScaleFactor ?: 1);
	if(progress >= 1 && fabs(step) < pixel)
		step = copysign(pixel, remaining);
	BOOL done = fabs(remaining) <= MAX(pixel, 0.5);

	[clipView setBoundsOrigin:NSMakePoint(NSMinX(clipView.bounds), done ? target : position + step)];
	[clipView.enclosingScrollView reflectScrolledClipView:clipView];
	_scrollPosition = NSMinY(clipView.bounds); // where it went, after rounding
	if(done)
		[self stopGliding];
}

- (void)stopGliding
{
	[_scrollLink invalidate];
	_scrollLink = nil;
	_scrollingToBottom = NO;
}

- (void)viewWillMoveToWindow:(NSWindow*)newWindow
{
	[super viewWillMoveToWindow:newWindow];
	if(!newWindow)
		[self stopGliding];
}

- (void)makeRoomForReply
{
	_makesRoomForReply = YES;
	_followsEnd = YES; // the user sent it, and wants to see it and what comes
}

- (void)removeRoomForReply
{
	if(NSClipView* clipView = [self.superview isKindOfClass:[NSClipView class]] ? (NSClipView*)self.superview : nil)
		self.minSize = NSMakeSize(0, MIN(self.minSize.height, NSHeight(clipView.bounds)));
}

// The text view stays tall enough for the room, however little text comes, and
// grows as usual once the text fills it
- (void)addRoomForReply
{
	NSClipView* clipView = [self.superview isKindOfClass:[NSClipView class]] ? (NSClipView*)self.superview : nil;
	CGFloat used = NSMaxY([self.layoutManager usedRectForTextContainer:self.textContainer]) + 2 * self.textContainerOrigin.y;
	CGFloat room = NSHeight(clipView.bounds) / 2;
	if(clipView && used > room)
	{
		self.minSize = NSMakeSize(0, used + room);
		[self sizeToFit];
	}
}

// What shows stays put when text above it changes, e.g. a reply folding as
// newer ones pass it or a tool call’s output: the first item in view that
// isn’t about to change, or the one clicked, keeps its place
- (NSString*)anchorItemTop:(CGFloat*)top
{
	if(![self.superview isKindOfClass:[NSClipView class]] || !self.textStorage.length)
		return nil;

	NSRect visible = self.visibleRect;
	NSPoint point = NSMakePoint(NSMinX(visible) - self.textContainerOrigin.x, NSMinY(visible) - self.textContainerOrigin.y);
	NSUInteger glyph = [self.layoutManager glyphIndexForPoint:point inTextContainer:self.textContainer];
	NSUInteger index = [self.layoutManager characterIndexForGlyphAtIndex:glyph];

	NSUInteger location = 0;
	for(AgentTranscriptItem* item in _transcript.items)
	{
		NSString* identifier = item.identifier;
		NSUInteger length = _renderedLengths[identifier].unsignedIntegerValue;
		BOOL clicked = [identifier isEqualToString:_clickedIdentifier];
		if(length && (clicked || (!_clickedIdentifier && index < location + length && ![_pendingIdentifiers containsObject:identifier])))
		{
			*top = NSMinY([self rectOfRange:NSMakeRange(location, 1)]);
			return identifier;
		}
		if(length && index < location + length)
			index = location + length; // changing: look further down
		location += length;
	}
	return nil;
}

- (void)keepItem:(NSString*)identifier atTop:(CGFloat)oldTop origin:(CGFloat)oldOrigin
{
	NSUInteger location = 0;
	for(AgentTranscriptItem* item in _transcript.items)
	{
		NSUInteger length = _renderedLengths[item.identifier].unsignedIntegerValue;
		if([item.identifier isEqualToString:identifier])
		{
			if(!length)
				return;
			CGFloat delta = NSMinY([self rectOfRange:NSMakeRange(location, 1)]) - oldTop;
			NSClipView* clipView = (NSClipView*)self.superview;
			if(fabs(delta) < 0.5 && NSMinY(clipView.bounds) == oldOrigin)
				return;

			// The room for the reply goes with the text
			if(self.minSize.height > NSHeight(clipView.bounds))
			{
				self.minSize = NSMakeSize(0, MAX(NSHeight(clipView.bounds), self.minSize.height + delta));
				[self sizeToFit];
			}

			CGFloat y = MAX(0, MIN(oldOrigin + delta, NSHeight(self.frame) - NSHeight(clipView.bounds)));
			NSPoint origin = NSMakePoint(NSMinX(clipView.bounds), y);
			_lastScrollOrigin = origin;
			[clipView setBoundsOrigin:origin];
			[clipView.enclosingScrollView reflectScrolledClipView:clipView];
			if(_scrollLink) // a glide under way carries on from here
			{
				_scrollPosition = y;
				_scrollTarget  += delta;
			}
			return;
		}
		location += length;
	}
}

// ===================================
// = Replacing only what changed =
// ===================================

static BOOL SameObjects (id a, id b) { return a == b || [a isEqual:b]; }

// Text blocks (and tables) are made anew with each render and compare by
// identity, so compare what they draw
static BOOL SameBlockGeometry (NSTextBlock* a, NSTextBlock* b)
{
	if(a.class != b.class || a.verticalAlignment != b.verticalAlignment || !SameObjects(a.backgroundColor, b.backgroundColor))
		return NO;
	for(NSTextBlockDimension dimension : { NSTextBlockWidth, NSTextBlockMinimumWidth, NSTextBlockMaximumWidth, NSTextBlockHeight, NSTextBlockMinimumHeight, NSTextBlockMaximumHeight })
	{
		if([a valueForDimension:dimension] != [b valueForDimension:dimension] || [a valueTypeForDimension:dimension] != [b valueTypeForDimension:dimension])
			return NO;
	}
	for(NSRectEdge edge : { NSMinXEdge, NSMinYEdge, NSMaxXEdge, NSMaxYEdge })
	{
		for(NSTextBlockLayer layer : { NSTextBlockPadding, NSTextBlockBorder, NSTextBlockMargin })
		{
			if([a widthForLayer:layer edge:edge] != [b widthForLayer:layer edge:edge] || [a widthValueTypeForLayer:layer edge:edge] != [b widthValueTypeForLayer:layer edge:edge])
				return NO;
		}
		if(!SameObjects([a borderColorForEdge:edge], [b borderColorForEdge:edge]))
			return NO;
	}
	return YES;
}

static BOOL SameTextBlock (NSTextBlock* a, NSTextBlock* b)
{
	if(a == b)
		return YES;
	if(!SameBlockGeometry(a, b))
		return NO;
	if(![a isKindOfClass:[NSTextTableBlock class]])
		return YES;

	NSTextTableBlock* cellA = (NSTextTableBlock*)a;
	NSTextTableBlock* cellB = (NSTextTableBlock*)b;
	NSTextTable* tableA = cellA.table;
	NSTextTable* tableB = cellB.table;
	if(cellA.startingRow != cellB.startingRow || cellA.rowSpan != cellB.rowSpan || cellA.startingColumn != cellB.startingColumn || cellA.columnSpan != cellB.columnSpan)
		return NO;
	if(tableA == tableB)
		return YES;
	if(!SameBlockGeometry(tableA, tableB) || tableA.numberOfColumns != tableB.numberOfColumns || tableA.layoutAlgorithm != tableB.layoutAlgorithm || tableA.collapsesBorders != tableB.collapsesBorders || tableA.hidesEmptyCells != tableB.hidesEmptyCells)
		return NO;
	for(NSString* key in @[ @"rowCount", @"cornerRadius", @"stripeColor", @"lineColor" ]) // OakMarkdown’s rounded tables
	{
		if([tableA respondsToSelector:NSSelectorFromString(key)] && !SameObjects([tableA valueForKey:key], [tableB valueForKey:key]))
			return NO;
	}
	return YES;
}

static BOOL SameParagraphStyle (NSParagraphStyle* a, NSParagraphStyle* b)
{
	if(SameObjects(a, b))
		return YES;
	if(!a || !b || a.textBlocks.count != b.textBlocks.count)
		return NO;
	for(NSUInteger i = 0; i < a.textBlocks.count; ++i)
	{
		if(!SameTextBlock(a.textBlocks[i], b.textBlocks[i]))
			return NO;
	}
	NSMutableParagraphStyle* withoutBlocksA = [a mutableCopy];
	NSMutableParagraphStyle* withoutBlocksB = [b mutableCopy];
	withoutBlocksA.textBlocks = @[ ];
	withoutBlocksB.textBlocks = @[ ];
	return [withoutBlocksA isEqual:withoutBlocksB];
}

static BOOL SameAttachment (NSTextAttachment* a, NSTextAttachment* b)
{
	if(SameObjects(a, b))
		return YES;
	// A code view’s placeholder: the view itself is found by AgentCodeBlockKeyAttributeName
	id cellA = a.attachmentCell, cellB = b.attachmentCell;
	return [cellA isKindOfClass:[AgentCodeBlockAttachmentCell class]] && [cellB isKindOfClass:[AgentCodeBlockAttachmentCell class]] && [(AgentCodeBlockAttachmentCell*)cellA height] == [(AgentCodeBlockAttachmentCell*)cellB height];
}

// `stored` is from the text storage, which adds a font where `rendered` has none
static BOOL SameAttributes (NSDictionary* stored, NSDictionary* rendered)
{
	if([stored isEqualToDictionary:rendered])
		return YES;
	static NSFont* const fixedFont = [NSFont fontWithName:@"Helvetica" size:12];
	NSMutableSet* keys = [NSMutableSet setWithArray:stored.allKeys];
	[keys addObjectsFromArray:rendered.allKeys];
	for(NSAttributedStringKey key in keys)
	{
		id a = stored[key], b = rendered[key];
		if([key isEqualToString:NSFontAttributeName] && !b && SameObjects(a, fixedFont))
			continue;
		if([key isEqualToString:NSParagraphStyleAttributeName] ? !SameParagraphStyle(a, b) : ([key isEqualToString:NSAttachmentAttributeName] ? !SameAttachment(a, b) : !SameObjects(a, b)))
			return NO;
	}
	return YES;
}

// Whether two paragraph styles of `rendered` share a text block (or table), i.e. lay out as one
static BOOL ShareBlock (NSParagraphStyle* a, NSParagraphStyle* b)
{
	for(NSTextBlock* blockA in a.textBlocks)
	{
		for(NSTextBlock* blockB in b.textBlocks)
		{
			if(blockA == blockB)
				return YES;
			if([blockA isKindOfClass:[NSTextTableBlock class]] && [blockB isKindOfClass:[NSTextTableBlock class]] && ((NSTextTableBlock*)blockA).table == ((NSTextTableBlock*)blockB).table)
				return YES;
		}
	}
	return NO;
}

// How many characters at the start of `range` in `storage` are already as in
// `rendered`. The rest is replaced, from there, so layout starts there rather
// than at the item’s start. A text block (a table, code, a quote) that the
// change falls in is replaced whole: half old and half new, it would draw as two.
static NSUInteger SameStartLength (NSTextStorage* storage, NSRange range, NSAttributedString* rendered)
{
	NSUInteger const length = MIN(range.length, rendered.length);
	if(!length)
		return 0;

	std::vector<unichar> oldChars(length), newChars(length);
	[storage.string getCharacters:oldChars.data() range:NSMakeRange(range.location, length)];
	[rendered.string getCharacters:newChars.data() range:NSMakeRange(0, length)];
	NSUInteger same = 0;
	while(same < length && oldChars[same] == newChars[same])
		++same;

	for(NSUInteger i = 0; i < same; )
	{
		NSRange oldRun, newRun;
		NSDictionary* oldAttributes = [storage attributesAtIndex:range.location + i effectiveRange:&oldRun];
		NSDictionary* newAttributes = [rendered attributesAtIndex:i effectiveRange:&newRun];
		if(!SameAttributes(oldAttributes, newAttributes))
		{
			same = i;
			break;
		}
		i = MIN(NSMaxRange(oldRun) - range.location, NSMaxRange(newRun));
	}

	if(same >= rendered.length)
		return same;

	// Not inside a character made of several code units (e.g. an emoji)
	NSString* text = rendered.string;
	same = [text rangeOfComposedCharacterSequenceAtIndex:same].location;

	// From the start of the paragraph, and of the text block it’s in
	NSUInteger start = [text paragraphRangeForRange:NSMakeRange(same, 0)].location;
	NSParagraphStyle* style = [rendered attribute:NSParagraphStyleAttributeName atIndex:start effectiveRange:nullptr];
	if(style.textBlocks.count)
	{
		while(start)
		{
			NSUInteger previous = [text paragraphRangeForRange:NSMakeRange(start - 1, 0)].location;
			if(!ShareBlock(style, [rendered attribute:NSParagraphStyleAttributeName atIndex:previous effectiveRange:nullptr]))
				break;
			start = previous;
		}
		same = start;
	}
	return same;
}

- (void)flushPendingItems
{
	_flushScheduled = NO;
	if(!_pendingIdentifiers.count)
		return;
	for(AgentTranscriptItem* item in [_transcript foldPassedReplies])
		[_pendingIdentifiers addObject:item.identifier];

	BOOL wasAtBottom = _followsEnd || (!_reloading && [self isScrolledToBottom]);
	BOOL followsEnd  = _followsEnd;
	CGFloat anchorTop = 0, oldOrigin = NSMinY(self.visibleRect);
	NSString* anchorItem = _reloading ? nil : [self anchorItemTop:&anchorTop];
	_clickedIdentifier = nil;
	NSTextStorage* storage = self.textStorage;
	[storage beginEditing];
	_fileTexts = [NSMutableDictionary dictionary];

	NSUInteger location = 0;
	__block NSRange newPermissionOptions = NSMakeRange(NSNotFound, 0);
	AgentTranscriptItem* lastShown = [self lastShownItem];
	BOOL hiding = NO;
	for(AgentTranscriptItem* item in _transcript.items)
	{
		NSString* identifier = item.identifier;
		NSNumber* oldLength  = _renderedLengths[identifier];

		// After an open question: shown once it’s answered
		if(hiding)
		{
			if(oldLength)
				[storage deleteCharactersInRange:NSMakeRange(location, oldLength.unsignedIntegerValue)];
			[_renderedLengths removeObjectForKey:identifier];
			continue;
		}
		hiding = item == lastShown;

		if(!oldLength || [_pendingIdentifiers containsObject:identifier])
		{
			NSAttributedString* rendered = [self renderItem:item];
			// A card shows in its own item or in its tool call’s row
			[rendered enumerateAttribute:AgentPermissionOptionsAttributeName inRange:NSMakeRange(0, rendered.length) options:0 usingBlock:^(NSString* permissionId, NSRange range, BOOL* stop){
				if(permissionId && ![_scrolledToPermissionIds containsObject:permissionId])
				{
					[_scrolledToPermissionIds addObject:permissionId];
					if(newPermissionOptions.location == NSNotFound)
						newPermissionOptions = NSMakeRange(location + range.location, range.length);
				}
			}];
			if(oldLength)
			{
				// Only from the first change, so layout starts there rather than at the item’s start
				NSUInteger const oldLen = oldLength.unsignedIntegerValue;
				NSUInteger const same   = SameStartLength(storage, NSMakeRange(location, oldLen), rendered);
				if(same < oldLen || same < rendered.length)
					[storage replaceCharactersInRange:NSMakeRange(location + same, oldLen - same) withAttributedString:[rendered attributedSubstringFromRange:NSMakeRange(same, rendered.length - same)]];
			}
			else
			{
				[storage insertAttributedString:rendered atIndex:location];
			}

			_renderedLengths[identifier] = @(rendered.length);
		}
		location += _renderedLengths[identifier].unsignedIntegerValue;
	}

	[storage endEditing];
	[_pendingIdentifiers removeAllObjects];
	_fileTexts = nil;

	[self positionCodeViews];
	[self.layoutManager ensureLayoutForTextContainer:self.textContainer];
	if(anchorItem)
		[self keepItem:anchorItem atTop:anchorTop origin:oldOrigin];
	_followsEnd = followsEnd; // the text changing isn’t the user scrolling
	if(_makesRoomForReply)
	{
		_makesRoomForReply = NO;
		[self addRoomForReply];
	}
	NSRect end = NSMakeRect(0, NSHeight(self.frame) - 1, 1, 1);
	if(newPermissionOptions.location != NSNotFound)
	{
		// The agent waits for an answer, so show the question and its options;
		// what comes after them too when it fits
		NSRect options = NSInsetRect([self rectOfRange:newPermissionOptions], 0, -8);
		NSRect toEnd   = NSUnionRect(options, end);
		BOOL fits      = NSHeight(toEnd) <= NSHeight(self.visibleRect);
		[self smoothlyScrollRectToVisible:(wasAtBottom && fits ? toEnd : options) toBottom:wasAtBottom && fits];
	}
	else if(wasAtBottom && !_reloading) // reloadData goes to the end at once
	{
		[self smoothlyScrollRectToVisible:end toBottom:YES];
	}
	self.needsDisplay = YES;
}

// Renders everything again. Scrolled up, the chat keeps the text at the top
// where it was, by item and offset since the item’s text may change.
- (void)reloadData
{
	BOOL followsEnd = _followsEnd;
	[self stopGliding];
	[self removeRoomForReply];
	NSString* anchorItem = nil;
	NSUInteger anchorOffset = 0;
	CGFloat anchorDelta = 0;
	if(!followsEnd && self.textStorage.length)
	{
		NSRect visible = self.visibleRect;
		NSPoint point = NSMakePoint(NSMinX(visible) - self.textContainerOrigin.x, NSMinY(visible) - self.textContainerOrigin.y);
		NSUInteger glyph = [self.layoutManager glyphIndexForPoint:point inTextContainer:self.textContainer];
		NSUInteger index = [self.layoutManager characterIndexForGlyphAtIndex:glyph];
		NSUInteger location = 0;
		for(AgentTranscriptItem* item in _transcript.items)
		{
			NSUInteger length = _renderedLengths[item.identifier].unsignedIntegerValue;
			if(index < location + length)
			{
				anchorItem   = item.identifier;
				anchorOffset = index - location;
				anchorDelta  = NSMinY(visible) - NSMinY([self rectOfRange:NSMakeRange(index, 1)]);
				break;
			}
			location += length;
		}
	}

	NSUInteger permissionCount = _scrolledToPermissionIds.count;
	_reloading = YES; // emptying the text scrolls to the top, which isn’t the user’s doing
	[_renderedLengths removeAllObjects];
	[_codeBlocks removeAllObjects];
	[self.textStorage setAttributedString:[[NSAttributedString alloc] init]];

	for(AgentTranscriptItem* item in _transcript.items)
		[_pendingIdentifiers addObject:item.identifier];
	[self flushPendingItems];
	_reloading = NO;

	// Emptying the text left it at the top; the end is where it was, not somewhere to glide to
	if(followsEnd && _scrolledToPermissionIds.count == permissionCount && [self.superview isKindOfClass:[NSClipView class]])
	{
		NSClipView* clipView = (NSClipView*)self.superview;
		NSPoint origin = NSMakePoint(NSMinX(clipView.bounds), MAX(0, NSHeight(self.frame) - NSHeight(clipView.bounds)));
		_lastScrollOrigin = origin;
		[clipView setBoundsOrigin:origin];
		[clipView.enclosingScrollView reflectScrolledClipView:clipView];
	}

	// A new question has been scrolled to, as the agent waits for its answer
	if(anchorItem && _scrolledToPermissionIds.count == permissionCount && [self.superview isKindOfClass:[NSClipView class]])
	{
		NSUInteger location = 0;
		for(AgentTranscriptItem* item in _transcript.items)
		{
			NSUInteger length = _renderedLengths[item.identifier].unsignedIntegerValue;
			if([item.identifier isEqualToString:anchorItem])
			{
				if(length)
				{
					NSUInteger index = location + MIN(anchorOffset, length - 1);
					NSClipView* clipView = (NSClipView*)self.superview;
					CGFloat y = NSMinY([self rectOfRange:NSMakeRange(index, 1)]) + anchorDelta;
					y = MAX(0, MIN(y, NSHeight(self.frame) - NSHeight(clipView.bounds)));
					NSPoint origin = NSMakePoint(NSMinX(clipView.bounds), y);
					_lastScrollOrigin = origin;
					[clipView setBoundsOrigin:origin];
					[clipView.enclosingScrollView reflectScrolledClipView:clipView];
				}
				break;
			}
			location += length;
		}
	}
	self.needsDisplay = YES;
}

- (void)setCodeBlockBackgroundColor:(NSColor*)backgroundColor textColor:(NSColor*)textColor highlighter:(NSAttributedString*(^)(NSString* code, NSString* language))highlighter
{
	_markdownStyle.codeBlockBackgroundColor = backgroundColor;
	_markdownStyle.codeBlockTextColor       = textColor;
	_markdownStyle.codeHighlighter          = highlighter;
	[self removeCodeViewsExcept:nil]; // new ones get the new theme
	[self reloadData];
}

// ===============
// = Code Views =
// ===============

- (NSView<AgentCodeBlockView>*)codeViewForKey:(NSString*)key code:(NSString*)code language:(NSString*)language
{
	if(NSView<AgentCodeBlockView>* view = _codeViews[key])
	{
		view.code = code;
		return view;
	}

	if(![_actionDelegate respondsToSelector:@selector(transcriptView:viewForCode:language:)])
		return nil;
	NSView<AgentCodeBlockView>* view = [_actionDelegate transcriptView:self viewForCode:code language:language];
	if(view)
	{
		_codeViews[key] = view;
		[view addObserver:self forKeyPath:@"fittingHeight" options:0 context:kFittingHeightContext];
	}
	return view;
}

- (void)removeCodeViewsExcept:(NSSet<NSString*>*)keep
{
	for(NSString* key in _codeViews.allKeys)
	{
		if([keep containsObject:key])
			continue;
		NSView<AgentCodeBlockView>* view = _codeViews[key];
		[view removeObserver:self forKeyPath:@"fittingHeight" context:kFittingHeightContext];
		[view removeFromSuperview];
		[_codeViews removeObjectForKey:key];
	}
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if(context != kFittingHeightContext)
		return [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];

	// Resize the view’s attachment
	NSString* key = [_codeViews allKeysForObject:object].firstObject;
	NSTextStorage* storage = self.textStorage;
	[storage enumerateAttribute:AgentCodeBlockKeyAttributeName inRange:NSMakeRange(0, storage.length) options:0 usingBlock:^(NSString* value, NSRange range, BOOL* stop){
		if(![value isEqualToString:key])
			return;
		NSTextAttachment* attachment = [storage attribute:NSAttachmentAttributeName atIndex:range.location effectiveRange:nullptr];
		if([attachment.attachmentCell isKindOfClass:[AgentCodeBlockAttachmentCell class]])
		{
			((AgentCodeBlockAttachmentCell*)attachment.attachmentCell).height = [object fittingHeight];
			[self.layoutManager invalidateLayoutForCharacterRange:range actualCharacterRange:nullptr];
		}
		*stop = YES;
	}];
	[self schedulePositionCodeViews];
}

- (void)layoutManager:(NSLayoutManager*)layoutManager didCompleteLayoutForTextContainer:(NSTextContainer*)textContainer atEnd:(BOOL)layoutFinishedFlag
{
	if(!_positioningCodeViews && _codeViews.count)
		[self schedulePositionCodeViews];
}

- (void)schedulePositionCodeViews
{
	if(_positionCodeViewsScheduled)
		return;
	_positionCodeViewsScheduled = YES;
	[self performSelector:@selector(positionScheduledCodeViews) withObject:nil afterDelay:0 inModes:@[ NSRunLoopCommonModes ]];
}

- (void)positionScheduledCodeViews
{
	_positionCodeViewsScheduled = NO;
	[self positionCodeViews];
}

// Puts each code view over its attachment; views without one are removed
- (void)positionCodeViews
{
	if(_positioningCodeViews)
		return;
	_positioningCodeViews = YES;

	NSLayoutManager* layoutManager = self.layoutManager;
	NSTextStorage* storage = self.textStorage;
	NSPoint origin = self.textContainerOrigin;
	NSMutableSet<NSString*>* present = [NSMutableSet set];

	[storage enumerateAttribute:AgentCodeBlockKeyAttributeName inRange:NSMakeRange(0, storage.length) options:0 usingBlock:^(NSString* key, NSRange range, BOOL*){
		NSView<AgentCodeBlockView>* view = key ? _codeViews[key] : nil;
		if(!view)
			return;
		[present addObject:key];

		NSUInteger glyph = [layoutManager glyphIndexForCharacterAtIndex:range.location];
		NSRect lineFragment = [layoutManager lineFragmentRectForGlyphAtIndex:glyph effectiveRange:nullptr];
		NSPoint location    = [layoutManager locationForGlyphAtIndex:glyph];
		NSSize size         = [layoutManager attachmentSizeForGlyphAtIndex:glyph];
		NSRect frame = NSMakeRect(origin.x + NSMinX(lineFragment) + location.x, origin.y + NSMinY(lineFragment) + location.y - size.height, size.width, size.height);

		if(view.superview != self)
			[self addSubview:view];
		if(!NSEqualRects(view.frame, frame))
			view.frame = frame;
	}];

	[self removeCodeViewsExcept:present];
	_positioningCodeViews = NO;
}

// =============
// = Rendering =
// =============

- (NSURL*)actionURL:(NSString*)action item:(AgentTranscriptItem*)item parameters:(NSDictionary<NSString*, NSString*>*)parameters
{
	NSURLComponents* components = [[NSURLComponents alloc] init];
	components.scheme = kActionScheme;
	components.host   = action;

	NSMutableArray* queryItems = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"item" value:item.identifier]];
	for(NSString* key in parameters)
		[queryItems addObject:[NSURLQueryItem queryItemWithName:key value:parameters[key]]];
	components.queryItems = queryItems;
	return components.URL;
}

- (NSAttributedString*)link:(NSString*)title url:(NSURL*)url
{
	return [[NSAttributedString alloc] initWithString:title attributes:@{ NSFontAttributeName: SmallFont(), NSLinkAttributeName: url }];
}

- (NSAttributedString*)text:(NSString*)text font:(NSFont*)font color:(NSColor*)color
{
	return [[NSAttributedString alloc] initWithString:text attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: color }];
}

// NO for a file the agent hasn’t created yet, e.g. while its write waits for approval
- (BOOL)fileExistsAtPath:(NSString*)path
{
	if(![_actionDelegate respondsToSelector:@selector(transcriptView:absolutePathForPath:)])
		return YES;
	return [_actionDelegate transcriptView:self absolutePathForPath:path] != nil;
}

// The index of the tool call’s diff for `path`, NSNotFound if it has none
static NSUInteger IndexOfDiffForPath (NSDictionary* toolCall, NSString* path)
{
	NSArray* contents = [toolCall[@"content"] isKindOfClass:[NSArray class]] ? toolCall[@"content"] : @[ ];
	for(NSUInteger i = 0; i < contents.count; ++i)
	{
		NSDictionary* content = contents[i];
		if([content isKindOfClass:[NSDictionary class]] && [content[@"type"] isEqualToString:@"diff"] && [content[@"path"] isEqual:path])
			return i;
	}
	return NSNotFound;
}

// ▸ / ▾ and a space, larger than the text so it’s easy to hit
- (NSAttributedString*)disclosure:(BOOL)open url:(NSURL*)url
{
	NSMutableAttributedString* res = [[NSMutableAttributedString alloc] initWithString:(open ? @"▾" : @"▸") attributes:@{ NSFontAttributeName: DisclosureFont(), NSBaselineOffsetAttributeName: @(-1), NSLinkAttributeName: url }];
	[res appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:NSFont.systemFontSize], NSLinkAttributeName: url }]];
	return res;
}

- (NSAttributedString*)foldToggleForItem:(AgentTranscriptItem*)item
{
	NSAttributedString* toggle = [self disclosure:!item.folded url:[self actionURL:@"fold" item:item parameters:@{ }]];
	return item.kind == AgentTranscriptItemKindToolCall ? toggle : [self workingMarker:toggle item:item];
}

- (NSAttributedString*)renderItem:(AgentTranscriptItem*)item
{
	NSMutableAttributedString* res = [[NSMutableAttributedString alloc] init];
	switch(item.kind)
	{
		case AgentTranscriptItemKindUser:     [self renderUserItem:item into:res];     break;
		case AgentTranscriptItemKindAgent:    [self renderAgentItem:item into:res];    break;
		case AgentTranscriptItemKindThought:  [self renderThoughtItem:item into:res];  break;
		case AgentTranscriptItemKindToolCall: [self renderToolCallItem:item into:res]; break;
		case AgentTranscriptItemKindPlan:     [self renderPlanItem:item into:res];     break;
		case AgentTranscriptItemKindNotice:   [res appendAttributedString:[self text:item.text font:SmallFont() color:NSColor.secondaryLabelColor]]; [self renderActionsOfItem:item into:res]; break;
		case AgentTranscriptItemKindError:    [res appendAttributedString:[self text:[@"⚠︎ " stringByAppendingString:item.text] font:SmallFont() color:NSColor.systemRedColor]]; [self renderActionsOfItem:item into:res]; break;
		case AgentTranscriptItemKindPermission: [self renderPermissionItem:item into:res]; break;
		case AgentTranscriptItemKindWaiting:
			if(item.text.length)
			{
				[res appendAttributedString:[self workingMarker:[self text:@"◐ " font:SmallFont() color:NSColor.secondaryLabelColor] item:item]];
				[res appendAttributedString:[self text:item.text font:[NSFont systemFontOfSize:NSFont.smallSystemFontSize] color:NSColor.secondaryLabelColor]];
				[res appendAttributedString:[self workingStatusOfItem:item]];
			}
			break;
	}
	if(!res.length) // e.g. a permission request shown in its tool call’s row
		return res;

	// End the item’s last paragraph, then a small spacer paragraph between items
	NSDictionary* lastAttributes = res.length ? [res attributesAtIndex:res.length - 1 effectiveRange:nullptr] : @{ };
	[res appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:lastAttributes]];
	[res appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:6] }]];
	return res;
}

- (void)renderActionsOfItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	NSString* separator = @"\n";
	for(NSDictionary<NSString*, NSString*>* action in item.actions)
	{
		[res appendAttributedString:[self text:separator font:SmallFont() color:NSColor.secondaryLabelColor]];
		[res appendAttributedString:[self link:action[@"title"] url:[self actionURL:@"item-action" item:item parameters:@{ @"action": action[@"action"] }]]];
		separator = @"   ";
	}
}

- (void)renderUserItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	NSTextBlock* block = [[NSTextBlock alloc] init];
	block.backgroundColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.12];
	[block setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth];
	[block setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
	[block setWidth:24 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];

	NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.textBlocks = @[ block ];

	[res appendAttributedString:[[NSAttributedString alloc] initWithString:item.text attributes:@{
		NSFontAttributeName:            [NSFont systemFontOfSize:NSFont.systemFontSize],
		NSForegroundColorAttributeName: NSColor.labelColor,
		NSParagraphStyleAttributeName:  paragraph,
	}]];

	if(item.attachmentNames.count)
	{
		NSString* names = [@"\n📎 " stringByAppendingString:[item.attachmentNames componentsJoinedByString:@", "]];
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:names attributes:@{
			NSFontAttributeName:            SmallFont(),
			NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
			NSParagraphStyleAttributeName:  paragraph,
		}]];
	}
}

- (void)renderAgentItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	NSArray<OakMarkdownCodeBlock*>* codeBlocks;
	if(item.folded)
	{
		NSAttributedString* rendered = [OakMarkdownRenderer attributedStringFromMarkdown:item.text style:_markdownStyle codeBlocks:&codeBlocks codeBlockFooter:nil];
		_codeBlocks[item.identifier] = codeBlocks;

		NSString* summary = FirstLine(rendered.string, kSummaryLength);
		if(codeBlocks.count)
			summary = [summary stringByAppendingFormat:@"  · %lu code block%@", codeBlocks.count, codeBlocks.count == 1 ? @"" : @"s"];
		[res appendAttributedString:[self foldToggleForItem:item]];
		[res appendAttributedString:[self text:summary font:[NSFont systemFontOfSize:NSFont.systemFontSize] color:NSColor.secondaryLabelColor]];
		[res appendAttributedString:[self workingStatusOfItem:item]];
		return;
	}

	__weak AgentTranscriptView* weakSelf = self;
	_markdownStyle.codeBlockReplacement = ^NSAttributedString*(OakMarkdownCodeBlock* codeBlock, NSUInteger index, NSAttributedString* rendered){
		return [weakSelf codeBlock:codeBlock index:index rendered:rendered item:item];
	};
	NSAttributedString* rendered = [OakMarkdownRenderer attributedStringFromMarkdown:item.text style:_markdownStyle codeBlocks:&codeBlocks codeBlockFooter:nil];
	_markdownStyle.codeBlockReplacement = nil;
	_codeBlocks[item.identifier] = codeBlocks;

	// The toggle goes in the first paragraph, with its style
	NSMutableAttributedString* toggle = [[self foldToggleForItem:item] mutableCopy];
	if(rendered.length)
	{
		if(NSParagraphStyle* paragraph = [rendered attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:nullptr])
			[toggle addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, toggle.length)];
	}
	[res appendAttributedString:toggle];
	[res appendAttributedString:rendered];
	[res appendAttributedString:[self workingStatusOfItem:item]];
}

// A code block’s line: ▸ / ▾, language, lines and place; unfolded, then the
// code (an editor view in an attachment, or else the rendered text) and its
// actions
- (NSAttributedString*)codeBlock:(OakMarkdownCodeBlock*)codeBlock index:(NSUInteger)index rendered:(NSAttributedString*)rendered item:(AgentTranscriptItem*)item
{
	NSString* key = [NSString stringWithFormat:@"%@:%lu", item.identifier, index];
	BOOL unfolded = _foldsCodeBlocks == [_toggledCodeBlocks containsObject:key];
	NSDictionary* parameters = @{ @"block": [NSString stringWithFormat:@"%lu", index] };

	NSString* language = codeBlock.language;
	if(language && [_actionDelegate respondsToSelector:@selector(transcriptView:displayNameForLanguage:)])
		language = [_actionDelegate transcriptView:self displayNameForLanguage:language] ?: language;
	NSUInteger lines = LineCount(codeBlock.code);
	NSString* title = [NSString stringWithFormat:@"%@ · %lu line%@", language ?: @"Code", lines, lines == 1 ? @"" : @"s"];

	NSURL* toggleURL = [self actionURL:@"code" item:item parameters:parameters];
	NSMutableAttributedString* res = [[NSMutableAttributedString alloc] init];
	[res appendAttributedString:[self disclosure:unfolded url:toggleURL]];
	[res appendAttributedString:[self link:title url:toggleURL]];

	NSAttributedString* separator = [self text:@" · " font:SmallFont() color:NSColor.secondaryLabelColor];
	if(NSDictionary* place = [self placeOfCodeBlock:codeBlock item:item])
	{
		NSString* path = place[@"path"];
		NSString* placeTitle = path.lastPathComponent;
		NSMutableDictionary* openParameters = [NSMutableDictionary dictionaryWithObject:path forKey:@"path"];
		if(NSNumber* line = place[@"line"])
		{
			NSUInteger lastLine = [place[@"lastLine"] unsignedIntegerValue];
			placeTitle = lastLine > line.unsignedIntegerValue ? [NSString stringWithFormat:@"%@:%@–%lu", placeTitle, line, lastLine] : [NSString stringWithFormat:@"%@:%@", placeTitle, line];
			openParameters[@"line"] = line.stringValue;
		}
		[res appendAttributedString:separator];
		[res appendAttributedString:[self link:placeTitle url:[self actionURL:@"open" item:item parameters:openParameters]]];
	}
	else if(NSString* firstLine = FirstLine(codeBlock.code, kFirstLineLength); firstLine.length)
	{
		[res appendAttributedString:separator];
		[res appendAttributedString:[self text:firstLine font:SmallMonospaceFont() color:NSColor.secondaryLabelColor]];
	}

	if(!unfolded)
	{
		[res appendAttributedString:[self text:@"   " font:SmallFont() color:NSColor.secondaryLabelColor]];
		[res appendAttributedString:[self link:@"Copy" url:[self actionURL:@"copy" item:item parameters:parameters]]];
		return res;
	}

	NSMutableParagraphStyle* codeParagraph = [[NSMutableParagraphStyle alloc] init];
	codeParagraph.paragraphSpacingBefore = 3;
	codeParagraph.paragraphSpacing       = 3;

	[res appendAttributedString:[self text:@"\n" font:SmallFont() color:NSColor.secondaryLabelColor]];
	if(NSView<AgentCodeBlockView>* view = [self codeViewForKey:key code:codeBlock.code language:codeBlock.language])
	{
		AgentCodeBlockAttachmentCell* cell = [[AgentCodeBlockAttachmentCell alloc] init];
		cell.height = view.fittingHeight;
		NSTextAttachment* attachment = [[NSTextAttachment alloc] init];
		attachment.attachmentCell = cell;

		NSMutableAttributedString* str = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
		[str addAttributes:@{ AgentCodeBlockKeyAttributeName: key, NSParagraphStyleAttributeName: codeParagraph, NSFontAttributeName: SmallFont() } range:NSMakeRange(0, str.length)];
		[res appendAttributedString:str];
	}
	else
	{
		[res appendAttributedString:rendered];
	}

	NSMutableAttributedString* footer = [[NSMutableAttributedString alloc] init];
	[footer appendAttributedString:[self text:@"\n" font:SmallFont() color:NSColor.secondaryLabelColor]];
	[footer appendAttributedString:[self link:@"Copy" url:[self actionURL:@"copy" item:item parameters:parameters]]];
	[footer appendAttributedString:[self text:@"   " font:SmallFont() color:NSColor.secondaryLabelColor]];
	[footer appendAttributedString:[self link:@"Insert at Cursor" url:[self actionURL:@"insert" item:item parameters:parameters]]];
	[footer appendAttributedString:[self text:@"   " font:SmallFont() color:NSColor.secondaryLabelColor]];
	[footer appendAttributedString:[self link:@"Apply in Editor" url:[self actionURL:@"apply" item:item parameters:parameters]]];
	NSMutableParagraphStyle* footerParagraph = [[NSMutableParagraphStyle alloc] init];
	footerParagraph.paragraphSpacing = 6;
	[footer addAttribute:NSParagraphStyleAttributeName value:footerParagraph range:NSMakeRange(1, footer.length - 1)];
	[res appendAttributedString:footer];
	return res;
}

// Where a code block sits: a file named by its fence or the text before it,
// or touched by the turn’s tool calls, or open, whose text contains the
// code. A file named by the fence is the place even without the code in it.
// Whether a closing fence follows the block’s code in `markdown`
static BOOL CodeBlockIsClosed (OakMarkdownCodeBlock* codeBlock, NSString* markdown)
{
	NSRange code = codeBlock.code.length ? [markdown rangeOfString:codeBlock.code options:NSBackwardsSearch] : NSMakeRange(NSNotFound, 0);
	if(code.location == NSNotFound)
		return YES; // can’t tell, so look it up
	NSString* rest = [markdown substringFromIndex:NSMaxRange(code)];
	for(NSString* line in [rest componentsSeparatedByString:@"\n"])
	{
		NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if([trimmed hasPrefix:@"```"] || [trimmed hasPrefix:@"~~~"])
			return YES;
	}
	return NO;
}

- (NSDictionary*)placeOfCodeBlock:(OakMarkdownCodeBlock*)codeBlock item:(AgentTranscriptItem*)item
{
	if(![_actionDelegate respondsToSelector:@selector(transcriptView:absolutePathForPath:)] || ![_actionDelegate respondsToSelector:@selector(transcriptView:textOfFileAtPath:)])
		return nil;

	// A block still streaming changes with each update, so it would search the
	// files again each time (most of the time an update took); wait for its end
	if(item == _workingItem && !CodeBlockIsClosed(codeBlock, item.text))
		return nil;

	NSString* cacheKey = [NSString stringWithFormat:@"%@\n%@\n%@", item.identifier, codeBlock.info ?: @"", codeBlock.code];
	if(id cached = [_codePlaces objectForKey:cacheKey])
		return cached == NSNull.null ? nil : cached;

	NSArray<NSString*>* fencePaths = [AgentCodeLocation pathsInInfo:codeBlock.info];
	NSMutableArray<NSString*>* candidates = [fencePaths mutableCopy];
	for(NSString* path in [AgentCodeLocation pathsInText:[AgentCodeLocation textBeforeCode:codeBlock.code inMarkdown:item.text]])
	{
		if(![candidates containsObject:path])
			[candidates addObject:path];
	}
	for(NSString* path in [self pathsOfTurnOfItem:item])
	{
		if(![candidates containsObject:path])
			[candidates addObject:path];
	}
	if([_actionDelegate respondsToSelector:@selector(openFilePathsForTranscriptView:)])
	{
		for(NSString* path in [_actionDelegate openFilePathsForTranscriptView:self])
		{
			if(![candidates containsObject:path])
				[candidates addObject:path];
		}
	}

	NSDictionary* res = nil;
	NSString* firstFencePath = nil;
	for(NSString* candidate in candidates)
	{
		NSString* path = [_actionDelegate transcriptView:self absolutePathForPath:candidate];
		if(!path)
			continue;
		if(!firstFencePath && [fencePaths containsObject:candidate])
			firstFencePath = path;

		id text = _fileTexts[path];
		if(!text)
		{
			text = [_actionDelegate transcriptView:self textOfFileAtPath:path] ?: NSNull.null;
			_fileTexts[path] = text;
		}
		if(text == NSNull.null)
			continue;

		NSRange lines = [AgentCodeLocation lineRangeOfCode:codeBlock.code inText:text];
		if(lines.location != NSNotFound)
		{
			res = @{ @"path": path, @"line": @(lines.location), @"lastLine": @(NSMaxRange(lines) - 1) };
			break;
		}
	}

	if(!res && firstFencePath)
		res = @{ @"path": firstFencePath };
	[_codePlaces setObject:res ?: NSNull.null forKey:cacheKey];
	return res;
}

// Files the tool calls between the user message before `item` and the next one touched
- (NSArray<NSString*>*)pathsOfTurnOfItem:(AgentTranscriptItem*)item
{
	NSArray<AgentTranscriptItem*>* items = _transcript.items;
	NSUInteger index = [items indexOfObjectIdenticalTo:item];
	if(index == NSNotFound)
		return @[ ];

	NSUInteger first = index, last = index;
	while(first > 0 && items[first - 1].kind != AgentTranscriptItemKindUser)
		--first;
	while(last + 1 < items.count && items[last + 1].kind != AgentTranscriptItemKindUser)
		++last;

	NSMutableArray<NSString*>* res = [NSMutableArray array];
	for(NSUInteger i = last + 1; i-- > first; )
	{
		NSDictionary* toolCall = items[i].kind == AgentTranscriptItemKindToolCall ? items[i].toolCall : nil;
		for(NSDictionary* location in [toolCall[@"locations"] isKindOfClass:[NSArray class]] ? toolCall[@"locations"] : @[ ])
		{
			NSString* path = [location[@"path"] isKindOfClass:[NSString class]] ? PathFromURI(location[@"path"]) : nil;
			if(path && ![res containsObject:path])
				[res addObject:path];
		}
		for(NSDictionary* content in [toolCall[@"content"] isKindOfClass:[NSArray class]] ? toolCall[@"content"] : @[ ])
		{
			NSString* path = [content[@"type"] isEqualToString:@"diff"] && [content[@"path"] isKindOfClass:[NSString class]] ? content[@"path"] : nil;
			if(path && ![res containsObject:path])
				[res addObject:path];
		}
	}
	return res;
}

- (void)renderThoughtItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	NSURL* toggleURL = [self actionURL:@"toggle" item:item parameters:@{ }];
	[res appendAttributedString:[self workingMarker:[self disclosure:item.expanded url:toggleURL] item:item]];
	[res appendAttributedString:[self link:@"Thinking" url:toggleURL]];
	[res appendAttributedString:[self workingStatusOfItem:item]];
	if(item.expanded && item.text.length)
		[res appendAttributedString:[self text:[@"\n" stringByAppendingString:item.text] font:SmallFont() color:NSColor.secondaryLabelColor]];
}

- (void)renderToolCallItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	NSDictionary* toolCall = item.toolCall;
	NSString* status       = toolCall[@"status"];
	NSString* title        = [toolCall[@"title"] isKindOfClass:[NSString class]] ? toolCall[@"title"] : @"Tool call";

	AgentTranscriptItem* permission = [self permissionItemForToolCallId:toolCall[@"toolCallId"]];
	BOOL asking = permission && !permission.permissionResolved;

	BOOL hasDetails = [toolCall[@"locations"] isKindOfClass:[NSArray class]] && [toolCall[@"locations"] count] || [toolCall[@"content"] isKindOfClass:[NSArray class]] && [toolCall[@"content"] count];
	if(hasDetails) // a question stays open with what it’s about
		[res appendAttributedString:[self disclosure:!item.folded || asking url:[self actionURL:@"fold" item:item parameters:@{ }]]];
	[res appendAttributedString:[self workingMarker:[self text:[ToolStatusGlyph(status) stringByAppendingString:@" "] font:SmallFont() color:ToolStatusColor(status)] item:item]];
	[res appendAttributedString:[self text:title font:[NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium] color:NSColor.labelColor]];
	[res appendAttributedString:[self workingStatusOfItem:item]];
	if(permission.permissionResolved)
	{
		[res appendAttributedString:[self text:@"  ·  " font:SmallFont() color:NSColor.secondaryLabelColor]];
		[res appendAttributedString:[self outcomeOfPermissionItem:permission]];
	}

	// The question comes after what it’s about, e.g. the diff of a write
	if(!item.folded || asking)
		[self appendDetailsOfToolCall:toolCall item:item into:res];
	if(asking)
	{
		[res appendAttributedString:[self text:@"\n" font:SmallFont() color:NSColor.labelColor]];
		[res appendAttributedString:[self cardOfPermissionItem:permission toolCall:toolCall details:NO]];
	}
}

// Locations as links to open, then the tool call’s content
- (void)appendDetailsOfToolCall:(NSDictionary*)toolCall item:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	for(NSDictionary* location in [toolCall[@"locations"] isKindOfClass:[NSArray class]] ? toolCall[@"locations"] : @[ ])
	{
		NSString* path = location[@"path"];
		if(![path isKindOfClass:[NSString class]])
			continue;
		NSString* line = [location[@"line"] respondsToSelector:@selector(stringValue)] ? [location[@"line"] stringValue] : nil;
		NSString* title = line ? [NSString stringWithFormat:@"%@:%@", path.lastPathComponent, line] : path.lastPathComponent;
		[res appendAttributedString:[self text:@"\n    ↳ " font:SmallFont() color:NSColor.secondaryLabelColor]];
		if([self fileExistsAtPath:PathFromURI(path)])
		{
			[res appendAttributedString:[self link:title url:[self actionURL:@"open" item:item parameters:line ? @{ @"path": path, @"line": line } : @{ @"path": path }]]];
		}
		else
		{
			// Not created yet: the link shows what the agent wants to write, if it says
			NSUInteger diffIndex = IndexOfDiffForPath(toolCall, path);
			if(diffIndex != NSNotFound)
					[res appendAttributedString:[self link:path.lastPathComponent url:[self actionURL:@"diff" item:item parameters:@{ @"content": [NSString stringWithFormat:@"%lu", diffIndex] }]]];
			else	[res appendAttributedString:[self text:path.lastPathComponent font:SmallFont() color:NSColor.labelColor]];
			[res appendAttributedString:[self text:@"  not created yet" font:SmallFont() color:NSColor.secondaryLabelColor]];
		}
	}

	for(NSDictionary* content in [toolCall[@"content"] isKindOfClass:[NSArray class]] ? toolCall[@"content"] : @[ ])
	{
		NSString* type = content[@"type"];
		if([type isEqualToString:@"diff"])
		{
			[self appendDiff:content index:[toolCall[@"content"] indexOfObjectIdenticalTo:content] item:item into:res];
		}
		else if([type isEqualToString:@"terminal"])
		{
			if(AgentTerminal* terminal = [_terminalManager terminalWithIdentifier:content[@"terminalId"]])
				[self appendTerminalOutput:terminal.output commandLine:terminal.commandLine truncated:terminal.truncated exited:terminal.exited exitCode:terminal.exitCode signal:terminal.signal stoppableTerminal:(terminal.released ? nil : terminal) item:item into:res];
			else if(AgentTranscriptTerminal* terminal = [_transcript terminalWithIdentifier:content[@"terminalId"]])
				[self appendTerminalOutput:terminal.output commandLine:CommandOfToolCall(toolCall) truncated:NO exited:terminal.exited exitCode:terminal.exitCode signal:terminal.signal stoppableTerminal:nil item:item into:res];
			else
				[res appendAttributedString:[self text:@"\n    Terminal" font:SmallFont() color:NSColor.secondaryLabelColor]];
		}
		else if([type isEqualToString:@"content"] && [content[@"content"][@"type"] isEqualToString:@"text"])
		{
			// The first lines, all of them when expanded
			NSArray* lines = [content[@"content"][@"text"] componentsSeparatedByString:@"\n"];
			BOOL cut = !item.expanded && lines.count > kOutputPreviewLines;
			NSString* preview = [[lines subarrayWithRange:NSMakeRange(0, cut ? kOutputPreviewLines : lines.count)] componentsJoinedByString:@"\n    "];
			[res appendAttributedString:[self text:[@"\n    " stringByAppendingString:preview] font:SmallMonospaceFont() color:NSColor.secondaryLabelColor]];
			if(cut || (item.expanded && lines.count > kOutputPreviewLines))
			{
				[res appendAttributedString:[self text:@"\n    " font:SmallFont() color:NSColor.secondaryLabelColor]];
				[res appendAttributedString:[self link:(cut ? [NSString stringWithFormat:@"Show all %lu lines", lines.count] : @"Show less") url:[self actionURL:@"toggle" item:item parameters:@{ }]]];
			}
		}
	}
}

// File name, +/− counts and a Diff link, then the changed lines; long diffs
// are cut short until expanded
- (void)appendDiff:(NSDictionary*)content index:(NSUInteger)index item:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	NSString* path    = [content[@"path"] isKindOfClass:[NSString class]] ? content[@"path"] : nil;
	NSString* oldText = [content[@"oldText"] isKindOfClass:[NSString class]] ? content[@"oldText"] : nil;
	NSString* newText = [content[@"newText"] isKindOfClass:[NSString class]] ? content[@"newText"] : @"";
	AgentDiff* diff   = [AgentDiff diffWithOldText:oldText newText:newText contextLines:1];

	NSDictionary* parameters = @{ @"content": [NSString stringWithFormat:@"%lu", index] };
	BOOL exists = path && [self fileExistsAtPath:path];
	[res appendAttributedString:[self text:@"\n    ✎ " font:SmallFont() color:NSColor.secondaryLabelColor]];
	if(exists)
			[res appendAttributedString:[self link:path.lastPathComponent url:[self actionURL:@"open" item:item parameters:@{ @"path": path }]]];
	else	[res appendAttributedString:[self text:path.lastPathComponent ?: @"file" font:SmallFont() color:NSColor.labelColor]];
	if(!oldText)
		[res appendAttributedString:[self text:(exists || !path ? @"  new" : @"  new, not created yet") font:SmallFont() color:NSColor.secondaryLabelColor]];
	[res appendAttributedString:[self text:[NSString stringWithFormat:@"  +%lu", diff.addedLineCount] font:SmallFont() color:NSColor.systemGreenColor]];
	[res appendAttributedString:[self text:[NSString stringWithFormat:@" −%lu", diff.removedLineCount] font:SmallFont() color:NSColor.systemRedColor]];
	[res appendAttributedString:[self text:@"   " font:SmallFont() color:NSColor.secondaryLabelColor]];
	[res appendAttributedString:[self link:@"Diff" url:[self actionURL:@"diff" item:item parameters:parameters]]];

	NSUInteger const total = AgentAppendDiffLines(res, diff, SmallMonospaceFont(), 20, item.expanded ? 0 : kDiffPreviewLines);

	if(total > kDiffPreviewLines)
	{
		NSString* title = item.expanded ? @"Show less" : [NSString stringWithFormat:@"Show all %lu lines", total];
		[res appendAttributedString:[self text:@"\n    " font:SmallFont() color:NSColor.secondaryLabelColor]];
		[res appendAttributedString:[self link:title url:[self actionURL:@"toggle" item:item parameters:@{ }]]];
	}
}

// Command line, the end of the output (all of it when expanded), and the
// exit status, or a Stop link while a command TextMate runs is running
- (void)appendTerminalOutput:(NSString*)rawOutput commandLine:(NSString*)commandLine truncated:(BOOL)truncated exited:(BOOL)exited exitCode:(NSNumber*)exitCode signal:(NSString*)signal stoppableTerminal:(AgentTerminal*)stoppableTerminal item:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.firstLineHeadIndent = paragraph.headIndent = 20;
	NSDictionary* commandAttributes = @{ NSFontAttributeName: SmallMonospaceFont(), NSForegroundColorAttributeName: NSColor.labelColor, NSParagraphStyleAttributeName: paragraph };
	NSDictionary* outputAttributes  = @{ NSFontAttributeName: SmallMonospaceFont(), NSForegroundColorAttributeName: NSColor.secondaryLabelColor, NSParagraphStyleAttributeName: paragraph };

	if(commandLine)
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n$ " stringByAppendingString:commandLine] attributes:commandAttributes]];

	NSString* output = DisplayTerminalOutput(rawOutput ?: @"");
	if([output hasSuffix:@"\n"])
		output = [output substringToIndex:output.length - 1];
	NSArray<NSString*>* lines = output.length ? [output componentsSeparatedByString:@"\n"] : @[ ];
	BOOL cut = !item.expanded && lines.count > kOutputPreviewLines;
	if(cut)
		lines = [lines subarrayWithRange:NSMakeRange(lines.count - kOutputPreviewLines, kOutputPreviewLines)];
	if(cut || truncated)
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n⋯" attributes:outputAttributes]];
	if(lines.count)
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:[lines componentsJoinedByString:@"\n"]] attributes:outputAttributes]];

	[res appendAttributedString:[self text:@"\n    " font:SmallFont() color:NSColor.secondaryLabelColor]];
	if(!exited)
	{
		[res appendAttributedString:[self text:@"Running…   " font:SmallFont() color:NSColor.secondaryLabelColor]];
		if(stoppableTerminal)
			[res appendAttributedString:[self link:@"Stop" url:[self actionURL:@"kill" item:item parameters:@{ @"terminal": stoppableTerminal.terminalId }]]];
	}
	else if(signal)
	{
		[res appendAttributedString:[self text:[NSString stringWithFormat:@"Stopped (%@)", signal] font:SmallFont() color:NSColor.secondaryLabelColor]];
	}
	else if(exitCode)
	{
		[res appendAttributedString:[self text:[NSString stringWithFormat:@"Exit code %@", exitCode] font:SmallFont() color:(exitCode.integerValue == 0 ? NSColor.systemGreenColor : NSColor.systemRedColor)]];
	}
	else
	{
		[res appendAttributedString:[self text:@"Finished" font:SmallFont() color:NSColor.secondaryLabelColor]];
	}

	if(item.expanded || cut)
	{
		[res appendAttributedString:[self text:@"   " font:SmallFont() color:NSColor.secondaryLabelColor]];
		[res appendAttributedString:[self link:(item.expanded ? @"Show less" : @"Show all output") url:[self actionURL:@"toggle" item:item parameters:@{ }]]];
	}
}

// Shown in its tool call’s row when there is one, else as a card of its own
- (void)renderPermissionItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	NSDictionary* toolCall = [self toolCallForItem:item];
	if([self toolCallItemWithIdentifier:toolCall[@"toolCallId"]])
		return;
	[res appendAttributedString:[self cardOfPermissionItem:item toolCall:toolCall details:YES]];
}

- (NSAttributedString*)outcomeOfPermissionItem:(AgentTranscriptItem*)item
{
	NSDictionary* selected = nil;
	for(NSDictionary* option in [item.permissionRequest[@"options"] isKindOfClass:[NSArray class]] ? item.permissionRequest[@"options"] : @[ ])
	{
		if([option isKindOfClass:[NSDictionary class]] && [option[@"optionId"] isEqual:item.selectedOptionId])
			selected = option;
	}
	NSString* outcome = selected ? [NSString stringWithFormat:@"%@ %@", PermissionOptionGlyph(selected[@"kind"]), selected[@"name"] ?: selected[@"optionId"]] : @"– Cancelled";
	NSColor* color = [selected[@"kind"] hasPrefix:@"allow"] ? NSColor.systemGreenColor : ([selected[@"kind"] hasPrefix:@"reject"] ? NSColor.systemRedColor : NSColor.secondaryLabelColor);
	return [self text:outcome font:SmallFont() color:color];
}

// The question, then its options (or the answer); with `details`, the tool
// call’s locations and content after them
- (NSAttributedString*)cardOfPermissionItem:(AgentTranscriptItem*)item toolCall:(NSDictionary*)toolCall details:(BOOL)withDetails
{
	NSArray* options = [item.permissionRequest[@"options"] isKindOfClass:[NSArray class]] ? item.permissionRequest[@"options"] : @[ ];

	NSTextBlock* block = [[NSTextBlock alloc] init];
	block.backgroundColor = [(item.permissionResolved ? NSColor.secondaryLabelColor : NSColor.systemOrangeColor) colorWithAlphaComponent:0.12];
	[block setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth];
	[block setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
	[block setWidth:4 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinYEdge];
	NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.textBlocks = @[ block ];

	NSMutableAttributedString* card = [[NSMutableAttributedString alloc] init];
	NSString* title = [toolCall[@"title"] isKindOfClass:[NSString class]] ? toolCall[@"title"] : @"Use a tool";
	[card appendAttributedString:[self text:@"Allow this action?\n" font:SmallFont() color:NSColor.secondaryLabelColor]];
	[card appendAttributedString:[self text:title font:[NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold] color:NSColor.labelColor]];
	if(NSString* command = CommandOfToolCall(toolCall))
	{
		if(![command isEqualToString:title])
			[card appendAttributedString:[self text:[@"\n$ " stringByAppendingString:command] font:SmallMonospaceFont() color:NSColor.labelColor]];
	}
	[card appendAttributedString:[self text:@"\n" font:SmallFont() color:NSColor.labelColor]];

	// The options come before the details, which can be long (a diff)
	if(!item.permissionResolved)
	{
		// The oldest open card answers ↩ and ⎋ in the empty message field
		BOOL takesKeys = item == _transcript.pendingPermissionItems.firstObject;
		NSString* allowId  = takesKeys ? [item permissionOptionIdAllowing:YES] : nil;
		NSString* rejectId = takesKeys ? [item permissionOptionIdAllowing:NO] : nil;
		for(NSDictionary* option in options)
		{
			if(option != options.firstObject)
				[card appendAttributedString:[self text:@"     " font:SmallFont() color:NSColor.labelColor]];
			NSString* name = [NSString stringWithFormat:@"%@ %@", PermissionOptionGlyph(option[@"kind"]), option[@"name"] ?: option[@"optionId"]];
			if([[option[@"optionId"] description] isEqualToString:allowId])
				name = [name stringByAppendingString:@" ↩"];
			else if([[option[@"optionId"] description] isEqualToString:rejectId])
				name = [name stringByAppendingString:@" ⎋"];
			NSMutableAttributedString* link = [[self link:name url:[self actionURL:@"permission" item:item parameters:@{ @"option": [option[@"optionId"] description] ?: @"" }]] mutableCopy];
			[link addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium] range:NSMakeRange(0, link.length)];
			[card appendAttributedString:link];
		}
		[card addAttribute:AgentPermissionOptionsAttributeName value:item.identifier range:NSMakeRange(0, card.length)];
	}
	else
	{
		[card appendAttributedString:[self outcomeOfPermissionItem:item]];
	}
	if(withDetails)
		[self appendDetailsOfToolCall:toolCall item:item into:card];

	[card addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, card.length)];
	return card;
}

- (void)renderPlanItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	[res appendAttributedString:[self foldToggleForItem:item]];
	[res appendAttributedString:[self text:@"Plan" font:[NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold] color:NSColor.labelColor]];
	if(item.folded)
	{
		NSUInteger done = [[item.planEntries valueForKey:@"status"] indexesOfObjectsPassingTest:^BOOL(id status, NSUInteger, BOOL*){ return [status isEqual:@"completed"]; }].count;
		[res appendAttributedString:[self text:[NSString stringWithFormat:@" · %lu of %lu done", done, item.planEntries.count] font:SmallFont() color:NSColor.secondaryLabelColor]];
		return;
	}
	for(NSDictionary* entry in item.planEntries)
	{
		NSString* status = entry[@"status"];
		NSColor* color = [status isEqualToString:@"completed"] ? NSColor.secondaryLabelColor : NSColor.labelColor;
		[res appendAttributedString:[self text:[NSString stringWithFormat:@"\n%@ %@", PlanStatusGlyph(status), entry[@"content"] ?: @""] font:SmallFont() color:color]];
	}
}

// ===========
// = Actions =
// ===========

// The tool call shown by a tool call or permission item. A permission request
// may only name its tool call; fill in what the tool call’s row knows.
- (NSDictionary*)toolCallForItem:(AgentTranscriptItem*)item
{
	if(item.kind != AgentTranscriptItemKindPermission)
		return item.toolCall ?: @{ };

	NSDictionary* toolCall = [item.permissionRequest[@"toolCall"] isKindOfClass:[NSDictionary class]] ? item.permissionRequest[@"toolCall"] : @{ };
	if(AgentTranscriptItem* toolCallItem = [self toolCallItemWithIdentifier:toolCall[@"toolCallId"]])
	{
		NSMutableDictionary* merged = [toolCallItem.toolCall mutableCopy];
		[merged addEntriesFromDictionary:toolCall];
		toolCall = merged;
	}
	return toolCall;
}

// The agent may announce its next tool calls before it asks about one; the
// chat stops at the first open question, in its tool call’s row or its own card
- (AgentTranscriptItem*)lastShownItem
{
	for(AgentTranscriptItem* item in _transcript.items)
	{
		if(item.kind != AgentTranscriptItemKindPermission || item.permissionResolved)
			continue;
		NSDictionary* toolCall = item.permissionRequest[@"toolCall"];
		AgentTranscriptItem* toolCallItem = [toolCall isKindOfClass:[NSDictionary class]] ? [self toolCallItemWithIdentifier:toolCall[@"toolCallId"]] : nil;
		return toolCallItem ?: item;
	}
	return nil;
}

// The latest permission request about a tool call
- (AgentTranscriptItem*)permissionItemForToolCallId:(id)toolCallId
{
	if(!toolCallId)
		return nil;
	for(AgentTranscriptItem* item in _transcript.items.reverseObjectEnumerator)
	{
		if(item.kind != AgentTranscriptItemKindPermission)
			continue;
		NSDictionary* toolCall = item.permissionRequest[@"toolCall"];
		if([toolCall isKindOfClass:[NSDictionary class]] && [toolCall[@"toolCallId"] isEqual:toolCallId])
			return item;
	}
	return nil;
}

- (AgentTranscriptItem*)toolCallItemWithIdentifier:(id)toolCallId
{
	if(!toolCallId)
		return nil;
	for(AgentTranscriptItem* item in _transcript.items.reverseObjectEnumerator)
	{
		if(item.kind == AgentTranscriptItemKindToolCall && [item.toolCall[@"toolCallId"] isEqual:toolCallId])
			return item;
	}
	return nil;
}

- (AgentTranscriptItem*)itemWithIdentifier:(NSString*)identifier
{
	for(AgentTranscriptItem* item in _transcript.items)
	{
		if([item.identifier isEqualToString:identifier])
			return item;
	}
	return nil;
}

- (BOOL)textView:(NSTextView*)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex
{
	NSURL* url = [link isKindOfClass:[NSURL class]] ? link : [NSURL URLWithString:[link description]];
	if(![url.scheme isEqualToString:kActionScheme])
		return NO; // regular links open in the browser

	NSMutableDictionary<NSString*, NSString*>* parameters = [NSMutableDictionary dictionary];
	for(NSURLQueryItem* queryItem in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems)
		parameters[queryItem.name] = queryItem.value;

	AgentTranscriptItem* item = [self itemWithIdentifier:parameters[@"item"]];
	NSString* action = url.host;

	if([action isEqualToString:@"copy"] || [action isEqualToString:@"insert"] || [action isEqualToString:@"apply"])
	{
		NSArray<OakMarkdownCodeBlock*>* codeBlocks = _codeBlocks[parameters[@"item"]];
		NSUInteger index = parameters[@"block"].integerValue;
		if(index >= codeBlocks.count)
			return YES;

		NSString* code = codeBlocks[index].code;
		if([action isEqualToString:@"copy"])
		{
			[NSPasteboard.generalPasteboard clearContents];
			[NSPasteboard.generalPasteboard setString:code forType:NSPasteboardTypeString];
		}
		else if([action isEqualToString:@"apply"])
		{
			if([_actionDelegate respondsToSelector:@selector(transcriptView:applyCode:)])
				[_actionDelegate transcriptView:self applyCode:code];
		}
		else if([_actionDelegate respondsToSelector:@selector(transcriptView:insertCode:)])
		{
			[_actionDelegate transcriptView:self insertCode:code];
		}
	}
	else if([action isEqualToString:@"toggle"] && item)
	{
		item.expanded = !item.expanded;
		[_pendingIdentifiers addObject:item.identifier];
		_clickedIdentifier = item.identifier;
		[self flushPendingItems];
	}
	else if([action isEqualToString:@"fold"] && item)
	{
		item.folded = !item.folded;
		item.foldsWhenPassed = NO; // the user’s to fold now
		[_pendingIdentifiers addObject:item.identifier];
		_clickedIdentifier = item.identifier;
		[self flushPendingItems];
	}
	else if([action isEqualToString:@"code"] && item && parameters[@"block"])
	{
		NSString* key = [NSString stringWithFormat:@"%@:%@", item.identifier, parameters[@"block"]];
		if([_toggledCodeBlocks containsObject:key])
				[_toggledCodeBlocks removeObject:key];
		else	[_toggledCodeBlocks addObject:key];
		[_pendingIdentifiers addObject:item.identifier];
		_clickedIdentifier = item.identifier;
		[self flushPendingItems];
	}
	else if([action isEqualToString:@"diff"] && item)
	{
		NSArray* contents = [[self toolCallForItem:item][@"content"] isKindOfClass:[NSArray class]] ? [self toolCallForItem:item][@"content"] : @[ ];
		NSUInteger index  = parameters[@"content"].integerValue;
		NSDictionary* content = index < contents.count ? contents[index] : nil;
		if([content[@"type"] isEqualToString:@"diff"] && [_actionDelegate respondsToSelector:@selector(transcriptView:showDiffOfFile:oldText:newText:)])
		{
			NSString* oldText = [content[@"oldText"] isKindOfClass:[NSString class]] ? content[@"oldText"] : nil;
			NSString* newText = [content[@"newText"] isKindOfClass:[NSString class]] ? content[@"newText"] : @"";
			[_actionDelegate transcriptView:self showDiffOfFile:content[@"path"] oldText:oldText newText:newText];
		}
	}
	else if([action isEqualToString:@"item-action"] && item && parameters[@"action"])
	{
		if([_actionDelegate respondsToSelector:@selector(transcriptView:performAction:forItem:)])
			[_actionDelegate transcriptView:self performAction:parameters[@"action"] forItem:item];
	}
	else if([action isEqualToString:@"kill"] && parameters[@"terminal"])
	{
		if(AgentTerminal* terminal = [_terminalManager terminalWithIdentifier:parameters[@"terminal"]])
			[_terminalManager killTerminal:terminal];
	}
	else if([action isEqualToString:@"permission"] && item && !item.permissionResolved)
	{
		if([_actionDelegate respondsToSelector:@selector(transcriptView:selectPermissionOption:forItem:)])
			[_actionDelegate transcriptView:self selectPermissionOption:parameters[@"option"] forItem:item];
	}
	else if([action isEqualToString:@"open"] && parameters[@"path"] && ![self fileExistsAtPath:PathFromURI(parameters[@"path"])])
	{
		// Deleted, or not written yet (the transcript hasn’t caught up): show what the agent wants to write rather than open an empty document
		NSDictionary* toolCall = item ? [self toolCallForItem:item] : nil;
		NSUInteger diffIndex = toolCall ? IndexOfDiffForPath(toolCall, parameters[@"path"]) : NSNotFound;
		NSDictionary* content = diffIndex != NSNotFound ? toolCall[@"content"][diffIndex] : nil;
		if(content && [_actionDelegate respondsToSelector:@selector(transcriptView:showDiffOfFile:oldText:newText:)])
				[_actionDelegate transcriptView:self showDiffOfFile:content[@"path"] oldText:([content[@"oldText"] isKindOfClass:[NSString class]] ? content[@"oldText"] : nil) newText:([content[@"newText"] isKindOfClass:[NSString class]] ? content[@"newText"] : @"")];
		else	NSBeep();
	}
	else if([action isEqualToString:@"open"] && parameters[@"path"])
	{
		if([_actionDelegate respondsToSelector:@selector(transcriptView:openFile:line:)])
			[_actionDelegate transcriptView:self openFile:PathFromURI(parameters[@"path"]) line:parameters[@"line"].integerValue];
	}
	return YES;
}
@end
