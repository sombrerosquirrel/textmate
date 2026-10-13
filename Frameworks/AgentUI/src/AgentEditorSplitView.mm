#import "AgentEditorSplitView.h"

NSString* const kUserDefaultsAgentPanelPlacementKey = @"agentPanelPlacement";
NSString* const kUserDefaultsAgentPanelWidthKey     = @"agentPanelWidth";

static CGFloat const kMinPanelWidth = 200;

// A plain line with no intrinsic size. An NSBox separator created with a zero
// frame thinks it’s horizontal and hugs a small height, which (pinned to our
// top and bottom) shrinks the whole window.
@interface AgentDividerView : NSView
@end

@implementation AgentDividerView
- (BOOL)isOpaque { return NO; }

- (void)drawRect:(NSRect)rect
{
	[NSColor.separatorColor setFill];
	NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
}
@end

@interface AgentEditorSplitView ()
{
	NSView* _divider;
	NSLayoutConstraint* _panelWidthConstraint;
	NSMutableArray<NSLayoutConstraint*>* _layoutConstraints;
	CGFloat _panelWidth;
}
@end

@implementation AgentEditorSplitView
+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		kUserDefaultsAgentPanelPlacementKey: @"right",
		kUserDefaultsAgentPanelWidthKey:     @380,
	}];
}

- (instancetype)initWithEditorView:(NSView*)editorView
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		_editorView        = editorView;
		_panelOnRight      = ![[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsAgentPanelPlacementKey] isEqualToString:@"left"];
		_panelWidth        = MAX([NSUserDefaults.standardUserDefaults doubleForKey:kUserDefaultsAgentPanelWidthKey], kMinPanelWidth);
		_layoutConstraints = [NSMutableArray array];

		_divider = [[AgentDividerView alloc] initWithFrame:NSZeroRect];
	}
	return self;
}

// The editor is adopted once we’re in the window. Taking it earlier doesn’t
// work: ProjectLayoutView, when we replace the editor as its document view,
// removes the old view (the editor) from whatever superview it has by then.
- (void)viewDidMoveToSuperview
{
	[super viewDidMoveToSuperview];
	[self adoptEditorView];
}

- (void)adoptEditorView
{
	if(!self.superview || _editorView.superview == self)
		return;

	[_editorView removeFromSuperview];
	_editorView.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:_editorView positioned:NSWindowBelow relativeTo:nil];
	self.needsUpdateConstraints = YES;
}

- (void)setPanelView:(NSView*)panelView
{
	if(_panelView == panelView)
		return;

	[_panelView removeFromSuperview];
	[_divider removeFromSuperview];

	_panelView = panelView;
	if(_panelView)
	{
		_panelView.translatesAutoresizingMaskIntoConstraints = NO;
		_divider.translatesAutoresizingMaskIntoConstraints   = NO;
		[self addSubview:_divider];
		[self addSubview:_panelView];
	}

	self.needsUpdateConstraints = YES;
	[self.window invalidateCursorRectsForView:self];
}

- (void)setPanelOnRight:(BOOL)flag
{
	if(_panelOnRight == flag)
		return;
	_panelOnRight = flag;
	self.needsUpdateConstraints = YES;
	[self.window invalidateCursorRectsForView:self];
}

- (void)updateConstraints
{
	[NSLayoutConstraint deactivateConstraints:_layoutConstraints];
	[_layoutConstraints removeAllObjects];

	NSView* editor = _editorView;
	if(editor.superview != self)
	{
		[super updateConstraints];
		return;
	}
	[_layoutConstraints addObjectsFromArray:@[
		[editor.topAnchor constraintEqualToAnchor:self.topAnchor],
		[editor.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
	]];

	if(!_panelView)
	{
		[_layoutConstraints addObjectsFromArray:@[
			[editor.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[editor.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		]];
	}
	else
	{
		NSView* panel = _panelView;
		NSView* left  = _panelOnRight ? editor : panel;
		NSView* right = _panelOnRight ? panel : editor;

		[_layoutConstraints addObjectsFromArray:@[
			[left.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[left.trailingAnchor constraintEqualToAnchor:_divider.leadingAnchor],
			[_divider.trailingAnchor constraintEqualToAnchor:right.leadingAnchor],
			[right.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
			[_divider.widthAnchor constraintEqualToConstant:1],
			[_divider.topAnchor constraintEqualToAnchor:self.topAnchor],
			[_divider.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
			[panel.topAnchor constraintEqualToAnchor:self.topAnchor],
			[panel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
		]];

		// Preferred, not required: the editor’s own minimum width always wins,
		// and the window isn’t forced to grow to fit the panel
		_panelWidthConstraint = [panel.widthAnchor constraintEqualToConstant:_panelWidth];
		_panelWidthConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		NSLayoutConstraint* minWidth = [panel.widthAnchor constraintGreaterThanOrEqualToConstant:kMinPanelWidth];
		minWidth.priority = NSLayoutPriorityDragThatCannotResizeWindow - 1;
		[_layoutConstraints addObjectsFromArray:@[ _panelWidthConstraint, minWidth ]];
	}

	[NSLayoutConstraint activateConstraints:_layoutConstraints];
	[super updateConstraints];
}

// =======================
// = Resizing the Panel =
// =======================

- (NSRect)dividerResizeRect
{
	if(!_panelView)
		return NSZeroRect;
	NSRect r = _divider.frame;
	return NSMakeRect(NSMidX(r) - 4, NSMinY(r), 8, NSHeight(r));
}

- (void)resetCursorRects
{
	[self addCursorRect:[self dividerResizeRect] cursor:NSCursor.resizeLeftRightCursor];
}

- (NSView*)hitTest:(NSPoint)aPoint
{
	if(NSMouseInRect([self convertPoint:aPoint fromView:self.superview], [self dividerResizeRect], self.isFlipped))
		return self;
	return [super hitTest:aPoint];
}

- (BOOL)mouseDownCanMoveWindow
{
	return NO;
}

- (void)mouseDown:(NSEvent*)anEvent
{
	NSPoint start = [self convertPoint:anEvent.locationInWindow fromView:nil];
	if(!_panelView || !NSMouseInRect(start, [self dividerResizeRect], self.isFlipped))
		return [super mouseDown:anEvent];

	CGFloat initialWidth = NSWidth(_panelView.frame);
	while(true)
	{
		NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp untilDate:NSDate.distantFuture inMode:NSEventTrackingRunLoopMode dequeue:YES];
		if(event.type == NSEventTypeLeftMouseUp)
			break;

		NSPoint current = [self convertPoint:event.locationInWindow fromView:nil];
		CGFloat delta   = (current.x - start.x) * (_panelOnRight ? -1 : +1);
		_panelWidth     = MAX(kMinPanelWidth, round(initialWidth + delta));
		_panelWidthConstraint.constant = _panelWidth;
		[self.window invalidateCursorRectsForView:self];
	}

	// The editor’s minimum width may have limited the drag; remember what we got
	[self layoutSubtreeIfNeeded];
	_panelWidth = MAX(kMinPanelWidth, round(NSWidth(_panelView.frame)));
	_panelWidthConstraint.constant = _panelWidth;
	[NSUserDefaults.standardUserDefaults setDouble:_panelWidth forKey:kUserDefaultsAgentPanelWidthKey];
}
@end
