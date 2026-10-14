#import "AgentTranscriptView.h"
#import "AgentMarkdown.h"
#import <OakAppKit/NSColor Additions.h>

static NSString* const kActionScheme      = @"textmate-agent";
static NSTimeInterval const kCoalesceDelay = 0.05;

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

static NSString* PathFromURI (NSString* uri)
{
	NSURL* url = [NSURL URLWithString:uri];
	return url.isFileURL ? url.path : uri;
}

@interface AgentTranscriptView () <NSTextViewDelegate>
{
	NSMutableDictionary<NSString*, NSNumber*>* _renderedLengths;
	NSMutableSet<NSString*>* _pendingIdentifiers;
	NSMutableDictionary<NSString*, NSArray<AgentMarkdownCodeBlock*>*>* _codeBlocks;
	BOOL _flushScheduled;
	AgentMarkdownStyle* _markdownStyle;
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
		_markdownStyle       = [AgentMarkdownStyle defaultStyle];

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
	NSArray<AgentMarkdownCodeBlock*>* codeBlocks;
	NSAttributedString* rendered = [AgentMarkdownRenderer attributedStringFromMarkdown:item.text style:_markdownStyle codeBlocks:&codeBlocks codeBlockFooter:^NSAttributedString*(NSUInteger index){
		NSMutableAttributedString* footer = [[NSMutableAttributedString alloc] init];
		NSDictionary* parameters = @{ @"block": [NSString stringWithFormat:@"%lu", index] };
		[footer appendAttributedString:[self link:@"Copy" url:[self actionURL:@"copy" item:item parameters:parameters]]];
		[footer appendAttributedString:[self text:@"   " font:SmallFont() color:NSColor.secondaryLabelColor]];
		[footer appendAttributedString:[self link:@"Insert at Cursor" url:[self actionURL:@"insert" item:item parameters:parameters]]];
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
			[res appendAttributedString:[self text:[NSString stringWithFormat:@"\n    Edit %@", [content[@"path"] lastPathComponent] ?: @"file"] font:SmallFont() color:NSColor.secondaryLabelColor]];
		}
		else if([type isEqualToString:@"terminal"])
		{
			[res appendAttributedString:[self text:@"\n    Terminal" font:SmallFont() color:NSColor.secondaryLabelColor]];
		}
		else if([type isEqualToString:@"content"] && [content[@"content"][@"type"] isEqualToString:@"text"])
		{
			// A short preview; the full output view is part of milestone M3
			NSArray* lines = [content[@"content"][@"text"] componentsSeparatedByString:@"\n"];
			NSString* preview = [[lines subarrayWithRange:NSMakeRange(0, MIN(lines.count, 6))] componentsJoinedByString:@"\n    "];
			if(lines.count > 6)
				preview = [preview stringByAppendingFormat:@"\n    … %lu more lines", lines.count - 6];
			[res appendAttributedString:[self text:[@"\n    " stringByAppendingString:preview] font:SmallMonospaceFont() color:NSColor.secondaryLabelColor]];
		}
	}
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

	if([action isEqualToString:@"copy"] || [action isEqualToString:@"insert"])
	{
		NSArray<AgentMarkdownCodeBlock*>* codeBlocks = _codeBlocks[parameters[@"item"]];
		NSUInteger index = parameters[@"block"].integerValue;
		if(index >= codeBlocks.count)
			return YES;

		NSString* code = codeBlocks[index].code;
		if([action isEqualToString:@"copy"])
		{
			[NSPasteboard.generalPasteboard clearContents];
			[NSPasteboard.generalPasteboard setString:code forType:NSPasteboardTypeString];
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
	else if([action isEqualToString:@"open"] && parameters[@"path"])
	{
		if([_actionDelegate respondsToSelector:@selector(transcriptView:openFile:line:)])
			[_actionDelegate transcriptView:self openFile:PathFromURI(parameters[@"path"]) line:parameters[@"line"].integerValue];
	}
	return YES;
}
@end
