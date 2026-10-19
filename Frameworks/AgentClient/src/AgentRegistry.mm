#import "AgentRegistry.h"
#import "AgentEnvironment.h"
#import "AgentKeychain.h"

NSString* const kUserDefaultsAgentsKey          = @"agents";
NSString* const kUserDefaultsAgentMCPServersKey = @"agentMCPServers";

NSNotificationName const AgentRegistryDidChangeNotification = @"AgentRegistryDidChangeNotification";

NSArray<NSString*>* AgentArgumentsFromCommandLine (NSString* commandLine)
{
	NSMutableArray<NSString*>* res = [NSMutableArray array];
	NSMutableString* word = nil;

	BOOL escape = NO, singleQuoted = NO, doubleQuoted = NO;
	for(NSUInteger i = 0; i < commandLine.length; )
	{
		NSRange range = [commandLine rangeOfComposedCharacterSequenceAtIndex:i];
		NSString* ch = [commandLine substringWithRange:range];
		i = NSMaxRange(range);

		if(!escape && [ch isEqualToString:@"'"] && !doubleQuoted)
			singleQuoted = !singleQuoted;
		else if(!escape && !singleQuoted && [ch isEqualToString:@"\""])
			doubleQuoted = !doubleQuoted;
		else if(!escape && !singleQuoted && [ch isEqualToString:@"\\"])
			escape = YES;
		else if(!escape && !singleQuoted && !doubleQuoted && ([ch isEqualToString:@" "] || [ch isEqualToString:@"\t"] || [ch isEqualToString:@"\n"]))
		{
			if(word)
				[res addObject:word];
			word = nil;
			continue;
		}
		else
		{
			escape = NO;
			if(!word)
				word = [NSMutableString string];
			[word appendString:ch];
			continue;
		}

		if(!word) // quotes start a word, even an empty one
			word = [NSMutableString string];
	}
	if(word)
		[res addObject:word];
	return res;
}

static NSDictionary<NSString*, NSString*>* StringDictionary (id value)
{
	if(![value isKindOfClass:[NSDictionary class]])
		return @{ };
	NSMutableDictionary* res = [NSMutableDictionary dictionary];
	for(id key in value)
	{
		if([key isKindOfClass:[NSString class]] && [value[key] isKindOfClass:[NSString class]])
			res[key] = value[key];
	}
	return res;
}

static NSString* StringValue (id value)
{
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL BoolValue (id value, BOOL defaultValue)
{
	return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : defaultValue;
}

// ===================
// = AgentDescriptor =
// ===================

static NSArray<NSDictionary*>* DefaultAgentDictionaries ()
{
	return @[
		@{ @"identifier": @"copilot", @"name": @"GitHub Copilot", @"command": @"copilot --acp",                                @"apiKeyVariable": @"COPILOT_GITHUB_TOKEN" },
		@{ @"identifier": @"claude",  @"name": @"Claude Code",    @"command": @"npx -y @agentclientprotocol/claude-agent-acp", @"apiKeyVariable": @"ANTHROPIC_API_KEY"    },
	];
}

@implementation AgentDescriptor
- (instancetype)initWithDictionary:(NSDictionary*)dictionary
{
	if(self = [super init])
	{
		_identifier     = StringValue(dictionary[@"identifier"]) ?: [NSString stringWithFormat:@"agent-%@", NSUUID.UUID.UUIDString.lowercaseString];
		_name           = StringValue(dictionary[@"name"]) ?: @"Untitled Agent";
		_commandLine    = StringValue(dictionary[@"command"]) ?: @"";
		_environment    = StringDictionary(dictionary[@"environment"]);
		_enabled        = BoolValue(dictionary[@"enabled"], YES);
		_apiKeyVariable = StringValue(dictionary[@"apiKeyVariable"]) ?: @"";
		_usesAPIKey     = BoolValue(dictionary[@"usesAPIKey"], NO);
		_builtIn        = [[DefaultAgentDictionaries() valueForKey:@"identifier"] containsObject:_identifier];
	}
	return self;
}

- (instancetype)initWithIdentifier:(NSString*)identifier name:(NSString*)name commandLine:(NSString*)commandLine
{
	return [self initWithDictionary:@{ @"identifier": identifier, @"name": name, @"command": commandLine }];
}

- (id)copyWithZone:(NSZone*)zone
{
	return [[AgentDescriptor alloc] initWithDictionary:self.dictionaryRepresentation];
}

- (NSDictionary*)dictionaryRepresentation
{
	return @{
		@"identifier":     _identifier,
		@"name":           _name,
		@"command":        _commandLine,
		@"environment":    _environment,
		@"enabled":        @(_enabled),
		@"apiKeyVariable": _apiKeyVariable,
		@"usesAPIKey":     @(_usesAPIKey),
	};
}

- (BOOL)isEqual:(id)other
{
	return [other isKindOfClass:[AgentDescriptor class]] && [self.dictionaryRepresentation isEqual:[other dictionaryRepresentation]];
}

- (NSUInteger)hash
{
	return _identifier.hash;
}

- (NSString*)command
{
	return [AgentArgumentsFromCommandLine(_commandLine).firstObject stringByExpandingTildeInPath] ?: @"";
}

- (NSArray<NSString*>*)arguments
{
	NSArray* words = AgentArgumentsFromCommandLine(_commandLine);
	return words.count > 1 ? [words subarrayWithRange:NSMakeRange(1, words.count - 1)] : @[ ];
}

- (NSString*)description
{
	return [NSString stringWithFormat:@"<%@ %@: %@>", self.class, _identifier, _commandLine];
}
@end

// ==================
// = AgentMCPServer =
// ==================

@implementation AgentMCPServer
- (instancetype)initWithDictionary:(NSDictionary*)dictionary
{
	if(self = [super init])
	{
		_name        = StringValue(dictionary[@"name"]) ?: @"";
		_type        = StringValue(dictionary[@"type"]) ?: @"stdio";
		_commandLine = StringValue(dictionary[@"command"]) ?: @"";
		_url         = StringValue(dictionary[@"url"]) ?: @"";
		_variables   = StringDictionary(dictionary[@"variables"]);
		_enabled     = BoolValue(dictionary[@"enabled"], YES);
	}
	return self;
}

- (id)copyWithZone:(NSZone*)zone
{
	return [[AgentMCPServer alloc] initWithDictionary:self.dictionaryRepresentation];
}

- (NSDictionary*)dictionaryRepresentation
{
	return @{
		@"name":      _name,
		@"type":      _type,
		@"command":   _commandLine,
		@"url":       _url,
		@"variables": _variables,
		@"enabled":   @(_enabled),
	};
}

- (BOOL)isEqual:(id)other
{
	return [other isKindOfClass:[AgentMCPServer class]] && [self.dictionaryRepresentation isEqual:[other dictionaryRepresentation]];
}

- (NSUInteger)hash
{
	return _name.hash;
}

// ACP sends environment variables and headers as [{ name, value }]
static NSArray<NSDictionary*>* NameValuePairs (NSDictionary<NSString*, NSString*>* dictionary)
{
	NSMutableArray* res = [NSMutableArray array];
	for(NSString* key in [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)])
		[res addObject:@{ @"name": key, @"value": dictionary[key] }];
	return res;
}

- (NSDictionary*)ACPRepresentationWithEnvironment:(NSDictionary<NSString*, NSString*>*)environment problem:(NSString**)problem
{
	NSString* reason = nil;
	NSDictionary* res = [self ACPRepresentationWithEnvironment:environment reason:&reason];
	if(problem)
		*problem = reason;
	return res;
}

- (NSDictionary*)ACPRepresentationWithEnvironment:(NSDictionary<NSString*, NSString*>*)environment reason:(NSString**)reason
{
	if(!_name.length)
		return *reason = @"no name", nil;

	if([_type isEqualToString:@"http"] || [_type isEqualToString:@"sse"])
	{
		if(!_url.length)
			return *reason = @"no URL", nil;
		return @{ @"type": _type, @"name": _name, @"url": _url, @"headers": NameValuePairs(_variables) };
	}

	NSArray<NSString*>* words = AgentArgumentsFromCommandLine(_commandLine);
	if(!words.count)
	{
		// A name with blanks is likely the command typed into the wrong column
		*reason = [_name rangeOfString:@" "].location != NSNotFound ? @"no command (the command goes in the Command or URL column, not Name)" : @"no command";
		return nil;
	}
	NSString* executable = [AgentEnvironment executablePathForCommand:[words.firstObject stringByExpandingTildeInPath] environment:environment];
	if(!executable)
		return *reason = [NSString stringWithFormat:@"“%@” not found on your login shell’s PATH", words.firstObject], nil;
	return @{ @"name": _name, @"command": executable, @"args": [words subarrayWithRange:NSMakeRange(1, words.count - 1)], @"env": NameValuePairs(_variables) };
}
@end

// =================
// = AgentRegistry =
// =================

static NSUserDefaults* RegistryDefaults = nil;

@implementation AgentRegistry
+ (NSUserDefaults*)userDefaults                   { return RegistryDefaults ?: NSUserDefaults.standardUserDefaults; }
+ (void)setUserDefaults:(NSUserDefaults*)defaults { RegistryDefaults = defaults; }

+ (NSArray<AgentDescriptor*>*)defaultAgents
{
	NSMutableArray* res = [NSMutableArray array];
	for(NSDictionary* dict in DefaultAgentDictionaries())
		[res addObject:[[AgentDescriptor alloc] initWithDictionary:dict]];
	return res;
}

+ (AgentDescriptor*)defaultAgentWithIdentifier:(NSString*)identifier
{
	for(AgentDescriptor* agent in self.defaultAgents)
	{
		if([agent.identifier isEqualToString:identifier])
			return agent;
	}
	return nil;
}

// Stored built-in agents keep only the settings the user changed, so a new
// default (e.g. a renamed package) reaches everyone who didn’t change it.
+ (NSArray<AgentDescriptor*>*)agents
{
	NSMutableArray<AgentDescriptor*>* res = [NSMutableArray array];
	NSMutableSet<NSString*>* identifiers  = [NSMutableSet set];

	id stored = [self.userDefaults arrayForKey:kUserDefaultsAgentsKey];
	for(NSDictionary* dict in [stored isKindOfClass:[NSArray class]] ? stored : @[ ])
	{
		if(![dict isKindOfClass:[NSDictionary class]] || ![StringValue(dict[@"identifier"]) length] || [identifiers containsObject:dict[@"identifier"]])
			continue;

		NSMutableDictionary* merged = [NSMutableDictionary dictionary];
		if(AgentDescriptor* builtIn = [self defaultAgentWithIdentifier:dict[@"identifier"]])
			[merged addEntriesFromDictionary:builtIn.dictionaryRepresentation];
		[merged addEntriesFromDictionary:dict];

		AgentDescriptor* agent = [[AgentDescriptor alloc] initWithDictionary:merged];
		[res addObject:agent];
		[identifiers addObject:agent.identifier];
	}

	for(AgentDescriptor* agent in self.defaultAgents)
	{
		if(![identifiers containsObject:agent.identifier])
			[res addObject:agent];
	}
	return res;
}

+ (NSArray<AgentDescriptor*>*)enabledAgents
{
	return [self.agents filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"enabled == YES"]];
}

+ (AgentDescriptor*)agentWithIdentifier:(NSString*)identifier
{
	for(AgentDescriptor* agent in self.agents)
	{
		if([agent.identifier isEqualToString:identifier])
			return agent;
	}
	return nil;
}

+ (void)setAgents:(NSArray<AgentDescriptor*>*)agents
{
	NSMutableArray* stored = [NSMutableArray array];
	NSMutableSet<NSString*>* identifiers = [NSMutableSet set];
	for(AgentDescriptor* agent in agents)
	{
		if([identifiers containsObject:agent.identifier])
			continue;
		[identifiers addObject:agent.identifier];

		NSMutableDictionary* dict = [agent.dictionaryRepresentation mutableCopy];
		if(AgentDescriptor* builtIn = [self defaultAgentWithIdentifier:agent.identifier])
		{
			NSDictionary* defaults = builtIn.dictionaryRepresentation;
			for(NSString* key in defaults)
			{
				if(![key isEqualToString:@"identifier"] && [dict[key] isEqual:defaults[key]])
					[dict removeObjectForKey:key];
			}
		}
		[stored addObject:dict];
	}

	for(AgentDescriptor* agent in self.defaultAgents)
	{
		if(![identifiers containsObject:agent.identifier])
			[stored addObject:@{ @"identifier": agent.identifier }];
	}

	[self.userDefaults setObject:stored forKey:kUserDefaultsAgentsKey];
	[NSNotificationCenter.defaultCenter postNotificationName:AgentRegistryDidChangeNotification object:self];
}

+ (AgentDescriptor*)makeAgent
{
	NSSet* names = [NSSet setWithArray:[self.agents valueForKey:@"name"]];
	NSString* name = @"New Agent";
	for(NSUInteger i = 2; [names containsObject:name]; ++i)
		name = [NSString stringWithFormat:@"New Agent %lu", i];
	return [[AgentDescriptor alloc] initWithDictionary:@{ @"name": name }];
}

+ (NSArray<AgentDescriptor*>*)agentsForProjectWithAgentName:(NSString*)agentName command:(NSString*)agentCommand projectAgent:(AgentDescriptor**)projectAgent
{
	agentName    = [agentName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	agentCommand = [agentCommand stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];

	NSArray<AgentDescriptor*>* agents = self.agents;
	AgentDescriptor* named = nil;
	if(agentName.length)
	{
		for(AgentDescriptor* agent in agents)
		{
			if([agent.name caseInsensitiveCompare:agentName] == NSOrderedSame || [agent.identifier caseInsensitiveCompare:agentName] == NSOrderedSame)
			{
				named = agent;
				break;
			}
		}
	}

	NSMutableArray<AgentDescriptor*>* res = [NSMutableArray array];
	for(AgentDescriptor* agent in agents)
	{
		if(agent.enabled || agent == named)
			[res addObject:agent];
	}

	AgentDescriptor* chosen = named;
	if(agentCommand.length)
	{
		if(named)
		{
			chosen = [named copy];
			chosen.commandLine = agentCommand;
			res[[res indexOfObject:named]] = chosen;
		}
		else
		{
			chosen = [[AgentDescriptor alloc] initWithIdentifier:@"project" name:(agentName.length ? agentName : @"Project Agent") commandLine:agentCommand];
			[res insertObject:chosen atIndex:0];
		}
	}

	if(projectAgent)
		*projectAgent = chosen;
	return res;
}

+ (NSArray<AgentMCPServer*>*)MCPServers
{
	NSMutableArray* res = [NSMutableArray array];
	id stored = [self.userDefaults arrayForKey:kUserDefaultsAgentMCPServersKey];
	for(NSDictionary* dict in [stored isKindOfClass:[NSArray class]] ? stored : @[ ])
	{
		if([dict isKindOfClass:[NSDictionary class]])
			[res addObject:[[AgentMCPServer alloc] initWithDictionary:dict]];
	}
	return res;
}

+ (void)setMCPServers:(NSArray<AgentMCPServer*>*)servers
{
	[self.userDefaults setObject:[servers valueForKey:@"dictionaryRepresentation"] forKey:kUserDefaultsAgentMCPServersKey];
	[NSNotificationCenter.defaultCenter postNotificationName:AgentRegistryDidChangeNotification object:self];
}

+ (void)makeSessionForAgent:(AgentDescriptor*)agent workingDirectory:(NSString*)workingDirectory completion:(void(^)(AgentSession* session, NSError* error))completion
{
	agent = [agent copy];
	NSArray<AgentMCPServer*>* servers = [self.MCPServers filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"enabled == YES"]];

	[AgentEnvironment loadLoginShellEnvironmentWithCompletion:^(NSDictionary<NSString*, NSString*>* loginEnvironment){
		// The Keychain can block (e.g. while it asks to be unlocked)
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSString* apiKey = agent.usesAPIKey && agent.apiKeyVariable.length ? [AgentKeychain APIKeyForAgent:agent.identifier] : nil;
			dispatch_async(dispatch_get_main_queue(), ^{
				NSMutableDictionary* environment = [loginEnvironment mutableCopy];
				[environment addEntriesFromDictionary:agent.environment];
				if(apiKey)
					environment[agent.apiKeyVariable] = apiKey;

				if(!agent.command.length)
				{
					NSString* description = [NSString stringWithFormat:@"%@ has no command. Set one in Preferences ▸ Agents.", agent.name];
					completion(nil, [NSError errorWithDomain:AgentConnectionErrorDomain code:AgentConnectionErrorLaunchFailed userInfo:@{ NSLocalizedDescriptionKey: description }]);
					return;
				}

				NSString* executable = [AgentEnvironment executablePathForCommand:agent.command environment:environment];
				if(!executable)
				{
					NSString* description = [NSString stringWithFormat:@"Unable to find “%@” for %@. Install it or make sure it is on the PATH of your login shell.", agent.command, agent.name];
					completion(nil, [NSError errorWithDomain:AgentConnectionErrorDomain code:AgentConnectionErrorLaunchFailed userInfo:@{ NSLocalizedDescriptionKey: description }]);
					return;
				}

				NSMutableArray<NSDictionary*>* mcpServers = [NSMutableArray array];
				NSMutableArray<NSDictionary*>* skipped    = [NSMutableArray array];
				for(AgentMCPServer* server in servers)
				{
					NSString* problem;
					if(NSDictionary* acp = [server ACPRepresentationWithEnvironment:environment problem:&problem])
							[mcpServers addObject:acp];
					else	[skipped addObject:@{ @"name": server.name.length ? server.name : @"Unnamed server", @"reason": problem ?: @"incomplete" }];
				}

				AgentConnection* connection = [[AgentConnection alloc] initWithExecutable:executable arguments:agent.arguments environment:environment workingDirectory:workingDirectory];
				AgentSession* session = [[AgentSession alloc] initWithConnection:connection workingDirectory:workingDirectory];
				session.mcpServers            = mcpServers;
				session.skippedMCPServers = skipped;
				completion(session, nil);
			});
		});
	}];
}
@end
