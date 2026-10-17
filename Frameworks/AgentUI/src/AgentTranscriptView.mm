#import "AgentTranscriptView.h"
#import <OakMarkdown/OakMarkdown.h>
#import <AgentClient/AgentDiff.h>
#import <OakAppKit/NSColor Additions.h>

static NSString* const kActionScheme      = @"textmate-agent";
static NSTimeInterval const kCoalesceDelay = 0.05;
static NSUInteger const kDiffPreviewLines   = 12;
static NSUInteger const kOutputPreviewLines = 12;

static NSFont* SmallFont ()          { return [NSFont systemFontOfSize:NSFont.smallSystemFontSize]; }
static NSFont* SmallMonospaceFont () { return [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular]; }

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

@interface AgentTranscriptView () <NSTextViewDelegate>
{
	NSMutableDictionary<NSString*, NSNumber*>* _renderedLengths;
	NSMutableSet<NSString*>* _pendingIdentifiers;
	NSMutableDictionary<NSString*, NSArray<OakMarkdownCodeBlock*>*>* _codeBlocks;
	BOOL _flushScheduled;
	OakMarkdownStyle* _markdownStyle;
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

		self.editable           = NO;
		self.selectable         = YES;
		self.richText           = YES;
		self.drawsBackground    = YES;
		self.backgroundColor    = NSColor.tmSidebarBackgroundColor;
		self.textContainerInset = NSMakeSize(10, 10);
		self.delegate           = self;
		self.linkTextAttributes = @{ NSForegroundColorAttributeName: NSColor.linkColor, NSCursorAttributeName: NSCursor.pointingHandCursor };
		self.automaticLinkDetectionEnabled = NO;
	}
	return self;
}

- (void)setTranscript:(AgentTranscript*)transcript
{
	_transcript = transcript;
	[self reloadData];
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
	if(_flushScheduled)
		return;

	_flushScheduled = YES;
	__weak AgentTranscriptView* weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCoalesceDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[weakSelf flushPendingItems];
	});
}

- (BOOL)isScrolledToBottom
{
	return NSMaxY(self.visibleRect) >= NSHeight(self.bounds) - 30;
}

- (void)flushPendingItems
{
	_flushScheduled = NO;
	if(!_pendingIdentifiers.count)
		return;

	BOOL wasAtBottom = [self isScrolledToBottom];
	NSTextStorage* storage = self.textStorage;
	[storage beginEditing];

	NSUInteger location = 0;
	for(AgentTranscriptItem* item in _transcript.items)
	{
		NSString* identifier = item.identifier;
		NSNumber* oldLength  = _renderedLengths[identifier];

		if(!oldLength || [_pendingIdentifiers containsObject:identifier])
		{
			NSAttributedString* rendered = [self renderItem:item];
			if(oldLength)
					[storage replaceCharactersInRange:NSMakeRange(location, oldLength.unsignedIntegerValue) withAttributedString:rendered];
			else	[storage insertAttributedString:rendered atIndex:location];

			_renderedLengths[identifier] = @(rendered.length);
		}
		location += _renderedLengths[identifier].unsignedIntegerValue;
	}

	[storage endEditing];
	[_pendingIdentifiers removeAllObjects];

	if(wasAtBottom)
		[self scrollRangeToVisible:NSMakeRange(storage.length, 0)];
	self.needsDisplay = YES;
}

- (void)reloadData
{
	[_renderedLengths removeAllObjects];
	[_codeBlocks removeAllObjects];
	[self.textStorage setAttributedString:[[NSAttributedString alloc] init]];

	for(AgentTranscriptItem* item in _transcript.items)
		[_pendingIdentifiers addObject:item.identifier];
	[self flushPendingItems];
	self.needsDisplay = YES;
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
		case AgentTranscriptItemKindNotice:   [res appendAttributedString:[self text:item.text font:SmallFont() color:NSColor.secondaryLabelColor]]; break;
		case AgentTranscriptItemKindError:    [res appendAttributedString:[self text:[@"⚠︎ " stringByAppendingString:item.text] font:SmallFont() color:NSColor.systemRedColor]]; break;
		case AgentTranscriptItemKindPermission: [self renderPermissionItem:item into:res]; break;
	}

	// End the item’s last paragraph, then a small spacer paragraph between items
	NSDictionary* lastAttributes = res.length ? [res attributesAtIndex:res.length - 1 effectiveRange:nullptr] : @{ };
	[res appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:lastAttributes]];
	[res appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:6] }]];
	return res;
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
	NSAttributedString* rendered = [OakMarkdownRenderer attributedStringFromMarkdown:item.text style:_markdownStyle codeBlocks:&codeBlocks codeBlockFooter:^NSAttributedString*(NSUInteger index){
		NSMutableAttributedString* footer = [[NSMutableAttributedString alloc] init];
		NSDictionary* parameters = @{ @"block": [NSString stringWithFormat:@"%lu", index] };
		[footer appendAttributedString:[self link:@"Copy" url:[self actionURL:@"copy" item:item parameters:parameters]]];
		[footer appendAttributedString:[self text:@"   " font:SmallFont() color:NSColor.secondaryLabelColor]];
		[footer appendAttributedString:[self link:@"Insert at Cursor" url:[self actionURL:@"insert" item:item parameters:parameters]]];
		[footer appendAttributedString:[self text:@"   " font:SmallFont() color:NSColor.secondaryLabelColor]];
		[footer appendAttributedString:[self link:@"Apply in Editor" url:[self actionURL:@"apply" item:item parameters:parameters]]];
		return footer;
	}];
	_codeBlocks[item.identifier] = codeBlocks;
	[res appendAttributedString:rendered];
}

- (void)renderThoughtItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	[res appendAttributedString:[self link:(item.expanded ? @"▾ Thinking" : @"▸ Thinking") url:[self actionURL:@"toggle" item:item parameters:@{ }]]];
	if(item.expanded && item.text.length)
		[res appendAttributedString:[self text:[@"\n" stringByAppendingString:item.text] font:SmallFont() color:NSColor.secondaryLabelColor]];
}

- (void)renderToolCallItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	NSDictionary* toolCall = item.toolCall;
	NSString* status       = toolCall[@"status"];
	NSString* title        = [toolCall[@"title"] isKindOfClass:[NSString class]] ? toolCall[@"title"] : @"Tool call";

	[res appendAttributedString:[self text:[ToolStatusGlyph(status) stringByAppendingString:@" "] font:SmallFont() color:ToolStatusColor(status)]];
	[res appendAttributedString:[self text:title font:[NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium] color:NSColor.labelColor]];

	[self appendDetailsOfToolCall:toolCall item:item into:res];
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
		[res appendAttributedString:[self link:title url:[self actionURL:@"open" item:item parameters:line ? @{ @"path": path, @"line": line } : @{ @"path": path }]]];
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
	[res appendAttributedString:[self text:@"\n    ✎ " font:SmallFont() color:NSColor.secondaryLabelColor]];
	if(path)
			[res appendAttributedString:[self link:path.lastPathComponent url:[self actionURL:@"open" item:item parameters:@{ @"path": path }]]];
	else	[res appendAttributedString:[self text:@"file" font:SmallFont() color:NSColor.labelColor]];
	if(!oldText)
		[res appendAttributedString:[self text:@"  new" font:SmallFont() color:NSColor.secondaryLabelColor]];
	[res appendAttributedString:[self text:[NSString stringWithFormat:@"  +%lu", diff.addedLineCount] font:SmallFont() color:NSColor.systemGreenColor]];
	[res appendAttributedString:[self text:[NSString stringWithFormat:@" −%lu", diff.removedLineCount] font:SmallFont() color:NSColor.systemRedColor]];
	[res appendAttributedString:[self text:@"   " font:SmallFont() color:NSColor.secondaryLabelColor]];
	[res appendAttributedString:[self link:@"Diff" url:[self actionURL:@"diff" item:item parameters:parameters]]];

	NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.firstLineHeadIndent = paragraph.headIndent = 20;

	NSUInteger shown = 0, total = 0;
	for(AgentDiffHunk* hunk in diff.hunks)
		total += hunk.lines.count;

	for(AgentDiffHunk* hunk in diff.hunks)
	{
		if(!item.expanded && shown >= kDiffPreviewLines)
			break;
		if(hunk != diff.hunks.firstObject)
			[res appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n⋯" attributes:@{ NSFontAttributeName: SmallMonospaceFont(), NSForegroundColorAttributeName: NSColor.tertiaryLabelColor, NSParagraphStyleAttributeName: paragraph }]];

		for(AgentDiffLine* line in hunk.lines)
		{
			if(!item.expanded && shown >= kDiffPreviewLines)
				break;
			++shown;

			NSString* prefix = line.kind == AgentDiffLineKindAdded ? @"+ " : (line.kind == AgentDiffLineKindRemoved ? @"− " : @"  ");
			NSColor* background = line.kind == AgentDiffLineKindAdded ? [NSColor.systemGreenColor colorWithAlphaComponent:0.15] : (line.kind == AgentDiffLineKindRemoved ? [NSColor.systemRedColor colorWithAlphaComponent:0.15] : nil);
			NSMutableDictionary* attributes = [NSMutableDictionary dictionaryWithDictionary:@{
				NSFontAttributeName:            SmallMonospaceFont(),
				NSForegroundColorAttributeName: line.kind == AgentDiffLineKindContext ? NSColor.secondaryLabelColor : NSColor.labelColor,
				NSParagraphStyleAttributeName:  paragraph,
			}];
			if(background)
				attributes[NSBackgroundColorAttributeName] = background;
			[res appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%@%@", prefix, line.text] attributes:attributes]];
		}
	}

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

- (void)renderPermissionItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	NSDictionary* toolCall = [self toolCallForItem:item];
	NSArray* options = [item.permissionRequest[@"options"] isKindOfClass:[NSArray class]] ? item.permissionRequest[@"options"] : @[ ];

	NSTextBlock* block = [[NSTextBlock alloc] init];
	block.backgroundColor = [(item.permissionResolved ? NSColor.secondaryLabelColor : NSColor.systemOrangeColor) colorWithAlphaComponent:0.12];
	[block setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth];
	[block setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
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
	[self appendDetailsOfToolCall:toolCall item:item into:card];
	[card appendAttributedString:[self text:@"\n" font:SmallFont() color:NSColor.labelColor]];

	if(!item.permissionResolved)
	{
		for(NSDictionary* option in options)
		{
			if(option != options.firstObject)
				[card appendAttributedString:[self text:@"     " font:SmallFont() color:NSColor.labelColor]];
			NSString* name = [NSString stringWithFormat:@"%@ %@", PermissionOptionGlyph(option[@"kind"]), option[@"name"] ?: option[@"optionId"]];
			NSMutableAttributedString* link = [[self link:name url:[self actionURL:@"permission" item:item parameters:@{ @"option": [option[@"optionId"] description] ?: @"" }]] mutableCopy];
			[link addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium] range:NSMakeRange(0, link.length)];
			[card appendAttributedString:link];
		}
	}
	else
	{
		NSDictionary* selected = nil;
		for(NSDictionary* option in options)
		{
			if([option[@"optionId"] isEqual:item.selectedOptionId])
				selected = option;
		}
		NSString* outcome = selected ? [NSString stringWithFormat:@"%@ %@", PermissionOptionGlyph(selected[@"kind"]), selected[@"name"] ?: selected[@"optionId"]] : @"– Cancelled";
		NSColor* color = [selected[@"kind"] hasPrefix:@"allow"] ? NSColor.systemGreenColor : ([selected[@"kind"] hasPrefix:@"reject"] ? NSColor.systemRedColor : NSColor.secondaryLabelColor);
		[card appendAttributedString:[self text:outcome font:SmallFont() color:color]];
	}

	[card addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, card.length)];
	[res appendAttributedString:card];
}

- (void)renderPlanItem:(AgentTranscriptItem*)item into:(NSMutableAttributedString*)res
{
	[res appendAttributedString:[self text:@"Plan" font:[NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold] color:NSColor.labelColor]];
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
	else if([action isEqualToString:@"open"] && parameters[@"path"])
	{
		if([_actionDelegate respondsToSelector:@selector(transcriptView:openFile:line:)])
			[_actionDelegate transcriptView:self openFile:PathFromURI(parameters[@"path"]) line:parameters[@"line"].integerValue];
	}
	return YES;
}
@end
