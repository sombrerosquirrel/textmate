#import "AgentRegistry.h"
#import "AgentEnvironment.h"

@implementation AgentDescriptor
- (instancetype)initWithIdentifier:(NSString*)identifier name:(NSString*)name command:(NSString*)command arguments:(NSArray<NSString*>*)arguments
{
	if(self = [super init])
	{
		_identifier = identifier;
		_name       = name;
		_command    = command;
		_arguments  = arguments ?: @[ ];
	}
	return self;
}
@end

@implementation AgentRegistry
+ (NSArray<AgentDescriptor*>*)agents
{
	static NSArray<AgentDescriptor*>* const agents = @[
		[[AgentDescriptor alloc] initWithIdentifier:@"copilot" name:@"GitHub Copilot" command:@"copilot" arguments:@[ @"--acp" ]],
		[[AgentDescriptor alloc] initWithIdentifier:@"claude"  name:@"Claude Code"    command:@"npx"     arguments:@[ @"-y", @"@agentclientprotocol/claude-agent-acp" ]],
	];
	return agents;
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

+ (void)makeSessionForAgent:(AgentDescriptor*)agent workingDirectory:(NSString*)workingDirectory completion:(void(^)(AgentSession* session, NSError* error))completion
{
	[AgentEnvironment loadLoginShellEnvironmentWithCompletion:^(NSDictionary<NSString*, NSString*>* environment){
		NSString* executable = [AgentEnvironment executablePathForCommand:agent.command environment:environment];
		if(!executable)
		{
			NSString* description = [NSString stringWithFormat:@"Unable to find “%@” for %@. Install it or make sure it is on the PATH of your login shell.", agent.command, agent.name];
			completion(nil, [NSError errorWithDomain:AgentConnectionErrorDomain code:AgentConnectionErrorLaunchFailed userInfo:@{ NSLocalizedDescriptionKey: description }]);
			return;
		}

		AgentConnection* connection = [[AgentConnection alloc] initWithExecutable:executable arguments:agent.arguments environment:environment workingDirectory:workingDirectory];
		completion([[AgentSession alloc] initWithConnection:connection workingDirectory:workingDirectory], nil);
	}];
}
@end
