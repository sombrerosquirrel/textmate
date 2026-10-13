#import "AgentTranscript.h"

static NSString* TextOfContentBlock (NSDictionary* content)
{
	if(![content isKindOfClass:[NSDictionary class]])
		return @"";

	NSString* type = content[@"type"];
	if([type isEqualToString:@"text"])
		return [content[@"text"] isKindOfClass:[NSString class]] ? content[@"text"] : @"";
	if([type isEqualToString:@"image"])
		return @"[image]";
	if([type isEqualToString:@"audio"])
		return @"[audio]";
	if([type isEqualToString:@"resource_link"])
		return [NSString stringWithFormat:@"[%@]", content[@"name"] ?: content[@"uri"] ?: @"resource"];
	if([type isEqualToString:@"resource"])
		return [NSString stringWithFormat:@"[%@]", content[@"resource"][@"uri"] ?: @"resource"];
	return @"";
}

@interface AgentTranscriptItem ()
@property (nonatomic, readwrite) AgentTranscriptItemKind kind;
@property (nonatomic, readwrite) NSString* identifier;
@property (nonatomic, readwrite) NSString* messageId;
@property (nonatomic, readwrite) NSMutableString* mutableText;
@property (nonatomic, readwrite) NSArray<NSString*>* attachmentNames;
@property (nonatomic, readwrite) NSMutableDictionary* mutableToolCall;
@property (nonatomic, readwrite) NSArray<NSDictionary*>* planEntries;
@end

@implementation AgentTranscriptItem
- (NSString*)text            { return [_mutableText copy] ?: @""; }
- (NSDictionary*)toolCall    { return [_mutableToolCall copy]; }
@end

@interface AgentTranscript ()
{
	NSMutableArray<AgentTranscriptItem*>* _items;
	NSUInteger _nextIdentifier;
}
@end

@implementation AgentTranscript
- (instancetype)init
{
	if(self = [super init])
		_items = [NSMutableArray array];
	return self;
}

- (NSArray<AgentTranscriptItem*>*)items
{
	return [_items copy];
}

- (AgentTranscriptItem*)addItemOfKind:(AgentTranscriptItemKind)kind text:(NSString*)text
{
	AgentTranscriptItem* item = [[AgentTranscriptItem alloc] init];
	item.kind        = kind;
	item.identifier  = [NSString stringWithFormat:@"%lu", ++_nextIdentifier];
	item.mutableText = [NSMutableString stringWithString:text ?: @""];
	[_items addObject:item];
	return item;
}

- (AgentTranscriptItem*)addUserMessage:(NSString*)text attachmentNames:(NSArray<NSString*>*)attachmentNames
{
	AgentTranscriptItem* item = [self addItemOfKind:AgentTranscriptItemKindUser text:text];
	item.attachmentNames = attachmentNames ?: @[ ];
	return item;
}

- (AgentTranscriptItem*)addNotice:(NSString*)text { return [self addItemOfKind:AgentTranscriptItemKindNotice text:text]; }
- (AgentTranscriptItem*)addError:(NSString*)text  { return [self addItemOfKind:AgentTranscriptItemKindError text:text]; }

- (void)removeAllItems
{
	[_items removeAllObjects];
}

// Chunks extend the last item when it’s of the same kind and message; anything
// in between (e.g. a tool call) starts a new item.
- (AgentTranscriptItem*)appendChunk:(NSDictionary*)update kind:(AgentTranscriptItemKind)kind
{
	NSString* messageId = [update[@"messageId"] isKindOfClass:[NSString class]] ? update[@"messageId"] : nil;
	NSString* text      = TextOfContentBlock(update[@"content"]);

	AgentTranscriptItem* last = _items.lastObject;
	if(last && last.kind == kind && (messageId == last.messageId || [messageId isEqualToString:last.messageId]))
	{
		[last.mutableText appendString:text];
		return last;
	}

	AgentTranscriptItem* item = [self addItemOfKind:kind text:text];
	item.messageId = messageId;
	return item;
}

- (AgentTranscriptItem*)toolCallItemWithIdentifier:(NSString*)toolCallId
{
	for(AgentTranscriptItem* item in _items.reverseObjectEnumerator)
	{
		if(item.kind == AgentTranscriptItemKindToolCall && [item.mutableToolCall[@"toolCallId"] isEqual:toolCallId])
			return item;
	}
	return nil;
}

- (AgentTranscriptItem*)applyUpdate:(NSDictionary*)update
{
	NSString* kind = update[@"sessionUpdate"];
	if([kind isEqualToString:@"agent_message_chunk"])
		return [self appendChunk:update kind:AgentTranscriptItemKindAgent];
	if([kind isEqualToString:@"agent_thought_chunk"])
		return [self appendChunk:update kind:AgentTranscriptItemKindThought];
	if([kind isEqualToString:@"user_message_chunk"])
		return [self appendChunk:update kind:AgentTranscriptItemKindUser];

	if([kind isEqualToString:@"tool_call"] || [kind isEqualToString:@"tool_call_update"])
	{
		id toolCallId = update[@"toolCallId"];
		if(!toolCallId)
			return nil;

		AgentTranscriptItem* item = [self toolCallItemWithIdentifier:toolCallId];
		if(!item)
		{
			item = [self addItemOfKind:AgentTranscriptItemKindToolCall text:nil];
			item.mutableToolCall = [NSMutableDictionary dictionary];
		}

		for(NSString* key in update)
		{
			if(![key isEqualToString:@"sessionUpdate"] && update[key] != [NSNull null])
				item.mutableToolCall[key] = update[key];
		}
		return item;
	}

	if([kind isEqualToString:@"plan"])
	{
		NSArray* entries = [update[@"entries"] isKindOfClass:[NSArray class]] ? update[@"entries"] : @[ ];

		// The agent always sends the complete plan; update the current turn’s plan in place
		for(AgentTranscriptItem* item in _items.reverseObjectEnumerator)
		{
			if(item.kind == AgentTranscriptItemKindUser)
				break;
			if(item.kind == AgentTranscriptItemKindPlan)
			{
				item.planEntries = entries;
				return item;
			}
		}

		AgentTranscriptItem* item = [self addItemOfKind:AgentTranscriptItemKindPlan text:nil];
		item.planEntries = entries;
		return item;
	}

	return nil;
}
@end
