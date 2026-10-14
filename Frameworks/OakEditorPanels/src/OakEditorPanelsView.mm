#import "OakEditorPanelsView.h"

static CGFloat const kDividerHitSlop = 4;

static BOOL IsHorizontal (OakEditorPanelEdge edge)
{
	return edge == OakEditorPanelEdgeLeft || edge == OakEditorPanelEdgeRight;
}

// A plain line with no intrinsic size. An NSBox separator created with a zero
// frame thinks it’s horizontal and hugs a small height, which (pinned to our
// top and bottom) shrinks the whole window.
@interface OakEditorPanelDivider : NSView
@end

@implementation OakEditorPanelDivider
- (BOOL)isOpaque { return NO; }

- (void)drawRect:(NSRect)rect
{
	[NSColor.separatorColor setFill];
	NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
}
@end

@interface OakEditorPanelsView ()
- (void)panelLayoutDidChange:(OakEditorPanel*)panel;
@end

@interface OakEditorPanel ()
@property (nonatomic, weak) OakEditorPanelsView* container;
@property (nonatomic, readonly) OakEditorPanelDivider* divider;
@property (nonatomic) NSLayoutConstraint* sizeConstraint;
@property (nonatomic) CGFloat size;                  // width or height, depending on the edge
@property (nonatomic, readonly) CGFloat minimumSize;
@property (nonatomic, readonly) NSRect dividerResizeRect;
- (void)saveSize;
@end

@implementation OakEditorPanel
- (instancetype)initWithView:(NSView*)view edge:(OakEditorPanelEdge)edge
{
	if(self = [super init])
	{
		_view          = view;
		_edge          = edge;
		_width         = 380;
		_height        = 250;
		_minimumWidth  = 200;
		_minimumHeight = 100;
		_divider       = [[OakEditorPanelDivider alloc] initWithFrame:NSZeroRect];
	}
	return self;
}

- (CGFloat)size
{
	return IsHorizontal(_edge) ? MAX(_width, _minimumWidth) : MAX(_height, _minimumHeight);
}

- (void)setSize:(CGFloat)size
{
	if(IsHorizontal(_edge))
		_width = size;
	else	_height = size;
	_sizeConstraint.constant = self.size;
}

- (CGFloat)minimumSize
{
	return IsHorizontal(_edge) ? _minimumWidth : _minimumHeight;
}

- (void)setEdge:(OakEditorPanelEdge)edge
{
	if(_edge == edge)
		return;
	_edge = edge;
	[_container panelLayoutDidChange:self];
}

- (void)setWidth:(CGFloat)width
{
	_width = width;
	if(IsHorizontal(_edge))
		_sizeConstraint.constant = self.size;
}

- (void)setHeight:(CGFloat)height
{
	_height = height;
	if(!IsHorizontal(_edge))
		_sizeConstraint.constant = self.size;
}

- (void)setAutosaveName:(NSString*)name
{
	_autosaveName = [name copy];
	if(!_autosaveName)
		return;

	NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
	if(CGFloat width = [defaults doubleForKey:[_autosaveName stringByAppendingString:@"Width"]])
		self.width = width;
	if(CGFloat height = [defaults doubleForKey:[_autosaveName stringByAppendingString:@"Height"]])
		self.height = height;
}

- (void)saveSize
{
	if(!_autosaveName)
		return;
	NSString* key = [_autosaveName stringByAppendingString:(IsHorizontal(_edge) ? @"Width" : @"Height")];
	[NSUserDefaults.standardUserDefaults setDouble:(IsHorizontal(_edge) ? _width : _height) forKey:key];
}

// The area where the divider can be dragged, in the container’s coordinates
- (NSRect)dividerResizeRect
{
	NSRect r = _divider.frame;
	if(IsHorizontal(_edge))
		return NSMakeRect(NSMidX(r) - kDividerHitSlop, NSMinY(r), 2*kDividerHitSlop, NSHeight(r));
	return NSMakeRect(NSMinX(r), NSMidY(r) - kDividerHitSlop, NSWidth(r), 2*kDividerHitSlop);
}
@end

@interface OakEditorPanelsView ()
{
	NSMutableArray<OakEditorPanel*>* _panels;
	NSMutableArray<NSLayoutConstraint*>* _layoutConstraints;
}
@end

@implementation OakEditorPanelsView
- (instancetype)initWithEditorView:(NSView*)editorView
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		_editorView        = editorView;
		_panels            = [NSMutableArray array];
		_layoutConstraints = [NSMutableArray array];
	}
	return self;
}

- (NSArray<OakEditorPanel*>*)panels
{
	return [_panels copy];
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

- (void)addPanel:(OakEditorPanel*)panel
{
	if([_panels containsObject:panel])
		return;

	[_panels addObject:panel];
	panel.container = self;
	panel.view.translatesAutoresizingMaskIntoConstraints    = NO;
	panel.divider.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:panel.divider];
	[self addSubview:panel.view];
	[self panelLayoutDidChange:panel];
}

- (void)removePanel:(OakEditorPanel*)panel
{
	if(![_panels containsObject:panel])
		return;

	[_panels removeObject:panel];
	panel.container      = nil;
	panel.sizeConstraint = nil;
	[panel.view removeFromSuperview];
	[panel.divider removeFromSuperview];
	[self panelLayoutDidChange:panel];
}

- (void)panelLayoutDidChange:(OakEditorPanel*)panel
{
	self.needsUpdateConstraints = YES;
	[self.window invalidateCursorRectsForView:self];
}

- (NSArray<OakEditorPanel*>*)panelsOnEdge:(OakEditorPanelEdge)edge
{
	return [_panels filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(OakEditorPanel* panel, NSDictionary*){
		return panel.edge == edge;
	}]];
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

	// Left and right panels, outermost first, spanning the full height
	NSLayoutXAxisAnchor* columnLeading  = self.leadingAnchor;
	NSLayoutXAxisAnchor* columnTrailing = self.trailingAnchor;

	for(OakEditorPanel* panel in [self panelsOnEdge:OakEditorPanelEdgeLeft])
	{
		[_layoutConstraints addObjectsFromArray:@[
			[panel.view.leadingAnchor constraintEqualToAnchor:columnLeading],
			[panel.view.trailingAnchor constraintEqualToAnchor:panel.divider.leadingAnchor],
		]];
		columnLeading = panel.divider.trailingAnchor;
	}

	for(OakEditorPanel* panel in [self panelsOnEdge:OakEditorPanelEdgeRight])
	{
		[_layoutConstraints addObjectsFromArray:@[
			[panel.view.trailingAnchor constraintEqualToAnchor:columnTrailing],
			[panel.view.leadingAnchor constraintEqualToAnchor:panel.divider.trailingAnchor],
		]];
		columnTrailing = panel.divider.leadingAnchor;
	}

	// Top and bottom panels, outermost first, spanning the editor column
	NSLayoutYAxisAnchor* editorTop    = self.topAnchor;
	NSLayoutYAxisAnchor* editorBottom = self.bottomAnchor;

	for(OakEditorPanel* panel in [self panelsOnEdge:OakEditorPanelEdgeTop])
	{
		[_layoutConstraints addObjectsFromArray:@[
			[panel.view.topAnchor constraintEqualToAnchor:editorTop],
			[panel.view.bottomAnchor constraintEqualToAnchor:panel.divider.topAnchor],
		]];
		editorTop = panel.divider.bottomAnchor;
	}

	for(OakEditorPanel* panel in [self panelsOnEdge:OakEditorPanelEdgeBottom])
	{
		[_layoutConstraints addObjectsFromArray:@[
			[panel.view.bottomAnchor constraintEqualToAnchor:editorBottom],
			[panel.view.topAnchor constraintEqualToAnchor:panel.divider.bottomAnchor],
		]];
		editorBottom = panel.divider.topAnchor;
	}

	[_layoutConstraints addObjectsFromArray:@[
		[editor.leadingAnchor constraintEqualToAnchor:columnLeading],
		[editor.trailingAnchor constraintEqualToAnchor:columnTrailing],
		[editor.topAnchor constraintEqualToAnchor:editorTop],
		[editor.bottomAnchor constraintEqualToAnchor:editorBottom],
	]];

	for(OakEditorPanel* panel in _panels)
	{
		NSView* view    = panel.view;
		NSView* divider = panel.divider;
		if(IsHorizontal(panel.edge))
		{
			[_layoutConstraints addObjectsFromArray:@[
				[divider.widthAnchor constraintEqualToConstant:1],
				[divider.topAnchor constraintEqualToAnchor:self.topAnchor],
				[divider.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
				[view.topAnchor constraintEqualToAnchor:self.topAnchor],
				[view.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
			]];
			panel.sizeConstraint = [view.widthAnchor constraintEqualToConstant:panel.size];
		}
		else
		{
			[_layoutConstraints addObjectsFromArray:@[
				[divider.heightAnchor constraintEqualToConstant:1],
				[divider.leadingAnchor constraintEqualToAnchor:columnLeading],
				[divider.trailingAnchor constraintEqualToAnchor:columnTrailing],
				[view.leadingAnchor constraintEqualToAnchor:columnLeading],
				[view.trailingAnchor constraintEqualToAnchor:columnTrailing],
			]];
			panel.sizeConstraint = [view.heightAnchor constraintEqualToConstant:panel.size];
		}

		// Preferred, not required: the editor’s own minimum size always wins,
		// and the window isn’t forced to grow to fit the panel
		panel.sizeConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
		NSLayoutDimension* dimension = IsHorizontal(panel.edge) ? view.widthAnchor : view.heightAnchor;
		NSLayoutConstraint* minSize = [dimension constraintGreaterThanOrEqualToConstant:panel.minimumSize];
		minSize.priority = NSLayoutPriorityDragThatCannotResizeWindow - 1;
		[_layoutConstraints addObjectsFromArray:@[ panel.sizeConstraint, minSize ]];
	}

	[NSLayoutConstraint activateConstraints:_layoutConstraints];
	[super updateConstraints];
}

// ======================
// = Resizing a Panel =
// ======================

- (OakEditorPanel*)panelWithDividerAtPoint:(NSPoint)aPoint
{
	for(OakEditorPanel* panel in _panels.reverseObjectEnumerator)
	{
		if(NSMouseInRect(aPoint, panel.dividerResizeRect, self.isFlipped))
			return panel;
	}
	return nil;
}

- (void)resetCursorRects
{
	for(OakEditorPanel* panel in _panels)
		[self addCursorRect:panel.dividerResizeRect cursor:(IsHorizontal(panel.edge) ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor)];
}

- (NSView*)hitTest:(NSPoint)aPoint
{
	if([self panelWithDividerAtPoint:[self convertPoint:aPoint fromView:self.superview]])
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
	OakEditorPanel* panel = [self panelWithDividerAtPoint:start];
	if(!panel)
		return [super mouseDown:anEvent];

	BOOL horizontal = IsHorizontal(panel.edge);
	CGFloat initialSize = horizontal ? NSWidth(panel.view.frame) : NSHeight(panel.view.frame);
	while(true)
	{
		NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp untilDate:NSDate.distantFuture inMode:NSEventTrackingRunLoopMode dequeue:YES];
		if(event.type == NSEventTypeLeftMouseUp)
			break;

		NSPoint current = [self convertPoint:event.locationInWindow fromView:nil];
		CGFloat right   = current.x - start.x;
		CGFloat down    = (current.y - start.y) * (self.isFlipped ? +1 : -1);

		CGFloat delta = 0;
		switch(panel.edge)
		{
			case OakEditorPanelEdgeLeft:   delta = +right; break;
			case OakEditorPanelEdgeRight:  delta = -right; break;
			case OakEditorPanelEdgeTop:    delta = +down;  break;
			case OakEditorPanelEdgeBottom: delta = -down;  break;
		}

		[panel setSize:MAX(panel.minimumSize, round(initialSize + delta))];
		[self.window invalidateCursorRectsForView:self];
	}

	// The editor’s minimum size may have limited the drag; remember what we got
	[self layoutSubtreeIfNeeded];
	[panel setSize:MAX(panel.minimumSize, round(horizontal ? NSWidth(panel.view.frame) : NSHeight(panel.view.frame)))];
	[panel saveSize];
}
@end
