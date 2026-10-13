#import "AgentPromptView.h"

static CGFloat const kMinTextHeight = 28;
static CGFloat const kMaxTextHeight = 180;
static NSUInteger const kMaxHistory = 50;

// =======================
// = AgentPromptTextView =
// =======================

@class AgentPromptTextView;

@protocol AgentPromptTextViewOwner <NSObject>
- (BOOL)promptTextView:(AgentPromptTextView*)textView acceptFileURLs:(NSArray<NSURL*>*)urls;
- (BOOL)promptTextViewPasteImage:(AgentPromptTextView*)textView;
@end

@interface AgentPromptTextView : NSTextView
@property (nonatomic, weak) id<AgentPromptTextViewOwner> owner;
@property (nonatomic) NSString* promptPlaceholder;
@end

@implementation AgentPromptTextView
- (void)drawRect:(NSRect)rect
{
	[super drawRect:rect];
	if(self.string.length || !_promptPlaceholder.length)
		return;

	NSPoint origin = self.textContainerOrigin;
	origin.x += self.textContainer.lineFragmentPadding;
	[_promptPlaceholder drawAtPoint:origin withAttributes:@{ NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:NSFont.systemFontSize], NSForegroundColorAttributeName: NSColor.placeholderTextColor }];
}

// Include the leading “/” so slash commands complete as one word
- (NSRange)rangeForUserCompletion
{
	NSString* str = self.string;
	NSRange selection = self.selectedRange;
	if([str hasPrefix:@"/"] && selection.length == 0 && [str rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet options:0 range:NSMakeRange(0, selection.location)].location == NSNotFound)
		return NSMakeRange(0, selection.location);
	return [super rangeForUserCompletion];
}

- (NSArray<NSURL*>*)fileURLsFromDraggingInfo:(id<NSDraggingInfo>)sender
{
	return [sender.draggingPasteboard readObjectsForClasses:@[ [NSURL class] ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
	return [self fileURLsFromDraggingInfo:sender].count ? NSDragOperationCopy : [super draggingEntered:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender
{
	return [self fileURLsFromDraggingInfo:sender].count ? NSDragOperationCopy : [super draggingUpdated:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
	NSArray<NSURL*>* urls = [self fileURLsFromDraggingInfo:sender];
	if(urls.count && [_owner promptTextView:self acceptFileURLs:urls])
		return YES;
	return [super performDragOperation:sender];
}

- (void)paste:(id)sender
{
	if(![_owner promptTextViewPasteImage:self])
		[self pasteAsPlainText:sender];
}
@end

// ===================
// = AgentPromptView =
// ===================

@interface AgentPromptView () <NSTextViewDelegate, AgentPromptTextViewOwner>
{
	NSMutableArray<AgentAttachment*>* _attachments;
	NSMutableArray<NSString*>* _history;
	NSInteger _historyIndex;
	NSString* _draftBeforeHistory;
	BOOL _completing;

	NSStackView* _chipsView;
	NSScrollView* _textScrollView;
	AgentPromptTextView* _textView;
	NSLayoutConstraint* _textHeightConstraint;
	NSButton* _addContextButton;
	NSButton* _sendButton;
}
@end

@implementation AgentPromptView
- (instancetype)initWithFrame:(NSRect)frame
{
	if(self = [super initWithFrame:frame])
	{
		_attachments  = [NSMutableArray array];
		_history      = [NSMutableArray array];
		_historyIndex = -1;
		_enabled      = YES;

		_chipsView = [NSStackView stackViewWithViews:@[ ]];
		_chipsView.orientation = NSUserInterfaceLayoutOrientationHorizontal;
		_chipsView.spacing     = 4;
		_chipsView.hidden      = YES;

		_textScrollView = [AgentPromptTextView scrollableTextView];
		_textScrollView.hasVerticalScroller = YES;
		_textScrollView.autohidesScrollers  = YES;
		// A rounded input field on the panel’s window-colored background
		_textScrollView.drawsBackground     = YES;
		_textScrollView.backgroundColor     = NSColor.textBackgroundColor;
		_textScrollView.wantsLayer          = YES;
		_textScrollView.layer.cornerRadius  = 6;
		_textScrollView.layer.borderWidth   = 1;
		_textScrollView.contentInsets       = NSEdgeInsetsMake(4, 6, 4, 6);
		_textScrollView.automaticallyAdjustsContentInsets = NO;
		_textScrollView.borderType          = NSNoBorder;

		// Replace the scroll view’s text view with our subclass, keeping its configuration
		NSTextView* prototype = _textScrollView.documentView;
		_textView = [[AgentPromptTextView alloc] initWithFrame:prototype.frame];
		_textView.autoresizingMask       = prototype.autoresizingMask;
		_textView.verticallyResizable    = YES;
		_textView.horizontallyResizable  = NO;
		_textView.textContainer.widthTracksTextView = YES;
		_textView.richText               = NO;
		_textView.allowsUndo             = YES;
		_textView.drawsBackground        = NO;
		_textView.font                   = [NSFont systemFontOfSize:NSFont.systemFontSize];
		_textView.textContainerInset     = NSMakeSize(0, 2);
		_textView.automaticQuoteSubstitutionEnabled = NO;
		_textView.automaticDashSubstitutionEnabled  = NO;
		_textView.delegate = self;
		_textView.owner    = self;
		_textScrollView.documentView = _textView;

		_addContextButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"Add Context"] target:self action:@selector(showAddContextMenu:)];
		_addContextButton.bordered = NO;
		_addContextButton.toolTip  = @"Add Context (files, selection, images)";

		_sendButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.up.circle.fill" accessibilityDescription:@"Send"] target:self action:@selector(sendOrStop:)];
		_sendButton.bordered = NO;
		_sendButton.contentTintColor = NSColor.controlAccentColor;
		_sendButton.toolTip  = @"Send (↩)";
		[_sendButton.widthAnchor constraintEqualToConstant:22].active = YES;

		NSStackView* buttons = [NSStackView stackViewWithViews:@[ _addContextButton, [NSView new], _sendButton ]];
		buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;

		NSStackView* stack = [NSStackView stackViewWithViews:@[ _chipsView, _textScrollView, buttons ]];
		stack.orientation = NSUserInterfaceLayoutOrientationVertical;
		[stack setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
		stack.alignment   = NSLayoutAttributeLeading;
		stack.spacing     = 4;
		stack.edgeInsets  = NSEdgeInsetsMake(8, 10, 6, 10);
		stack.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview:stack];

		_textHeightConstraint = [_textScrollView.heightAnchor constraintEqualToConstant:kMinTextHeight];
		[NSLayoutConstraint activateConstraints:@[
			[stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
			[stack.topAnchor constraintEqualToAnchor:self.topAnchor],
			[stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
			[_textScrollView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-20],
			[buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-20],
			_textHeightConstraint,
		]];
		[self updateFieldBorder];
	}
	return self;
}

// Layer colors don’t follow appearance changes by themselves
- (void)viewDidChangeEffectiveAppearance
{
	[super viewDidChangeEffectiveAppearance];
	[self updateFieldBorder];
}

- (void)updateFieldBorder
{
	[self.effectiveAppearance performAsCurrentDrawingAppearance:^{
		_textScrollView.layer.borderColor = NSColor.separatorColor.CGColor;
	}];
}

- (NSView*)initialFirstResponder { return _textView; }
- (NSString*)text                { return [_textView.string copy]; }
- (NSArray<AgentAttachment*>*)attachments { return [_attachments copy]; }

- (void)setText:(NSString*)text
{
	_textView.string = text ?: @"";
	_textView.selectedRange = NSMakeRange(_textView.string.length, 0);
	[self updateTextHeight];
	_textView.needsDisplay = YES;
}

- (void)setPlaceholderString:(NSString*)placeholderString
{
	_placeholderString = placeholderString;
	_textView.promptPlaceholder = placeholderString;
	_textView.needsDisplay = YES;
}

- (void)setWorking:(BOOL)flag
{
	_working = flag;
	_sendButton.image   = [NSImage imageWithSystemSymbolName:(flag ? @"stop.circle.fill" : @"arrow.up.circle.fill") accessibilityDescription:(flag ? @"Stop" : @"Send")];
	_sendButton.toolTip = flag ? @"Stop (⎋)" : @"Send (↩)";
}

- (void)setEnabled:(BOOL)flag
{
	_enabled = flag;
	_textView.editable        = flag;
	_addContextButton.enabled = flag;
	_sendButton.enabled       = flag;
}

- (void)updateTextHeight
{
	[_textView.layoutManager ensureLayoutForTextContainer:_textView.textContainer];
	CGFloat height = NSHeight([_textView.layoutManager usedRectForTextContainer:_textView.textContainer]) + 2 * _textView.textContainerInset.height + _textScrollView.contentInsets.top + _textScrollView.contentInsets.bottom;
	_textHeightConstraint.constant = MIN(MAX(height, kMinTextHeight), kMaxTextHeight);
}

// ===============
// = Attachments =
// ===============

- (void)addAttachment:(AgentAttachment*)attachment
{
	for(AgentAttachment* existing in _attachments)
	{
		if(existing.kind == attachment.kind && [existing.name isEqualToString:attachment.name])
			return;
	}
	[_attachments addObject:attachment];
	[self updateChips];
}

- (void)removeAllAttachments
{
	[_attachments removeAllObjects];
	[self updateChips];
}

- (void)updateChips
{
	for(NSView* view in _chipsView.arrangedSubviews)
		[view removeFromSuperview];

	for(AgentAttachment* attachment in _attachments)
	{
		NSString* symbol = attachment.kind == AgentAttachmentKindImage ? @"photo" : (attachment.kind == AgentAttachmentKindSelection ? @"text.cursor" : @"doc");
		NSButton* chip = [NSButton buttonWithTitle:[attachment.name stringByAppendingString:@"  ✕"] target:self action:@selector(removeAttachment:)];
		chip.image         = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
		chip.imagePosition = NSImageLeading;
		chip.bezelStyle    = NSBezelStyleRecessed;
		chip.controlSize   = NSControlSizeSmall;
		chip.font          = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
		chip.toolTip       = attachment.path ?: attachment.name;
		chip.tag           = [_attachments indexOfObject:attachment];
		[_chipsView addArrangedSubview:chip];
	}
	_chipsView.hidden = _attachments.count == 0;
}

- (void)removeAttachment:(NSButton*)sender
{
	if(sender.tag >= 0 && sender.tag < (NSInteger)_attachments.count)
		[_attachments removeObjectAtIndex:sender.tag];
	[self updateChips];
}

- (void)showAddContextMenu:(NSButton*)sender
{
	if(![_delegate respondsToSelector:@selector(addContextMenuForPromptView:)])
		return;
	NSMenu* menu = [_delegate addContextMenuForPromptView:self];
	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
}

- (BOOL)promptTextView:(AgentPromptTextView*)textView acceptFileURLs:(NSArray<NSURL*>*)urls
{
	for(NSURL* url in urls)
	{
		BOOL isDirectory = NO;
		if([NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDirectory] && !isDirectory)
			[self addAttachment:[AgentAttachment fileAttachmentWithPath:url.path text:nil]];
	}
	return YES;
}

- (BOOL)promptTextViewPasteImage:(AgentPromptTextView*)textView
{
	NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
	if([pasteboard canReadObjectForClasses:@[ [NSString class] ] options:nil] || ![pasteboard canReadObjectForClasses:@[ [NSImage class] ] options:nil])
		return NO;
	if(![_delegate respondsToSelector:@selector(promptViewAcceptsImages:)] || ![_delegate promptViewAcceptsImages:self])
	{
		NSBeep(); // the agent doesn’t accept images
		return YES;
	}

	NSImage* image = [[pasteboard readObjectsForClasses:@[ [NSImage class] ] options:nil] firstObject];
	CGImageRef cgImage = [image CGImageForProposedRect:nullptr context:nil hints:nil];
	if(!cgImage)
		return NO;
	NSData* png = [[[NSBitmapImageRep alloc] initWithCGImage:cgImage] representationUsingType:NSBitmapImageFileTypePNG properties:@{ }];
	NSUInteger imageCount = 1;
	for(AgentAttachment* attachment in _attachments)
		imageCount += attachment.kind == AgentAttachmentKindImage ? 1 : 0;
	[self addAttachment:[AgentAttachment imageAttachmentWithPNGData:png name:[NSString stringWithFormat:@"Image %lu", imageCount]]];
	return YES;
}

// ===========
// = Sending =
// ===========

- (void)sendOrStop:(id)sender
{
	if(_working)
			[_delegate promptViewDidRequestStop:self];
	else	[self submit];
}

- (void)submit
{
	if(!_enabled || _working || (!self.text.length && !_attachments.count))
		return;
	[_delegate promptViewDidSubmit:self];
}

- (void)rememberPrompt:(NSString*)text
{
	if(!text.length || [_history.lastObject isEqualToString:text])
		return;
	[_history addObject:text];
	if(_history.count > kMaxHistory)
		[_history removeObjectAtIndex:0];
	_historyIndex = -1;
}

- (BOOL)recallHistory:(NSInteger)direction
{
	if(!_history.count)
		return NO;

	if(_historyIndex == -1)
	{
		if(direction > 0)
			return NO;
		_draftBeforeHistory = self.text;
		_historyIndex = _history.count;
	}

	NSInteger index = _historyIndex + direction;
	if(index < 0)
		return YES;
	if(index >= (NSInteger)_history.count)
	{
		_historyIndex = -1;
		self.text = _draftBeforeHistory;
		return YES;
	}

	_historyIndex = index;
	self.text = _history[index];
	return YES;
}

// =======================
// = NSTextViewDelegate =
// =======================

- (BOOL)textView:(NSTextView*)textView doCommandBySelector:(SEL)selector
{
	if(selector == @selector(insertNewline:))
	{
		if(NSApp.currentEvent.modifierFlags & (NSEventModifierFlagShift|NSEventModifierFlagOption))
		{
			[textView insertNewlineIgnoringFieldEditor:self];
			return YES;
		}
		[self submit];
		return YES;
	}
	if(selector == @selector(cancelOperation:))
	{
		if(_working)
			[_delegate promptViewDidRequestStop:self];
		return YES;
	}

	// ↑ on the first line / ↓ on the last line walk the prompt history
	NSRange selection = textView.selectedRange;
	if(selector == @selector(moveUp:) && [textView.string rangeOfString:@"\n" options:0 range:NSMakeRange(0, selection.location)].location == NSNotFound)
		return [self recallHistory:-1];
	if(selector == @selector(moveDown:) && [textView.string rangeOfString:@"\n" options:0 range:NSMakeRange(NSMaxRange(selection), textView.string.length - NSMaxRange(selection))].location == NSNotFound)
		return [self recallHistory:+1];
	return NO;
}

- (void)textDidChange:(NSNotification*)notification
{
	[self updateTextHeight];
	_textView.needsDisplay = YES;

	// Offer slash commands while the first word starts with “/”
	if(_completing)
		return;
	NSString* str = _textView.string;
	NSRange word = [_textView rangeForUserCompletion];
	if(![str hasPrefix:@"/"] || word.location != 0 || word.length != _textView.selectedRange.location)
		return;

	NSString* partial = [str substringWithRange:word];
	NSArray* completions = [self slashCommandCompletionsForPrefix:partial];
	if(completions.count && !(completions.count == 1 && [completions.firstObject isEqualToString:partial]))
	{
		_completing = YES;
		[_textView complete:self];
		_completing = NO;
	}
}

- (NSArray<NSString*>*)slashCommandCompletionsForPrefix:(NSString*)prefix
{
	if(![_delegate respondsToSelector:@selector(slashCommandsForPromptView:)])
		return @[ ];

	NSMutableArray* res = [NSMutableArray array];
	for(NSDictionary* command in [_delegate slashCommandsForPromptView:self])
	{
		NSString* name = [@"/" stringByAppendingString:command[@"name"] ?: @""];
		if(name.length > 1 && [name.lowercaseString hasPrefix:prefix.lowercaseString])
			[res addObject:name];
	}
	return [res sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSArray<NSString*>*)textView:(NSTextView*)textView completions:(NSArray<NSString*>*)words forPartialWordRange:(NSRange)charRange indexOfSelectedItem:(NSInteger*)index
{
	NSString* partial = [textView.string substringWithRange:charRange];
	if(charRange.location == 0 && [partial hasPrefix:@"/"])
	{
		if(index)
			*index = -1; // don’t insert anything until the user picks
		return [self slashCommandCompletionsForPrefix:partial];
	}
	return @[ ];
}
@end
