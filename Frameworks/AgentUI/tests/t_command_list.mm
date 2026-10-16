#import <AgentUI/AgentCommandList.h>

static NSArray<NSDictionary*>* const kCommands = @[
	@{ @"name": @"usage-credits", @"description": @"Credits" },
	@{ @"name": @"Usage", @"description": @"Show usage" },
	@{ @"name": @"review" },
	@{ @"name": @"" },
	@{ @"description": @"No name" },
];

static std::string Names (NSArray<NSDictionary*>* commands)
{
	return [[commands valueForKey:@"name"] componentsJoinedByString:@" "].UTF8String;
}

void test_matches_prefix ()
{
	OAK_ASSERT_EQ(Names((AgentSlashCommandsMatchingPrefix(kCommands, @"/"))), "review Usage usage-credits");
	OAK_ASSERT_EQ(Names((AgentSlashCommandsMatchingPrefix(kCommands, @"/us"))), "Usage usage-credits");
	OAK_ASSERT_EQ(Names((AgentSlashCommandsMatchingPrefix(kCommands, @"/rev"))), "review");
	OAK_ASSERT_EQ(AgentSlashCommandsMatchingPrefix(kCommands, @"/x").count, 0);
	OAK_ASSERT_EQ(AgentSlashCommandsMatchingPrefix(nil, @"/").count, 0);
}

void test_exact_match_first ()
{
	NSArray* commands = @[ @{ @"name": @"compact-all" }, @{ @"name": @"compact" }, @{ @"name": @"compact-a" } ];
	OAK_ASSERT_EQ(Names((AgentSlashCommandsMatchingPrefix(commands, @"/COMPACT"))), "compact compact-a compact-all");
	OAK_ASSERT_EQ(Names((AgentSlashCommandsMatchingPrefix(commands, @"/compact-a"))), "compact-a compact-all");
}
