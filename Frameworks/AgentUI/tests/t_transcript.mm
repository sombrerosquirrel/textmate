#import <AgentUI/AgentTranscript.h>

static NSDictionary* Chunk (NSString* kind, NSString* text, NSString* messageId = nil)
{
	NSMutableDictionary* res = [NSMutableDictionary dictionaryWithDictionary:@{ @"sessionUpdate": kind, @"content": @{ @"type": @"text", @"text": text } }];
	if(messageId)
		res[@"messageId"] = messageId;
	return res;
}

void test_message_chunks ()
{
	AgentTranscript* transcript = [[AgentTranscript alloc] init];
	AgentTranscriptItem* first = [transcript applyUpdate:Chunk(@"agent_message_chunk", @"Hello, ")];
	AgentTranscriptItem* again = [transcript applyUpdate:Chunk(@"agent_message_chunk", @"world")];
	OAK_ASSERT(first == again);
	OAK_ASSERT([first.text isEqualToString:@"Hello, world"]);
	OAK_ASSERT_EQ(transcript.items.count, 1);
	OAK_ASSERT_EQ((NSInteger)first.kind, (NSInteger)AgentTranscriptItemKindAgent);
}

void test_message_ids_split_messages ()
{
	AgentTranscript* transcript = [[AgentTranscript alloc] init];
	[transcript applyUpdate:Chunk(@"agent_message_chunk", @"one", @"m1")];
	[transcript applyUpdate:Chunk(@"agent_message_chunk", @" more", @"m1")];
	[transcript applyUpdate:Chunk(@"agent_message_chunk", @"two", @"m2")];
	OAK_ASSERT_EQ(transcript.items.count, 2);
	OAK_ASSERT([transcript.items[0].text isEqualToString:@"one more"]);
	OAK_ASSERT([transcript.items[1].text isEqualToString:@"two"]);
}

void test_thinking_and_tool_calls_interleave ()
{
	AgentTranscript* transcript = [[AgentTranscript alloc] init];
	[transcript addUserMessage:@"Fix it" attachmentNames:@[ @"main.cc" ]];
	[transcript applyUpdate:Chunk(@"agent_thought_chunk", @"Let me look")];
	[transcript applyUpdate:@{ @"sessionUpdate": @"tool_call", @"toolCallId": @"t1", @"title": @"Read main.cc", @"kind": @"read", @"status": @"pending" }];
	[transcript applyUpdate:Chunk(@"agent_message_chunk", @"Found it")];
	AgentTranscriptItem* tool = [transcript applyUpdate:@{ @"sessionUpdate": @"tool_call_update", @"toolCallId": @"t1", @"status": @"completed" }];

	NSArray<AgentTranscriptItem*>* items = transcript.items;
	OAK_ASSERT_EQ(items.count, 4);
	OAK_ASSERT_EQ((NSInteger)items[0].kind, (NSInteger)AgentTranscriptItemKindUser);
	OAK_ASSERT([items[0].attachmentNames isEqual:@[ @"main.cc" ]]);
	OAK_ASSERT_EQ((NSInteger)items[1].kind, (NSInteger)AgentTranscriptItemKindThought);
	OAK_ASSERT_EQ((NSInteger)items[2].kind, (NSInteger)AgentTranscriptItemKindToolCall);
	OAK_ASSERT_EQ((NSInteger)items[3].kind, (NSInteger)AgentTranscriptItemKindAgent);

	// The update merged into the existing tool call
	OAK_ASSERT(tool == items[2]);
	OAK_ASSERT([tool.toolCall[@"status"] isEqualToString:@"completed"]);
	OAK_ASSERT([tool.toolCall[@"title"] isEqualToString:@"Read main.cc"]);
}

void test_plan_updates_in_place_per_turn ()
{
	AgentTranscript* transcript = [[AgentTranscript alloc] init];
	[transcript addUserMessage:@"first" attachmentNames:nil];
	AgentTranscriptItem* plan = [transcript applyUpdate:@{ @"sessionUpdate": @"plan", @"entries": @[ @{ @"content": @"a", @"status": @"pending" } ] }];
	[transcript applyUpdate:Chunk(@"agent_message_chunk", @"working")];
	AgentTranscriptItem* updated = [transcript applyUpdate:@{ @"sessionUpdate": @"plan", @"entries": @[ @{ @"content": @"a", @"status": @"completed" } ] }];
	OAK_ASSERT(plan == updated);
	OAK_ASSERT([plan.planEntries[0][@"status"] isEqualToString:@"completed"]);

	// A new turn gets its own plan
	[transcript addUserMessage:@"second" attachmentNames:nil];
	AgentTranscriptItem* next = [transcript applyUpdate:@{ @"sessionUpdate": @"plan", @"entries": @[ ] }];
	OAK_ASSERT(next != plan);
}

void test_ignored_updates ()
{
	AgentTranscript* transcript = [[AgentTranscript alloc] init];
	OAK_ASSERT(([transcript applyUpdate:@{ @"sessionUpdate": @"available_commands_update", @"availableCommands": @[ ] }] == nil));
	OAK_ASSERT(([transcript applyUpdate:@{ @"sessionUpdate": @"usage_update", @"used": @1, @"size": @2 }] == nil));
	OAK_ASSERT(([transcript applyUpdate:@{ @"sessionUpdate": @"tool_call" }] == nil)); // no id
	OAK_ASSERT_EQ(transcript.items.count, 0);
}

void test_non_text_content ()
{
	AgentTranscript* transcript = [[AgentTranscript alloc] init];
	AgentTranscriptItem* item = [transcript applyUpdate:@{ @"sessionUpdate": @"agent_message_chunk", @"content": @{ @"type": @"resource_link", @"uri": @"file:///a", @"name": @"a.txt" } }];
	OAK_ASSERT([item.text isEqualToString:@"[a.txt]"]);
}

void test_identifiers_are_unique ()
{
	AgentTranscript* transcript = [[AgentTranscript alloc] init];
	AgentTranscriptItem* a = [transcript addNotice:@"a"];
	AgentTranscriptItem* b = [transcript addError:@"b"];
	OAK_ASSERT(![a.identifier isEqualToString:b.identifier]);
	[transcript removeAllItems];
	OAK_ASSERT_EQ(transcript.items.count, 0);
	AgentTranscriptItem* c = [transcript addNotice:@"c"];
	OAK_ASSERT(![c.identifier isEqualToString:a.identifier]);
}
