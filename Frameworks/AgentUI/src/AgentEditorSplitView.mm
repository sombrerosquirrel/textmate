#import "AgentEditorSplitView.h"

NSString* const kUserDefaultsAgentPanelPlacementKey = @"agentPanelPlacement";
NSString* const kUserDefaultsAgentPanelWidthKey     = @"agentPanelWidth";

static CGFloat const kMinPanelWidth  = 260;
static CGFloat const kMinEditorWidth = 200;

@interface AgentEditorSplitView () <NSSplitViewDelegate>
{
	BOOL _restoringPanelWidth;
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
		_editorView   = editorView;
		_panelOnRight = ![[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsAgentPanelPlacementKey] isEqualToString:@"left"];

		self.vertical     = YES;
		self.dividerStyle = NSSplitViewDividerStyleThin;
		self.delegate     = self;
		[self arrangeSubviews];
	}
	return self;
}

- (CGFloat)panelWidth
{
	return MAX([NSUserDefaults.standardUserDefaults doubleForKey:kUserDefaultsAgentPanelWidthKey], kMinPanelWidth);
}

- (void)arrangeSubviews
{
	for(NSView* view in self.arrangedSubviews.copy)
	{
		[self removeArrangedSubview:view];
		[view removeFromSuperview];
	}

	NSArray* views = !_panelView ? @[ _editorView ] : (_panelOnRight ? @[ _editorView, _panelView ] : @[ _panelView, _editorView ]);
	for(NSView* view in views)
		[self addArrangedSubview:view];

	// When the window resizes, the editor takes up the change and the panel keeps its width
	[self setHoldingPriority:NSLayoutPriorityDefaultLow forSubviewAtIndex:[views indexOfObject:_editorView]];
	if(_panelView)
	{
		[self setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:[views indexOfObject:_panelView]];
		[self restorePanelWidthWithRetries:10];
	}
}

- (void)restorePanelWidthWithRetries:(NSUInteger)retries
{
	if(!_panelView || self.arrangedSubviews.count != 2)
		return;

	[self layoutSubtreeIfNeeded];
	CGFloat total = NSWidth(self.bounds);
	if(total <= 0)
	{
		// Not laid out yet; try again once we have a size
		if(retries)
			dispatch_async(dispatch_get_main_queue(), ^{ [self restorePanelWidthWithRetries:retries - 1]; });
		return;
	}

	CGFloat width = MIN(self.panelWidth, total - kMinEditorWidth - self.dividerThickness);
	_restoringPanelWidth = YES;
	[self setPosition:(_panelOnRight ? total - width - self.dividerThickness : width) ofDividerAtIndex:0];
	_restoringPanelWidth = NO;
}

- (void)setPanelView:(NSView*)panelView
{
	if(_panelView == panelView)
		return;
	_panelView = panelView;
	[self arrangeSubviews];
}

- (void)setPanelOnRight:(BOOL)flag
{
	if(_panelOnRight == flag)
		return;
	_panelOnRight = flag;
	[self arrangeSubviews];
}

// ========================
// = NSSplitViewDelegate =
// ========================

- (CGFloat)splitView:(NSSplitView*)splitView constrainMinCoordinate:(CGFloat)proposedMinimum ofSubviewAt:(NSInteger)dividerIndex
{
	return MAX(proposedMinimum, _panelOnRight ? kMinEditorWidth : kMinPanelWidth);
}

- (CGFloat)splitView:(NSSplitView*)splitView constrainMaxCoordinate:(CGFloat)proposedMaximum ofSubviewAt:(NSInteger)dividerIndex
{
	return MIN(proposedMaximum, NSWidth(splitView.bounds) - (_panelOnRight ? kMinPanelWidth : kMinEditorWidth) - splitView.dividerThickness);
}

- (BOOL)splitView:(NSSplitView*)splitView canCollapseSubview:(NSView*)subview
{
	return NO;
}

- (void)splitViewDidResizeSubviews:(NSNotification*)notification
{
	// Only remember widths the user chose by dragging the divider
	if(_restoringPanelWidth || !_panelView || !notification.userInfo[@"NSSplitViewDividerIndex"])
		return;
	[NSUserDefaults.standardUserDefaults setDouble:round(NSWidth(_panelView.frame)) forKey:kUserDefaultsAgentPanelWidthKey];
}
@end
