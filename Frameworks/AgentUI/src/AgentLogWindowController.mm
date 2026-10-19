#import "AgentLogWindowController.h"
#import "AgentLog.h"

static NSUInteger const kDetailLimit = 2000; // characters of each message shown

typedef NS_ENUM(NSInteger, AgentLogFilter) {
	AgentLogFilterEverything = 0,
	AgentLogFilterMessages,
	AgentLogFilterOutput, // standard error and events
};

@interface AgentLogWindowController () <NSWindowDelegate, NSSearchFieldDelegate>
{
	NSPopUpButton* _sourcePopUp;
	NSPopUpButton* _filterPopUp;
	NSSearchField* _searchField;
	NSTextView* _textView;
	NSString* _source;            // nil for all agents
	NSUInteger _lastSerialNumber; // last entry considered for the text view
	NSUInteger _shownEntries;
	NSUInteger _sourceCount;      // sources in the popup
}
@end

@implementation AgentLogWindowController
+ (AgentLogWindowController*)sharedInstance
{
	static AgentLogWindowController* sharedInstance = [[self alloc] init];
	return sharedInstance;
}

- (instancetype)init
{
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 520) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
	window.title               = @"Agent Log";
	window.minSize             = NSMakeSize(420, 240);
	window.releasedWhenClosed  = NO;
	window.frameAutosaveName   = @"Agent Log";
	window.restorable          = NO;
	window.collectionBehavior  = NSWindowCollectionBehaviorFullScreenAuxiliary;
	if(self = [super initWithWindow:window])
	{
		window.delegate = self;
		[self buildContent];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(agentLogDidChange:) name:AgentLogDidChangeNotification object:AgentLog.sharedLog];
		if(!window.isVisible)
			[window center];
	}
	return self;
}

- (void)buildContent
{
	_sourcePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	_sourcePopUp.target = self;
	_sourcePopUp.action = @selector(sourceChanged:);

	_filterPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[_filterPopUp addItemsWithTitles:@[ @"Everything", @"Messages", @"Errors and Events" ]];
	_filterPopUp.target = self;
	_filterPopUp.action = @selector(filterChanged:);

	_searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
	_searchField.placeholderString = @"Search";
	_searchField.delegate          = self;
	_searchField.sendsSearchStringImmediately = NO;
	[_searchField.widthAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;

	NSButton* copyButton  = [NSButton buttonWithTitle:@"Copy" target:self action:@selector(copyLog:)];
	copyButton.toolTip    = @"Copy the entries shown";
	NSButton* clearButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearLog:)];

	NSStackView* bar = [NSStackView stackViewWithViews:@[ _sourcePopUp, _filterPopUp, _searchField, copyButton, clearButton ]];
	bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	bar.edgeInsets  = NSEdgeInsetsMake(8, 12, 8, 12);
	[_searchField setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

	NSScrollView* scrollView = [NSTextView scrollableTextView];
	scrollView.borderType = NSNoBorder;
	_textView = scrollView.documentView;
	_textView.editable           = NO;
	_textView.selectable         = YES;
	_textView.usesFindBar        = YES;
	_textView.richText           = NO;
	_textView.textContainerInset = NSMakeSize(8, 8);
	_textView.font               = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

	NSBox* separator = [[NSBox alloc] initWithFrame:NSZeroRect];
	separator.boxType = NSBoxSeparator;

	NSStackView* stack = [NSStackView stackViewWithViews:@[ bar, separator, scrollView ]];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.spacing     = 0;
	for(NSView* view in stack.arrangedSubviews)
		[view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
	[scrollView setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
	self.window.contentView = stack;

	[self rebuildSourcePopUp];
	[self rebuildText];
}

- (void)showWindowForSource:(NSString*)source
{
	_source = source;
	[self rebuildSourcePopUp];
	[self rebuildText];
	[self showWindow:self];
}

- (void)rebuildSourcePopUp
{
	[_sourcePopUp removeAllItems];
	[_sourcePopUp addItemWithTitle:@"All Agents"];
	NSArray<NSString*>* sources = AgentLog.sharedLog.sources;
	_sourceCount = sources.count;
	if(sources.count)
		[_sourcePopUp.menu addItem:[NSMenuItem separatorItem]];
	for(NSString* source in sources)
	{
		[_sourcePopUp addItemWithTitle:source];
		_sourcePopUp.lastItem.representedObject = source;
	}
	NSInteger index = _source ? [_sourcePopUp indexOfItemWithRepresentedObject:_source] : 0;
	[_sourcePopUp selectItemAtIndex:index != -1 ? index : 0];
}

- (void)sourceChanged:(id)sender
{
	_source = _sourcePopUp.selectedItem.representedObject;
	[self rebuildText];
}

- (void)filterChanged:(id)sender
{
	[self rebuildText];
}

- (void)controlTextDidChange:(NSNotification*)notification
{
	[self rebuildText];
}

- (void)copyLog:(id)sender
{
	[NSPasteboard.generalPasteboard clearContents];
	[NSPasteboard.generalPasteboard writeObjects:@[ _textView.string ]];
}

- (void)clearLog:(id)sender
{
	[AgentLog.sharedLog clear];
}

// ===========
// = Entries =
// ===========

- (BOOL)showsEntry:(AgentLogEntry*)entry
{
	if(_source && ![entry.source isEqualToString:_source])
		return NO;

	BOOL isMessage = entry.kind == AgentLogEntryKindSent || entry.kind == AgentLogEntryKindReceived;
	switch(_filterPopUp.indexOfSelectedItem)
	{
		case AgentLogFilterMessages: if(!isMessage) return NO; break;
		case AgentLogFilterOutput:   if(isMessage)  return NO; break;
	}
	return [entry matchesSearchString:_searchField.stringValue];
}

- (NSAttributedString*)textForEntry:(AgentLogEntry*)entry
{
	static NSDateFormatter* formatter = [] {
		NSDateFormatter* res = [[NSDateFormatter alloc] init];
		res.dateFormat = @"HH:mm:ss.SSS";
		return res;
	}();

	NSFont* font     = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	NSFont* boldFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightSemibold];
	NSColor* color;
	switch(entry.kind)
	{
		case AgentLogEntryKindSent:          color = NSColor.systemBlueColor;      break;
		case AgentLogEntryKindReceived:      color = NSColor.systemGreenColor;     break;
		case AgentLogEntryKindStandardError: color = NSColor.systemOrangeColor;    break;
		case AgentLogEntryKindEvent:         color = NSColor.systemPurpleColor;    break;
	}

	NSMutableParagraphStyle* detailStyle = [[NSMutableParagraphStyle alloc] init];
	detailStyle.firstLineHeadIndent = 16;
	detailStyle.headIndent          = 16;
	detailStyle.paragraphSpacing    = 4;

	NSMutableAttributedString* res = [[NSMutableAttributedString alloc] init];
	NSString* prefix = _source ? [formatter stringFromDate:entry.date] : [NSString stringWithFormat:@"%@  %@", [formatter stringFromDate:entry.date], entry.source];
	[res appendAttributedString:[[NSAttributedString alloc] initWithString:[prefix stringByAppendingString:@"  "] attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.secondaryLabelColor }]];
	[res appendAttributedString:[[NSAttributedString alloc] initWithString:[entry.summary stringByAppendingString:@"\n"] attributes:@{ NSFontAttributeName: boldFont, NSForegroundColorAttributeName: color }]];
	if(NSString* detail = [entry detailWithLimit:kDetailLimit])
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:[detail stringByAppendingString:@"\n"] attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.labelColor, NSParagraphStyleAttributeName: detailStyle }]];
	return res;
}

- (BOOL)isScrolledToEnd
{
	NSRect visible = _textView.enclosingScrollView.contentView.documentVisibleRect;
	return NSMaxY(visible) >= NSHeight(_textView.frame) - 20;
}

- (void)appendEntries:(NSArray<AgentLogEntry*>*)entries
{
	NSMutableAttributedString* text = [[NSMutableAttributedString alloc] init];
	for(AgentLogEntry* entry in entries)
	{
		_lastSerialNumber = MAX(_lastSerialNumber, entry.serialNumber);
		if([self showsEntry:entry])
		{
			[text appendAttributedString:[self textForEntry:entry]];
			++_shownEntries;
		}
	}
	if(!text.length)
		return;

	BOOL follow = [self isScrolledToEnd];
	[_textView.textStorage appendAttributedString:text];
	if(follow)
		[_textView scrollToEndOfDocument:self];
}

- (void)rebuildText
{
	_lastSerialNumber = 0;
	_shownEntries     = 0;
	[_textView.textStorage setAttributedString:[[NSAttributedString alloc] init]];
	[self appendEntries:AgentLog.sharedLog.entries];
	[_textView scrollToEndOfDocument:self];
}

- (void)agentLogDidChange:(NSNotification*)notification
{
	if(!self.window.isVisible)
		return;

	NSArray<AgentLogEntry*>* entries = AgentLog.sharedLog.entries;
	if(_sourceCount != AgentLog.sharedLog.sources.count)
		[self rebuildSourcePopUp];

	// Cleared, or trimmed well past what the text view shows
	if(!entries.count || _shownEntries > AgentLog.sharedLog.maximumEntries * 6 / 5)
		return [self rebuildText];

	NSUInteger first = entries.count;
	while(first > 0 && entries[first-1].serialNumber > _lastSerialNumber)
		--first;
	[self appendEntries:[entries subarrayWithRange:NSMakeRange(first, entries.count - first)]];
}

- (void)windowDidBecomeKey:(NSNotification*)notification
{
	// Entries added while the window was closed
	if(AgentLog.sharedLog.entries.lastObject.serialNumber != _lastSerialNumber)
		[self rebuildText];
}
@end
