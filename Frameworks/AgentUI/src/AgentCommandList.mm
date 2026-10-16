#import "AgentCommandList.h"

static CGFloat const kRowHeight   = 22;
static NSUInteger const kMaxRows  = 8;
static CGFloat const kListPadding = 4;

NSArray<NSDictionary*>* AgentSlashCommandsMatchingPrefix (NSArray<NSDictionary*>* commands, NSString* prefix)
{
	NSString* typed = prefix.lowercaseString;
	NSMutableArray* res = [NSMutableArray array];
	for(NSDictionary* command in commands)
	{
		if(![command isKindOfClass:[NSDictionary class]] || ![command[@"name"] isKindOfClass:[NSString class]] || ![command[@"name"] length])
			continue;
		if([[@"/" stringByAppendingString:command[@"name"]].lowercaseString hasPrefix:typed])
			[res addObject:command];
	}

	NSString* exact = [typed hasPrefix:@"/"] ? [typed substringFromIndex:1] : typed;
	[res sortUsingComparator:^NSComparisonResult(NSDictionary* lhs, NSDictionary* rhs){
		BOOL lhsExact = [[lhs[@"name"] lowercaseString] isEqualToString:exact];
		BOOL rhsExact = [[rhs[@"name"] lowercaseString] isEqualToString:exact];
		if(lhsExact != rhsExact)
			return lhsExact ? NSOrderedAscending : NSOrderedDescending;
		return [lhs[@"name"] localizedCaseInsensitiveCompare:rhs[@"name"]];
	}];
	return res;
}

// The list shows above the prompt without taking the keyboard from it
@interface AgentCommandListPanel : NSPanel
@end

@implementation AgentCommandListPanel
- (BOOL)canBecomeKeyWindow  { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// Draw the selection in the accent color although the panel is never key
@interface AgentCommandListRowView : NSTableRowView
@end

@implementation AgentCommandListRowView
- (BOOL)isEmphasized { return YES; }
@end

@interface AgentCommandList () <NSTableViewDataSource, NSTableViewDelegate>
{
	NSArray<NSDictionary*>* _commands;
	AgentCommandListPanel* _panel;
	NSScrollView* _scrollView;
	NSTableView* _tableView;
}
@end

@implementation AgentCommandList
- (void)dealloc
{
	[self close];
}

- (BOOL)isVisible
{
	return _panel.parentWindow != nil;
}

- (NSDictionary*)selectedCommand
{
	NSInteger row = _tableView.selectedRow;
	return self.visible && row >= 0 && row < (NSInteger)_commands.count ? _commands[row] : nil;
}

- (void)createPanel
{
	_tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
	[_tableView addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"command"]];
	_tableView.headerView              = nil;
	_tableView.style                   = NSTableViewStyleFullWidth;
	_tableView.rowHeight               = kRowHeight;
	_tableView.intercellSpacing        = NSMakeSize(0, 0);
	_tableView.backgroundColor         = NSColor.clearColor;
	_tableView.allowsEmptySelection    = NO;
	_tableView.refusesFirstResponder   = YES;
	_tableView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
	_tableView.dataSource              = self;
	_tableView.delegate                = self;
	_tableView.target                  = self;
	_tableView.action                  = @selector(didClickRow:);

	_scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	_scrollView.documentView        = _tableView;
	_scrollView.hasVerticalScroller = YES;
	_scrollView.autohidesScrollers  = YES;
	_scrollView.drawsBackground     = NO;
	_scrollView.borderType          = NSNoBorder;
	_scrollView.automaticallyAdjustsContentInsets = NO;
	_scrollView.contentInsets       = NSEdgeInsetsMake(kListPadding, 0, kListPadding, 0);

	NSVisualEffectView* background = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
	background.material     = NSVisualEffectMaterialMenu;
	background.state        = NSVisualEffectStateActive;
	background.wantsLayer   = YES;
	background.layer.cornerRadius  = 6;
	background.layer.masksToBounds = YES;
	_scrollView.frame            = background.bounds;
	_scrollView.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
	[background addSubview:_scrollView];

	_panel = [[AgentCommandListPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:YES];
	_panel.contentView      = background;
	_panel.opaque           = NO;
	_panel.backgroundColor  = NSColor.clearColor;
	_panel.hasShadow        = YES;
	_panel.releasedWhenClosed = NO;
	_panel.hidesOnDeactivate  = YES;
}

- (void)showCommands:(NSArray<NSDictionary*>*)commands aboveView:(NSView*)view
{
	if(!commands.count || !view.window)
		return [self close];
	if(!_panel)
		[self createPanel];

	NSDictionary* selected = self.selectedCommand;
	_commands = commands;
	[_tableView reloadData];

	// Keep the selected command selected while it still matches
	NSUInteger row = selected ? [_commands indexOfObject:selected] : NSNotFound;
	[_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row == NSNotFound ? 0 : row] byExtendingSelection:NO];
	[_tableView scrollRowToVisible:_tableView.selectedRow];

	NSRect anchor = [view.window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
	CGFloat height = MIN(commands.count, kMaxRows) * kRowHeight + 2 * kListPadding;
	[_panel setFrame:NSMakeRect(NSMinX(anchor), NSMaxY(anchor) + 2, NSWidth(anchor), height) display:YES];
	_panel.appearance = view.effectiveAppearance;

	if(_panel.parentWindow != view.window)
	{
		[_panel.parentWindow removeChildWindow:_panel];
		[view.window addChildWindow:_panel ordered:NSWindowAbove];
	}
	[_panel orderFront:self];
}

- (void)moveSelection:(NSInteger)delta
{
	if(!_commands.count)
		return;
	NSInteger row = MIN(MAX(_tableView.selectedRow + delta, 0), (NSInteger)_commands.count - 1);
	[_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	[_tableView scrollRowToVisible:row];
}

- (void)close
{
	[_panel.parentWindow removeChildWindow:_panel];
	[_panel orderOut:self];
	_commands = nil;
	[_tableView reloadData]; // layout may still ask for the old rows
}

- (void)didClickRow:(id)sender
{
	NSInteger row = _tableView.clickedRow;
	if(row >= 0 && row < (NSInteger)_commands.count && _clickHandler)
		_clickHandler(_commands[row]);
}

// ==========================
// = NSTableView Delegate =
// ==========================

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView
{
	return _commands.count;
}

- (NSTableRowView*)tableView:(NSTableView*)tableView rowViewForRow:(NSInteger)row
{
	return [[AgentCommandListRowView alloc] initWithFrame:NSZeroRect];
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row
{
	NSTextField* label = [tableView makeViewWithIdentifier:@"command" owner:self];
	if(!label)
	{
		label = [NSTextField labelWithString:@""];
		label.identifier    = @"command";
		label.lineBreakMode = NSLineBreakByTruncatingTail;
		label.cell.usesSingleLineMode = YES;
	}

	if(row < 0 || row >= (NSInteger)_commands.count)
		return nil;

	NSDictionary* command = _commands[row];
	BOOL selected = row == tableView.selectedRow;
	NSColor* nameColor        = selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor;
	NSColor* descriptionColor = selected ? [NSColor.alternateSelectedControlTextColor colorWithAlphaComponent:0.75] : NSColor.secondaryLabelColor;
	NSMutableAttributedString* str = [[NSMutableAttributedString alloc] initWithString:[@"/" stringByAppendingString:command[@"name"]] attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium], NSForegroundColorAttributeName: nameColor }];
	if([command[@"description"] isKindOfClass:[NSString class]] && [command[@"description"] length])
		[str appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:command[@"description"]] attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:NSFont.systemFontSize], NSForegroundColorAttributeName: descriptionColor }]];
	label.attributedStringValue = str;
	label.toolTip = command[@"description"];
	return label;
}

// The text colors depend on the selection
- (void)tableViewSelectionDidChange:(NSNotification*)notification
{
	[_tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _commands.count)] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}
@end
