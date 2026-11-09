#import "AgentInlinePromptController.h"
#import "AgentDiffText.h"
#import <AgentClient/AgentDiff.h>
#import <OakMarkdown/OakMarkdown.h>

static CGFloat const kWidth = 420;
static CGFloat const kMaxDiffHeight = 280; // taller diffs scroll
static CGFloat const kMaxReplyHeight = 220; // and replies

static NSTextField* Label (NSString* text, BOOL secondary)
{
	NSTextField* label = [NSTextField wrappingLabelWithString:text ?: @""];
	label.font      = [NSFont systemFontOfSize:secondary ? NSFont.smallSystemFontSize : NSFont.systemFontSize];
	label.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
	label.preferredMaxLayoutWidth = kWidth - 24;
	label.selectable = NO;
	return label;
}

@interface AgentInlinePromptController () <NSPopoverDelegate, NSTextFieldDelegate, NSTextViewDelegate>
{
	NSString* _agentName;
	NSString* _context;
	NSPopover* _popover;
	NSStackView* _stack;
	NSTextField* _promptField;
	NSArray<NSString*>* _codes;           // the reply’s code blocks
	NSArray<NSButton*>* _codeCheckboxes;  // with several: which ones the actions use
	NSTextView* _replyView;
	NSTextField* _codeStatus;             // the hint over the buttons, then what was done
	NSButton* _copyButton;
	NSButton* _insertButton;
	AgentInlineInsertMode _insertMode;
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

// The reply as Markdown, code blocks included, in the popover’s fonts
+ (NSAttributedString*)replyText:(NSString*)reply codeBlocks:(NSArray<OakMarkdownCodeBlock*>**)codeBlocks
{
	OakMarkdownStyle* style = [OakMarkdownStyle defaultStyle];
	style.font     = [NSFont systemFontOfSize:NSFont.systemFontSize];
	style.codeFont = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
	return [OakMarkdownRenderer attributedStringFromMarkdown:reply style:style codeBlocks:codeBlocks codeBlockFooter:nil];
}

// With several code blocks: a checkbox for each, named by its number,
// language and first line. The first is checked to start with.
- (NSView*)codeBlockCheckboxes:(NSArray<OakMarkdownCodeBlock*>*)codeBlocks
{
	NSMutableArray<NSButton*>* checkboxes = [NSMutableArray array];
	for(NSUInteger i = 0; i < codeBlocks.count; ++i)
	{
		NSString* firstLine = @"";
		for(NSString* line in [codeBlocks[i].code componentsSeparatedByString:@"\n"])
		{
			if((firstLine = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]).length)
				break;
		}
		if(firstLine.length > 48)
			firstLine = [[firstLine substringToIndex:[firstLine rangeOfComposedCharacterSequenceAtIndex:48].location] stringByAppendingString:@"…"];
		NSString* language = codeBlocks[i].language;
		NSString* title = [NSString stringWithFormat:@"%lu. %@%@", i + 1, language.length ? [language stringByAppendingString:@" — "] : @"", firstLine];

		NSButton* checkbox = [NSButton checkboxWithTitle:title target:self action:@selector(toggleCodeBlock:)];
		checkbox.controlSize = NSControlSizeSmall;
		checkbox.font        = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
		checkbox.tag         = i;
		checkbox.state       = i == 0 ? NSControlStateValueOn : NSControlStateValueOff;
		checkbox.lineBreakMode = NSLineBreakByTruncatingTail;
		[checkbox.widthAnchor constraintLessThanOrEqualToConstant:kWidth - 24].active = YES;
		[checkboxes addObject:checkbox];
	}
	_codeCheckboxes = checkboxes;

	NSStackView* stack = [NSStackView stackViewWithViews:checkboxes];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment   = NSLayoutAttributeLeading;
	stack.spacing     = 2;
	return stack;
}

// Shows the block in the reply
- (void)toggleCodeBlock:(NSButton*)sender
{
	NSUInteger const block = sender.tag;
	NSTextStorage* textStorage = _replyView.textStorage;
	__block NSRange range = NSMakeRange(NSNotFound, 0);
	[textStorage enumerateAttribute:OakMarkdownCodeBlockAttributeName inRange:NSMakeRange(0, textStorage.length) options:0 usingBlock:^(NSNumber* index, NSRange blockRange, BOOL* stop){
		if(index && index.unsignedIntegerValue == block)
		{
			range = range.location == NSNotFound ? blockRange : NSUnionRange(range, blockRange);
		}
		else if(range.location != NSNotFound)
		{
			*stop = YES;
		}
	}];
	if(range.location != NSNotFound && sender.state == NSControlStateValueOn)
	{
		[_replyView scrollRangeToVisible:range];
		[_replyView showFindIndicatorForRange:range];
	}
	[self updateCodeButtons];
}

// Text selected in the reply, else the checked blocks (or the only one), one after another
- (NSString*)codeToUse
{
	NSRange selection = _replyView.selectedRange;
	if(selection.length)
		return [_replyView.string substringWithRange:selection];

	if(!_codeCheckboxes)
		return _codes.firstObject;

	NSMutableArray* res = [NSMutableArray array];
	for(NSButton* checkbox in _codeCheckboxes)
	{
		if(checkbox.state == NSControlStateValueOn)
			[res addObject:_codes[checkbox.tag]];
	}
	return res.count ? [res componentsJoinedByString:@"\n"] : nil;
}

- (void)updateCodeButtons
{
	BOOL const enabled = self.codeToUse.length > 0;
	_copyButton.enabled   = enabled;
	_insertButton.enabled = enabled;
}

- (void)textViewDidChangeSelection:(NSNotification*)notification
{
	[self updateCodeButtons];
}

- (void)setCodeStatus:(NSString*)status
{
	_codeStatus.stringValue = status;
	_codeStatus.hidden      = NO;
}

// As tall as the diffs, up to kMaxDiffHeight; then it scrolls
- (NSView*)diffViewForChanges:(NSArray<NSDictionary*>*)changes
{
	return [self scrollingText:[AgentInlinePromptController diffTextForChanges:changes] maxHeight:kMaxDiffHeight];
}

- (NSView*)scrollingText:(NSAttributedString*)text maxHeight:(CGFloat)maxHeight
{
	CGFloat const width = kWidth - 24;
	NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, maxHeight)];
	scrollView.hasVerticalScroller = YES;
	scrollView.autohidesScrollers  = YES;
	scrollView.drawsBackground     = NO;

	NSTextView* textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, scrollView.contentSize.width, maxHeight)];
	textView.editable           = NO;
	textView.selectable         = YES;
	textView.drawsBackground    = NO;
	textView.verticallyResizable = YES;
	textView.autoresizingMask   = NSViewWidthSizable;
	textView.textContainer.widthTracksTextView = YES;
	[textView.textStorage setAttributedString:text];
	scrollView.documentView = textView;

	[textView.layoutManager ensureLayoutForTextContainer:textView.textContainer];
	CGFloat height = ceil(NSHeight([textView.layoutManager usedRectForTextContainer:textView.textContainer]) + 2 * textView.textContainerInset.height);
	[textView sizeToFit];

	[scrollView.widthAnchor constraintEqualToConstant:width].active = YES;
	[scrollView.heightAnchor constraintEqualToConstant:MIN(height, maxHeight)].active = YES;
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
	_codes          = @[ ];
	_codeCheckboxes = nil;
	_replyView      = nil;
	_insertMode     = _replacesSelection ? AgentInlineInsertReplacingSelection : AgentInlineInsertAtCursor;
	if(reply.length)
	{
		NSArray<OakMarkdownCodeBlock*>* codeBlocks;
		NSAttributedString* text = [AgentInlinePromptController replyText:reply codeBlocks:&codeBlocks];
		_codes = [codeBlocks valueForKey:@"code"] ?: @[ ];
		NSScrollView* scrollView = (NSScrollView*)[self scrollingText:text maxHeight:changes.count ? kMaxReplyHeight / 2 : kMaxReplyHeight];
		_replyView = scrollView.documentView;
		_replyView.delegate = self;
		[views addObject:scrollView];
		if(codeBlocks.count > 1)
			[views addObject:[self codeBlockCheckboxes:codeBlocks]];
	}
	if(!views.count)
		[views addObject:Label(@"Done, nothing changed.", NO)];

	BOOL const hasCode = _codes.count > 0;
	_codeStatus = Label(@"Check the blocks to use; they go in one after another. Or select text in the reply to use just that.", YES);
	_codeStatus.hidden = !_codeCheckboxes;
	if(hasCode)
		[views addObject:_codeStatus];

	NSMutableArray* buttons = [NSMutableArray arrayWithObject:[self button:@"Show in Chat" action:@selector(showChat:) key:nil]];
	_copyButton = _insertButton = nil;
	if(hasCode)
		[buttons addObject:_copyButton = [self button:@"Copy" action:@selector(copyCode:) key:nil]];
	if(changes.count)
	{
		[buttons addObject:[self button:@"Undo" action:@selector(undoChanges:) key:nil]];
		[buttons addObject:[self button:@"Keep" action:@selector(keepChanges:) key:@"\r"]];
	}
	else
	{
		if(hasCode)
			[buttons addObject:_insertButton = [self button:(_replacesSelection ? @"Replace Selection" : @"Insert at Cursor") action:@selector(insertCode:) key:nil]];
		[buttons addObject:[self button:@"Close" action:@selector(closeButton:) key:@"\r"]];
	}
	[views addObject:[self buttonRow:buttons]];
	[self setViews:views];
	[self updateCodeButtons];
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
// The popover stays open for more. After the first, each goes after the last.
- (void)insertCode:(id)sender
{
	NSString* code = self.codeToUse;
	if(!code.length)
		return;
	[_delegate inlinePrompt:self insertText:code mode:_insertMode];
	[self setCodeStatus:_insertMode == AgentInlineInsertReplacingSelection ? @"Replaced the selection. Check other blocks to add them after it." : @"Inserted. Check other blocks to add them after it."];
	_insertMode = AgentInlineInsertAfterLastInsertion;
	_insertButton.title = @"Insert After";
}

- (void)copyCode:(id)sender
{
	NSString* code = self.codeToUse;
	if(!code.length)
		return;
	[NSPasteboard.generalPasteboard clearContents];
	[NSPasteboard.generalPasteboard setString:code forType:NSPasteboardTypeString];
	[self setCodeStatus:@"Copied."];
}

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

// Only up or down: it keeps the column it was opened at
- (void)moveToRect:(NSRect)rect
{
	if(!_popover.isShown || NSIsEmptyRect(rect))
		return;
	NSRect res = _popover.positioningRect;
	res.origin.y    = NSMinY(rect);
	res.size.height = NSHeight(rect);
	_popover.positioningRect = res;
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
