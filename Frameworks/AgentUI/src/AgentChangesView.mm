#import "AgentChangesView.h"
#import <AgentClient/AgentDiff.h>

static CGFloat const kMaximumListHeight = 132;

static NSFont* SmallFont () { return [NSFont systemFontOfSize:NSFont.smallSystemFontSize]; }

static NSButton* LinkButton (NSString* title, NSString* toolTip, id target, SEL action)
{
	NSButton* button = [NSButton buttonWithTitle:title target:target action:action];
	button.bordered    = NO;
	button.controlSize = NSControlSizeSmall;
	button.font        = SmallFont();
	button.toolTip     = toolTip;
	button.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{ NSFontAttributeName: SmallFont(), NSForegroundColorAttributeName: NSColor.linkColor }];
	[button setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
	return button;
}

static NSTextField* Label (NSAttributedString* text)
{
	NSTextField* label = [NSTextField labelWithAttributedString:text];
	label.lineBreakMode = NSLineBreakByTruncatingMiddle;
	[label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	return label;
}

// Flipped, so the list starts at the top of its scroll view
@interface AgentChangesListView : NSStackView
@end

@implementation AgentChangesListView
- (BOOL)isFlipped { return YES; }
@end

@implementation AgentChangesView
{
	NSTextField* _summaryField;
	NSStackView* _listView;
	NSScrollView* _scrollView;
	NSLayoutConstraint* _heightConstraint;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if(self = [super initWithFrame:frame])
	{
		_summaryField = Label([[NSAttributedString alloc] initWithString:@""]);

		NSStackView* header = [NSStackView stackViewWithViews:@[
			_summaryField, [NSView new],
			LinkButton(@"Keep All", @"Keep all changes", self, @selector(keepAll:)),
			LinkButton(@"Undo All", @"Undo all changes", self, @selector(undoAll:)),
		]];
		header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
		header.spacing     = 8;

		_listView = [[AgentChangesListView alloc] initWithFrame:NSZeroRect];
		_listView.orientation = NSUserInterfaceLayoutOrientationVertical;
		_listView.alignment   = NSLayoutAttributeLeading;
		_listView.spacing     = 0;
		_listView.translatesAutoresizingMaskIntoConstraints = NO;

		_scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
		_scrollView.hasVerticalScroller = YES;
		_scrollView.autohidesScrollers  = YES;
		_scrollView.drawsBackground     = NO;
		_scrollView.borderType          = NSNoBorder;
		_scrollView.documentView        = _listView;
		[_listView.leadingAnchor constraintEqualToAnchor:_scrollView.contentView.leadingAnchor].active = YES;
		[_listView.trailingAnchor constraintEqualToAnchor:_scrollView.contentView.trailingAnchor].active = YES;
		[_listView.topAnchor constraintEqualToAnchor:_scrollView.contentView.topAnchor].active = YES;
		_heightConstraint = [_scrollView.heightAnchor constraintEqualToConstant:0];
		_heightConstraint.active = YES;

		NSStackView* stack = [NSStackView stackViewWithViews:@[ header, _scrollView ]];
		stack.orientation = NSUserInterfaceLayoutOrientationVertical;
		stack.alignment   = NSLayoutAttributeLeading;
		stack.spacing     = 2;
		stack.edgeInsets  = NSEdgeInsetsMake(6, 8, 6, 8);
		stack.translatesAutoresizingMaskIntoConstraints = NO;
		for(NSView* view in stack.arrangedSubviews)
			[view.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-16].active = YES;

		[self addSubview:stack];
		[NSLayoutConstraint activateConstraints:@[
			[stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
			[stack.topAnchor constraintEqualToAnchor:self.topAnchor],
			[stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
		]];
		self.hidden = YES;
	}
	return self;
}

- (NSString*)displayNameForPath:(NSString*)path
{
	if(_rootDirectory && [path hasPrefix:[_rootDirectory stringByAppendingString:@"/"]])
		return [path substringFromIndex:_rootDirectory.length + 1];
	return path.stringByAbbreviatingWithTildeInPath;
}

- (NSView*)rowForChange:(AgentFileChange*)change index:(NSUInteger)index
{
	AgentDiff* diff = [AgentDiff diffWithOldText:change.originalText newText:change.currentText contextLines:0];

	NSMutableAttributedString* title = [[NSMutableAttributedString alloc] init];
	NSString* name = [self displayNameForPath:change.path];
	[title appendAttributedString:[[NSAttributedString alloc] initWithString:name attributes:@{ NSFontAttributeName: SmallFont(), NSForegroundColorAttributeName: NSColor.labelColor }]];
	if(!change.originalText)
		[title appendAttributedString:[[NSAttributedString alloc] initWithString:@"  new" attributes:@{ NSFontAttributeName: SmallFont(), NSForegroundColorAttributeName: NSColor.secondaryLabelColor }]];
	[title appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  +%lu", diff.addedLineCount] attributes:@{ NSFontAttributeName: SmallFont(), NSForegroundColorAttributeName: NSColor.systemGreenColor }]];
	[title appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" −%lu", diff.removedLineCount] attributes:@{ NSFontAttributeName: SmallFont(), NSForegroundColorAttributeName: NSColor.systemRedColor }]];

	NSButton* open = [NSButton buttonWithTitle:@"" target:self action:@selector(openChange:)];
	open.bordered        = NO;
	open.attributedTitle = title;
	open.alignment       = NSTextAlignmentLeft;
	open.toolTip         = [NSString stringWithFormat:@"Open %@", change.path];
	open.tag             = index;
	[open setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
	open.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;

	NSButton* showDiff = LinkButton(@"Diff", @"Show the changes as a diff", self, @selector(showDiff:));
	NSButton* keep     = LinkButton(@"Keep", @"Keep the agent’s changes to this file", self, @selector(keep:));
	NSButton* undo     = LinkButton(@"Undo", @"Restore this file as it was before the agent changed it", self, @selector(undo:));
	showDiff.tag = keep.tag = undo.tag = index;

	NSStackView* row = [NSStackView stackViewWithViews:@[ open, [NSView new], showDiff, keep, undo ]];
	row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	row.spacing     = 8;
	return row;
}

- (void)setChanges:(NSArray<AgentFileChange*>*)changes
{
	_changes = [changes copy];

	for(NSView* view in _listView.arrangedSubviews)
		[view removeFromSuperview];
	[_changes enumerateObjectsUsingBlock:^(AgentFileChange* change, NSUInteger index, BOOL*){
		NSView* row = [self rowForChange:change index:index];
		[_listView addArrangedSubview:row];
		[row.widthAnchor constraintEqualToAnchor:_listView.widthAnchor].active = YES;
	}];

	NSString* summary = _changes.count == 1 ? @"1 file changed" : [NSString stringWithFormat:@"%lu files changed", _changes.count];
	_summaryField.attributedStringValue = [[NSAttributedString alloc] initWithString:summary attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.labelColor }];

	[_listView layoutSubtreeIfNeeded];
	_heightConstraint.constant = MIN(_listView.fittingSize.height, kMaximumListHeight);
	self.hidden = _changes.count == 0;
}

- (AgentFileChange*)changeForSender:(NSButton*)sender
{
	return sender.tag < _changes.count ? _changes[sender.tag] : nil;
}

- (void)openChange:(NSButton*)sender
{
	if(AgentFileChange* change = [self changeForSender:sender])
		[_delegate changesView:self openChange:change];
}

- (void)showDiff:(NSButton*)sender
{
	if(AgentFileChange* change = [self changeForSender:sender])
		[_delegate changesView:self showDiffOfChange:change];
}

- (void)keep:(NSButton*)sender
{
	if(AgentFileChange* change = [self changeForSender:sender])
		[_delegate changesView:self keepChanges:@[ change ]];
}

- (void)undo:(NSButton*)sender
{
	if(AgentFileChange* change = [self changeForSender:sender])
		[_delegate changesView:self undoChanges:@[ change ]];
}

- (void)keepAll:(id)sender { [_delegate changesView:self keepChanges:_changes]; }
- (void)undoAll:(id)sender { [_delegate changesView:self undoChanges:_changes]; }
@end
