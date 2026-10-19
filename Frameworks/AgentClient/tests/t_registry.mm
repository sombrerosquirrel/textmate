#import <AgentClient/AgentRegistry.h>
#import <AgentClient/AgentKeychain.h>

// Each test gets empty user defaults of its own.
struct test_defaults_t
{
	test_defaults_t ()
	{
		suiteName = [NSString stringWithFormat:@"com.macromates.TextMate.AgentClient.test.%@", NSUUID.UUID.UUIDString];
		defaults  = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
		AgentRegistry.userDefaults = defaults;
	}

	~test_defaults_t ()
	{
		AgentRegistry.userDefaults = nil;
		[defaults removePersistentDomainForName:suiteName];
	}

	NSString* suiteName;
	NSUserDefaults* defaults;
};

void test_command_line ()
{
	OAK_ASSERT([AgentArgumentsFromCommandLine(@"copilot --acp") isEqual:(@[ @"copilot", @"--acp" ])]);
	OAK_ASSERT([AgentArgumentsFromCommandLine(@"  a   b  ") isEqual:(@[ @"a", @"b" ])]);
	OAK_ASSERT([AgentArgumentsFromCommandLine(@"'/path with/space' \"x y\" a\\ b") isEqual:(@[ @"/path with/space", @"x y", @"a b" ])]);
	OAK_ASSERT([AgentArgumentsFromCommandLine(@"say \"it's\" 'a \"b\"'") isEqual:(@[ @"say", @"it's", @"a \"b\"" ])]);
	OAK_ASSERT([AgentArgumentsFromCommandLine(@"a '' b") isEqual:(@[ @"a", @"", @"b" ])]);
	OAK_ASSERT([AgentArgumentsFromCommandLine(@"a\tb\nc") isEqual:(@[ @"a", @"b", @"c" ])]);
	OAK_ASSERT([AgentArgumentsFromCommandLine(@"") isEqual:@[ ]]);
}

void test_default_agents ()
{
	test_defaults_t t;
	OAK_ASSERT([[AgentRegistry.agents valueForKey:@"identifier"] isEqual:(@[ @"copilot", @"claude" ])]);
	OAK_ASSERT([[AgentRegistry agentWithIdentifier:@"copilot"].arguments isEqual:@[ @"--acp" ]]);
	OAK_ASSERT([[AgentRegistry agentWithIdentifier:@"claude"].command isEqualToString:@"npx"]);
	OAK_ASSERT([[AgentRegistry agentWithIdentifier:@"claude"].apiKeyVariable isEqualToString:@"ANTHROPIC_API_KEY"]);
	OAK_ASSERT([AgentRegistry agentWithIdentifier:@"claude"].builtIn);
	OAK_ASSERT([AgentRegistry agentWithIdentifier:@"nonexistent"] == nil);
}

void test_edit_agents ()
{
	test_defaults_t t;

	AgentDescriptor* claude = [[AgentRegistry agentWithIdentifier:@"claude"] copy];
	claude.commandLine = @"/opt/claude-acp --debug";
	claude.environment = @{ @"DEBUG": @"1" };

	AgentDescriptor* gemini = [AgentRegistry makeAgent];
	gemini.name        = @"Gemini";
	gemini.commandLine = @"gemini --experimental-acp";
	OAK_ASSERT(!gemini.builtIn);

	// Copilot left out: built-in agents can’t be removed, it’s added back
	[AgentRegistry setAgents:@[ claude, gemini ]];
	OAK_ASSERT([[AgentRegistry.agents valueForKey:@"name"] isEqual:(@[ @"Claude Code", @"Gemini", @"GitHub Copilot" ])]);
	OAK_ASSERT([[AgentRegistry agentWithIdentifier:@"claude"].arguments isEqual:@[ @"--debug" ]]);
	OAK_ASSERT([[AgentRegistry agentWithIdentifier:@"claude"].environment isEqual:@{ @"DEBUG": @"1" }]);
	OAK_ASSERT([[AgentRegistry agentWithIdentifier:gemini.identifier].command isEqualToString:@"gemini"]);

	// Only changed settings of built-in agents are stored
	NSArray* stored = [t.defaults arrayForKey:kUserDefaultsAgentsKey];
	OAK_ASSERT(stored.firstObject[@"name"] == nil);
	OAK_ASSERT([stored.firstObject[@"command"] isEqualToString:@"/opt/claude-acp --debug"]);
	OAK_ASSERT([stored.lastObject isEqual:@{ @"identifier": @"copilot" }]);

	// Restoring the default
	[AgentRegistry setAgents:@[ [AgentRegistry defaultAgentWithIdentifier:@"claude"], gemini ]];
	OAK_ASSERT([[AgentRegistry agentWithIdentifier:@"claude"].commandLine isEqualToString:@"npx -y @agentclientprotocol/claude-agent-acp"]);

	// Removing a user agent; disabling a built-in one
	AgentDescriptor* copilot = [[AgentRegistry agentWithIdentifier:@"copilot"] copy];
	copilot.enabled = NO;
	[AgentRegistry setAgents:@[ copilot ]];
	OAK_ASSERT([[AgentRegistry.agents valueForKey:@"identifier"] isEqual:(@[ @"copilot", @"claude" ])]);
	OAK_ASSERT([[AgentRegistry.enabledAgents valueForKey:@"identifier"] isEqual:(@[ @"claude" ])]);
}

void test_new_agent_names ()
{
	test_defaults_t t;
	AgentDescriptor* first = [AgentRegistry makeAgent];
	OAK_ASSERT([first.name isEqualToString:@"New Agent"]);
	[AgentRegistry setAgents:[AgentRegistry.agents arrayByAddingObject:first]];
	AgentDescriptor* second = [AgentRegistry makeAgent];
	OAK_ASSERT([second.name isEqualToString:@"New Agent 2"]);
	OAK_ASSERT(![second.identifier isEqualToString:first.identifier]);
}

void test_project_overrides ()
{
	test_defaults_t t;
	AgentDescriptor* copilot = [[AgentRegistry agentWithIdentifier:@"copilot"] copy];
	copilot.enabled = NO;
	[AgentRegistry setAgents:@[ copilot ]];

	AgentDescriptor* chosen;
	NSArray<AgentDescriptor*>* agents = [AgentRegistry agentsForProjectWithAgentName:nil command:nil projectAgent:&chosen];
	OAK_ASSERT(chosen == nil);
	OAK_ASSERT([[agents valueForKey:@"identifier"] isEqual:(@[ @"claude" ])]);

	// By name or identifier, ignoring case; a disabled agent is included
	agents = [AgentRegistry agentsForProjectWithAgentName:@"github copilot" command:nil projectAgent:&chosen];
	OAK_ASSERT([chosen.identifier isEqualToString:@"copilot"]);
	OAK_ASSERT([[agents valueForKey:@"identifier"] isEqual:(@[ @"copilot", @"claude" ])]);
	[AgentRegistry agentsForProjectWithAgentName:@"CLAUDE" command:nil projectAgent:&chosen];
	OAK_ASSERT([chosen.identifier isEqualToString:@"claude"]);

	// agentCommand replaces the named agent’s command
	agents = [AgentRegistry agentsForProjectWithAgentName:@"Claude Code" command:@"./bin/agent --acp" projectAgent:&chosen];
	OAK_ASSERT([chosen.identifier isEqualToString:@"claude"]);
	OAK_ASSERT([chosen.commandLine isEqualToString:@"./bin/agent --acp"]);
	OAK_ASSERT(agents.firstObject == chosen);
	OAK_ASSERT([[AgentRegistry agentWithIdentifier:@"claude"].commandLine hasPrefix:@"npx"]); // not saved

	// … or adds a project agent
	agents = [AgentRegistry agentsForProjectWithAgentName:@"Local" command:@"local-agent" projectAgent:&chosen];
	OAK_ASSERT([chosen.name isEqualToString:@"Local"]);
	OAK_ASSERT([[agents valueForKey:@"name"] isEqual:(@[ @"Local", @"Claude Code" ])]);
	[AgentRegistry agentsForProjectWithAgentName:nil command:@"local-agent" projectAgent:&chosen];
	OAK_ASSERT([chosen.name isEqualToString:@"Project Agent"]);

	// An unknown name without a command is ignored
	[AgentRegistry agentsForProjectWithAgentName:@"Unknown" command:nil projectAgent:&chosen];
	OAK_ASSERT(chosen == nil);
}

void test_mcp_server_storage ()
{
	test_defaults_t t;
	OAK_ASSERT_EQ(AgentRegistry.MCPServers.count, 0);

	AgentMCPServer* server = [[AgentMCPServer alloc] initWithDictionary:@{ @"name": @"files", @"command": @"npx -y @modelcontextprotocol/server-filesystem /tmp" }];
	OAK_ASSERT([server.type isEqualToString:@"stdio"]);
	OAK_ASSERT(server.enabled);
	[AgentRegistry setMCPServers:@[ server ]];
	OAK_ASSERT([AgentRegistry.MCPServers isEqual:@[ server ]]);
}

void test_mcp_server_acp_representation ()
{
	NSDictionary* environment = @{ @"PATH": @"/usr/bin:/bin" };

	AgentMCPServer* stdio = [[AgentMCPServer alloc] initWithDictionary:@{ @"name": @"cat", @"command": @"cat -u 'a b'", @"variables": @{ @"B": @"2", @"A": @"1" } }];
	OAK_ASSERT([[stdio ACPRepresentationWithEnvironment:environment problem:nullptr] isEqual:(@{
		@"name": @"cat", @"command": @"/bin/cat", @"args": @[ @"-u", @"a b" ],
		@"env": @[ @{ @"name": @"A", @"value": @"1" }, @{ @"name": @"B", @"value": @"2" } ],
	})]);

	AgentMCPServer* http = [[AgentMCPServer alloc] initWithDictionary:@{ @"name": @"web", @"type": @"http", @"url": @"https://example.com/mcp", @"variables": @{ @"Authorization": @"Bearer x" } }];
	OAK_ASSERT([[http ACPRepresentationWithEnvironment:environment problem:nullptr] isEqual:(@{
		@"type": @"http", @"name": @"web", @"url": @"https://example.com/mcp",
		@"headers": @[ @{ @"name": @"Authorization", @"value": @"Bearer x" } ],
	})]);

	// Incomplete or not found, with the reason
	auto problem = [&](NSDictionary* dict) -> NSString* {
		NSString* res;
		OAK_ASSERT([[[AgentMCPServer alloc] initWithDictionary:dict] ACPRepresentationWithEnvironment:environment problem:&res] == nil);
		return res;
	};
	OAK_ASSERT([problem(@{ @"name": @"x", @"command": @"no-such-command-xyz" }) isEqualToString:@"“no-such-command-xyz” not found on your login shell’s PATH"]);
	OAK_ASSERT([problem(@{ @"name": @"x", @"type": @"sse" }) isEqualToString:@"no URL"]);
	OAK_ASSERT([problem(@{ @"command": @"cat" }) isEqualToString:@"no name"]);
	OAK_ASSERT([problem(@{ @"name": @"x" }) isEqualToString:@"no command"]);
	OAK_ASSERT([problem(@{ @"name": @"npx -y some-server" }) hasPrefix:@"no command (the command goes in"]);
}

void test_keychain ()
{
	NSString* previousService = AgentKeychain.service;
	AgentKeychain.service = [NSString stringWithFormat:@"TextMate AgentClient Test %@", NSUUID.UUID.UUIDString];

	NSError* error;
	if(![AgentKeychain setAPIKey:@"secret-1" forAgent:@"test" error:&error])
	{
		// No usable login Keychain (e.g. a locked Keychain over SSH)
		fprintf(stderr, "skipping Keychain test: %s\n", error.localizedDescription.UTF8String);
		AgentKeychain.service = previousService;
		return;
	}

	OAK_ASSERT([[AgentKeychain APIKeyForAgent:@"test"] isEqualToString:@"secret-1"]);
	OAK_ASSERT([AgentKeychain setAPIKey:@"secret-2" forAgent:@"test" error:nil]);
	OAK_ASSERT([[AgentKeychain APIKeyForAgent:@"test"] isEqualToString:@"secret-2"]);
	OAK_ASSERT([AgentKeychain APIKeyForAgent:@"other"] == nil);
	OAK_ASSERT([AgentKeychain setAPIKey:nil forAgent:@"test" error:nil]);
	OAK_ASSERT([AgentKeychain APIKeyForAgent:@"test"] == nil);
	OAK_ASSERT([AgentKeychain setAPIKey:@"" forAgent:@"test" error:nil]); // removing twice is fine

	AgentKeychain.service = previousService;
}
