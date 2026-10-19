#import <AgentUI/AgentLog.h>

void test_log_summaries ()
{
	AgentLog* log = [[AgentLog alloc] init];
	[log addMessage:@{ @"jsonrpc": @"2.0", @"id": @3, @"method": @"session/prompt", @"params": @{ } } outgoing:YES source:@"p — A"];
	[log addMessage:@{ @"jsonrpc": @"2.0", @"method": @"session/update", @"params": @{ @"update": @{ @"sessionUpdate": @"agent_message_chunk" } } } outgoing:NO source:@"p — A"];
	[log addMessage:@{ @"jsonrpc": @"2.0", @"id": @3, @"result": @{ @"stopReason": @"end_turn" } } outgoing:NO source:@"p — A"];
	[log addMessage:@{ @"jsonrpc": @"2.0", @"id": @4, @"error": @{ @"code": @-32000, @"message": @"Authentication required" } } outgoing:NO source:@"p — B"];
	[log addStandardError:@"warning: something\n" source:@"p — B"];
	[log addStandardError:@"\n" source:@"p — B"];
	[log addEvent:@"Exited with status 1" source:@"p — B"];

	OAK_ASSERT_EQ(log.entries.count, 6);
	OAK_ASSERT([log.entries[0].summary isEqual:@"→ session/prompt #3"]);
	OAK_ASSERT([log.entries[1].summary isEqual:@"← session/update agent_message_chunk"]);
	OAK_ASSERT([log.entries[2].summary isEqual:@"← result #3"]);
	OAK_ASSERT([log.entries[3].summary isEqual:@"← error #4"]);
	OAK_ASSERT([log.entries[4].summary isEqual:@"stderr"]);
	OAK_ASSERT([[log.entries[4] detailWithLimit:0] isEqual:@"warning: something"]);
	OAK_ASSERT([log.entries[5].summary isEqual:@"Exited with status 1"]);
	OAK_ASSERT([log.entries[5] detailWithLimit:0] == nil);
	OAK_ASSERT([log.sources isEqual:(@[ @"p — A", @"p — B" ])]);
	OAK_ASSERT(log.entries[0].serialNumber < log.entries[1].serialNumber);
}

void test_log_detail_and_search ()
{
	AgentLog* log = [[AgentLog alloc] init];
	[log addMessage:@{ @"id": @1, @"result": @{ @"text": @"Hello World" } } outgoing:NO source:@"x"];
	AgentLogEntry* entry = log.entries.firstObject;
	OAK_ASSERT([[entry detailWithLimit:0] isEqual:@"{\"id\":1,\"result\":{\"text\":\"Hello World\"}}"]);
	OAK_ASSERT([[entry detailWithLimit:5] hasPrefix:@"{\"id\"…"]);
	OAK_ASSERT([entry matchesSearchString:@"hello world"]);
	OAK_ASSERT([entry matchesSearchString:@"result"]);
	OAK_ASSERT([entry matchesSearchString:@""]);
	OAK_ASSERT(![entry matchesSearchString:@"goodbye"]);
}

void test_log_trimming ()
{
	AgentLog* log = [[AgentLog alloc] init];
	log.maximumEntries = 10;
	for(NSUInteger i = 0; i < 25; ++i)
		[log addEvent:[NSString stringWithFormat:@"%lu", i] source:@"x"];
	OAK_ASSERT(log.entries.count >= 10 && log.entries.count <= 11);
	OAK_ASSERT([log.entries.lastObject.text isEqual:@"24"]);

	[log clear];
	OAK_ASSERT_EQ(log.entries.count, 0);
}
