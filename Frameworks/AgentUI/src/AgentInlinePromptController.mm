#import "AgentInlinePromptController.h"
#import "AgentDiffText.h"
#import <AgentClient/AgentDiff.h>

static CGFloat const kWidth = 420;
static CGFloat const kMaxDiffHeight = 280; // taller diffs scroll

static NSTextField* Label (NSString* text, BOOL secondary)
{
	NSTextField* label = [NSTextField wrappingLabelWithString:text ?: @""];
	label.font      = [NSFont systemFontOfSize:secondary ? NSFont.smallSystemFontSize : NSFont.systemFontSize];
	label.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
	label.preferredMaxLayoutWidth = kWidth - 24;
	label.selectable = NO;
	return label;
}

@interface AgentInlinePromptController () <NSPopoverDelegate, NSTextFieldDelegate>
{
	NSString* _agentName;
	NSString* _context;
	NSPopover* _popover;
	NSStackView* _stack;
	NSTextField* _promptField;
}
@end

@implementation AgentInlinePromptController
- (instancetype)initWithAgentName:(NSString*)agentName context:(NSString*)context
{
	if(self = [super initWithNibName:nil bundle:nil])
	{
		_agentName = agentName;
		_context   = context;
	}
	return self;
}

- (void)loadView
{
	_stack = [NSStackView stackViewWithViews:@[ ]];
	_stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	_stack.alignment   = NSLayoutAttributeLeading;
	_stack.spacing     = 8;
	_stack.edgeInsets  = NSEdgeInsetsMake(12, 12, 12, 12);
	[_stack.widthAnchor constraintEqualToConstant:kWidth].active = YES;
	self.view = _stack;
	[self showPrompt];
}

- (void)setViews:(NSArray<NSView*>*)views
{
	for(NSView* view in _stack.arrangedSubviews)
		[view removeFromSuperview];
	for(NSView* view in views)
		[_stack addArrangedSubview:view];
}

- (NSStackView*)buttonRow:(NSArray<NSButton*>*)buttons
{
	NSStackView* row = [NSStackView stackViewWithViews:[@[ [NSView new] ] arrayByAddingObjectsFromArray:buttons]];
	row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	[row.widthAnchor constraintEqualToConstant:kWidth - 24].active = YES;
	return row;
}

- (NSButton*)button:(NSString*)title action:(SEL)action key:(NSString*)key
{
	NSButton* button = [NSButton buttonWithTitle:title target:self action:action];
	button.keyEquivalent = key ?: @"";
	return button;
}

// Each file’s name with its +/− counts, then its changed lines
+ (NSAttributedString*)diffTextForChanges:(NSArray<NSDictionary*>*)changes
{
	NSFont* font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	NSMutableParagraphStyle* heading = [[NSMutableParagraphStyle alloc] init];

	NSMutableAttributedString* res = [[NSMutableAttributedString alloc] init];
	for(NSDictionary* change in changes)
	{
		NSString* name    = [change[@"path"] isKindOfClass:[NSString class]] ? change[@"path"] : @"file";
		NSString* oldText = [change[@"oldText"] isKindOfClass:[NSString class]] ? change[@"oldText"] : nil;
		NSString* newText = [change[@"newText"] isKindOfClass:[NSString class]] ? change[@"newText"] : nil;
		AgentDiff* diff   = [AgentDiff diffWithOldText:oldText newText:newText ?: @"" contextLines:1];

		heading.paragraphSpacingBefore = res.length ? 8 : 0;
		NSString* state = !oldText ? @"  new" : (!newText ? @"  deleted" : @"");
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@%@", res.length ? @"\n" : @"", name] attributes:@{ NSFontAttributeName: [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize], NSForegroundColorAttributeName: NSColor.labelColor, NSParagraphStyleAttributeName: [heading copy] }]];
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:state attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.secondaryLabelColor }]];
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  +%lu", diff.addedLineCount] attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.systemGreenColor }]];
		[res appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" −%lu", diff.removedLineCount] attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.systemRedColor }]];
		AgentAppendDiffLines(res, diff, [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular], 0, 0);
	}
	return res;
}

// As tall as the diffs, up to kMaxDiffHeight; then it scrolls
- (NSView*)diffViewForChanges:(NSArray<NSDictionary*>*)changes
{
	CGFloat const width = kWidth - 24;
	NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, kMaxDiffHeight)];
	scrollView.hasVerticalScroller = YES;
	scrollView.autohidesScrollers  = YES;
	scrollView.drawsBackground     = NO;

	NSTextView* textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, scrollView.contentSize.width, kMaxDiffHeight)];
	textView.editable           = NO;
	textView.selectable         = YES;
	textView.drawsBackground    = NO;
	textView.verticallyResizable = YES;
	textView.autoresizingMask   = NSViewWidthSizable;
	textView.textContainer.widthTracksTextView = YES;
	[textView.textStorage setAttributedString:[AgentInlinePromptController diffTextForChanges:changes]];
	scrollView.documentView = textView;

	[textView.layoutManager ensureLayoutForTextContainer:textView.textContainer];
	CGFloat height = ceil(NSHeight([textView.layoutManager usedRectForTextContainer:textView.textContainer]) + 2 * textView.textContainerInset.height);
	[textView sizeToFit];

	[scrollView.widthAnchor constraintEqualToConstant:width].active = YES;
	[scrollView.heightAnchor constraintEqualToConstant:MIN(height, kMaxDiffHeight)].active = YES;
	return scrollView;
}

// ==========
// = States =
// ==========

- (void)showPrompt
{
	_promptField = [NSTextField textFieldWithString:@""];
	_promptField.placeholderString = [NSString stringWithFormat:@"Ask %@ to change this…", _agentName];
	_promptField.delegate          = self;
	_promptField.lineBreakMode     = NSLineBreakByWordWrapping;
	_promptField.usesSingleLineMode = NO;
	_promptField.cell.wraps        = YES;
	_promptField.cell.scrollable   = NO;
	[_promptField.widthAnchor constraintEqualToConstant:kWidth - 24].active = YES;

	NSString* hint = _context ? [NSString stringWithFormat:@"About %@ · ↩ Send · ⎋ Close", _context] : @"↩ Send · ⎋ Close";
	[self setViews:@[ _promptField, Label(hint, YES) ]];
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)selector
{
	if(selector == @selector(insertNewline:))
	{
		if(NSApp.currentEvent.modifierFlags & (NSEventModifierFlagShift|NSEventModifierFlagOption))
		{
			[textView insertNewlineIgnoringFieldEditor:self];
			return YES;
		}
		NSString* text = [_promptField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if(text.length)
			[_delegate inlinePrompt:self submitText:text];
		return YES;
	}
	return NO;
}

- (void)showWorking:(NSString*)status
{
	NSProgressIndicator* spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
	spinner.style       = NSProgressIndicatorStyleSpinning;
	spinner.controlSize = NSControlSizeSmall;
	[spinner startAnimation:self];

	NSTextField* label = Label(status.length ? status : [NSString stringWithFormat:@"%@ is working…", _agentName], NO);
	label.lineBreakMode = NSLineBreakByTruncatingTail;
	label.maximumNumberOfLines = 2;
	NSStackView* row = [NSStackView stackViewWithViews:@[ spinner, label ]];
	row.orientation = NSUserInterfaceLayoutOrientationHorizontal;

	[self setViews:@[ row, [self buttonRow:@[ [self button:@"Show in Chat" action:@selector(showChat:) key:nil], [self button:@"Stop" action:@selector(stop:) key:@"."] ]] ]];
	[self.view.window makeFirstResponder:nil];
}

- (void)showPermissionRequest:(NSString*)title changes:(NSArray<NSDictionary*>*)changes
{
	NSButton* reject = [self button:@"Reject" action:@selector(reject:) key:@"\e"];
	NSButton* allow  = [self button:@"Allow" action:@selector(allow:) key:@"\r"];
	NSMutableArray* views = [NSMutableArray arrayWithObjects:Label([NSString stringWithFormat:@"%@ asks to:", _agentName], YES), Label(title, NO), nil];
	if(changes.count)
		[views addObject:[self diffViewForChanges:changes]];
	[views addObject:[self buttonRow:@[ [self button:@"Show in Chat" action:@selector(showChat:) key:nil], reject, allow ]]];
	[self setViews:views];
	if(!NSApp.isActive)
		[NSApp requestUserAttention:NSInformationalRequest];
}

- (void)showFinishedWithChanges:(NSArray<NSDictionary*>*)changes reply:(NSString*)reply
{
	NSMutableArray* views = [NSMutableArray array];
	if(changes.count)
		[views addObject:[self diffViewForChanges:changes]];
	if(reply.length)
	{
		NSString* text = reply.length > 400 ? [[reply substringToIndex:[reply rangeOfComposedCharacterSequenceAtIndex:400].location] stringByAppendingString:@"…"] : reply;
		NSTextField* label = Label(text, changes.count > 0);
		label.maximumNumberOfLines = 8;
		[views addObject:label];
	}
	if(!views.count)
		[views addObject:Label(@"Done, nothing changed.", NO)];

	NSMutableArray* buttons = [NSMutableArray arrayWithObject:[self button:@"Show in Chat" action:@selector(showChat:) key:nil]];
	if(changes.count)
	{
		[buttons addObject:[self button:@"Undo" action:@selector(undoChanges:) key:nil]];
		[buttons addObject:[self button:@"Keep" action:@selector(keepChanges:) key:@"\r"]];
	}
	else
	{
		[buttons addObject:[self button:@"Close" action:@selector(closeButton:) key:@"\r"]];
	}
	[views addObject:[self buttonRow:buttons]];
	[self setViews:views];
}

- (void)showFailure:(NSString*)message
{
	NSTextField* label = Label(message, NO);
	label.textColor = NSColor.systemRedColor;
	[self setViews:@[ label, [self buttonRow:@[ [self button:@"Close" action:@selector(closeButton:) key:nil], [self button:@"Show in Chat" action:@selector(showChat:) key:@"\r"] ]] ]];
}

// ===========
// = Actions =
// ===========

- (void)stop:(id)sender         { [_delegate inlinePromptStop:self]; }
- (void)allow:(id)sender        { [_delegate inlinePrompt:self answerPermission:YES]; }
- (void)reject:(id)sender       { [_delegate inlinePrompt:self answerPermission:NO]; }
- (void)keepChanges:(id)sender  { [_delegate inlinePromptKeepChanges:self]; [self close]; }
- (void)undoChanges:(id)sender  { [self close]; [_delegate inlinePromptUndoChanges:self]; }
- (void)showChat:(id)sender     { [self close]; [_delegate inlinePromptShowChat:self]; }
- (void)closeButton:(id)sender  { [self close]; }

// ===========
// = Popover =
// ===========

- (void)showInPopoverRelativeToRect:(NSRect)rect ofView:(NSView*)view
{
	_popover = [[NSPopover alloc] init];
	_popover.contentViewController = self;
	_popover.behavior = NSPopoverBehaviorTransient;
	_popover.delegate = self;
	[_popover showRelativeToRect:rect ofView:view preferredEdge:view.isFlipped ? NSRectEdgeMaxY : NSRectEdgeMinY];
	[self.view.window makeFirstResponder:_promptField];
}

- (BOOL)isShown
{
	return _popover.isShown;
}

- (void)close
{
	[_popover close];
}

- (void)popoverDidClose:(NSNotification*)notification
{
	_popover = nil; // the request, if sent, carries on in the chat
}
@end
