#import "AgentSession.h"

// Known agents and how to start them: the built-in agents (GitHub Copilot,
// Claude Code) and the user’s own, configured in Preferences ▸ Agents and
// stored in user defaults. Also the MCP servers passed to every agent.

extern NSString* const kUserDefaultsAgentsKey;          // array of agent dictionaries, in display order
extern NSString* const kUserDefaultsAgentMCPServersKey; // array of MCP server dictionaries

// Posted by +setAgents: and +setMCPServers:.
extern NSNotificationName const AgentRegistryDidChangeNotification;

// Splits a command line into words like a shell: blanks separate words,
// single and double quotes group them, and a backslash escapes the next
// character (outside single quotes). As path::unescape, which splits
// lspCommand, except that a single quote inside double quotes is literal.
NSArray<NSString*>* AgentArgumentsFromCommandLine (NSString* commandLine);

@interface AgentDescriptor : NSObject <NSCopying>
// Keys: identifier, name, command (command line), environment, enabled,
// apiKeyVariable, usesAPIKey.
- (instancetype)initWithDictionary:(NSDictionary*)dictionary;
- (instancetype)initWithIdentifier:(NSString*)identifier name:(NSString*)name commandLine:(NSString*)commandLine;
@property (nonatomic, readonly) NSDictionary* dictionaryRepresentation;

@property (nonatomic, readonly) NSString* identifier;
@property (nonatomic, readonly, getter = isBuiltIn) BOOL builtIn;
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* commandLine;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*>* environment; // added to the login shell environment
@property (nonatomic, getter = isEnabled) BOOL enabled;                     // shown in the panel’s agent picker
@property (nonatomic, copy) NSString* apiKeyVariable;                      // e.g. ANTHROPIC_API_KEY
@property (nonatomic) BOOL usesAPIKey;                                    // pass the Keychain’s API key in apiKeyVariable

// The command line split into words: command is the first, arguments the rest.
@property (nonatomic, readonly) NSString* command;
@property (nonatomic, readonly) NSArray<NSString*>* arguments;

// For built-in agents: the command that signs in from a terminal (e.g.
// `claude auth login`), used when the agent doesn’t name one in its
// authMethods; and how to install the agent, for when its command is missing.
@property (nonatomic, readonly) NSArray<NSString*>* signInArguments;
@property (nonatomic, readonly) NSString* installHint;

// Copilot CLI (checked with 1.0.97) ignores mcpServers in session/new and
// session/load; it takes them on its command line instead.
@property (nonatomic, readonly) BOOL takesMCPServersAsArgument;
// Arguments that pass ACP McpServer objects to such an agent.
+ (NSArray<NSString*>*)argumentsForMCPServers:(NSArray<NSDictionary*>*)servers;
@end

// An MCP server, as configured in Preferences ▸ Agents.
@interface AgentMCPServer : NSObject <NSCopying>
// Keys: name, type (stdio, http, sse), command (command line, stdio), url
// (http, sse), environment (stdio) or headers (http, sse), enabled.
- (instancetype)initWithDictionary:(NSDictionary*)dictionary;
@property (nonatomic, readonly) NSDictionary* dictionaryRepresentation;

@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* type;
@property (nonatomic, copy) NSString* commandLine;
@property (nonatomic, copy) NSString* url;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*>* variables; // environment (stdio) or headers (http, sse)
@property (nonatomic, getter = isEnabled) BOOL enabled;

// The ACP McpServer object for session/new, or nil if the server is
// incomplete or its command can’t be found on the PATH of `environment`;
// `problem` then says why, e.g. “no command”.
- (NSDictionary*)ACPRepresentationWithEnvironment:(NSDictionary<NSString*, NSString*>*)environment problem:(NSString**)problem;
@end

@interface AgentRegistry : NSObject
// Where agents and MCP servers are stored (tests use their own suite).
// Default: NSUserDefaults.standardUserDefaults.
@property (class, nonatomic) NSUserDefaults* userDefaults;

@property (class, nonatomic, readonly) NSArray<AgentDescriptor*>* defaultAgents;
// All configured agents, enabled or not, in display order.
@property (class, nonatomic, readonly) NSArray<AgentDescriptor*>* agents;
@property (class, nonatomic, readonly) NSArray<AgentDescriptor*>* enabledAgents;
+ (AgentDescriptor*)agentWithIdentifier:(NSString*)identifier;
// Saves the list. Built-in agents left out are added back (they can be
// disabled, not removed).
+ (void)setAgents:(NSArray<AgentDescriptor*>*)agents;
+ (AgentDescriptor*)defaultAgentWithIdentifier:(NSString*)identifier;
// A new, enabled agent with a unique identifier (not yet saved).
+ (AgentDescriptor*)makeAgent;

// The agents for a project with `.tm_properties` keys agentName and
// agentCommand (either may be nil): the enabled agents, plus the one
// agentName names if it’s disabled. With agentCommand, that agent’s command
// line is replaced; if agentName names no agent, a “project” agent called
// agentName (or “Project Agent”) is added first. `projectAgent` is set to
// the agent the project asks for, if any.
+ (NSArray<AgentDescriptor*>*)agentsForProjectWithAgentName:(NSString*)agentName command:(NSString*)agentCommand projectAgent:(AgentDescriptor**)projectAgent;

@property (class, nonatomic, readonly) NSArray<AgentMCPServer*>* MCPServers;
+ (void)setMCPServers:(NSArray<AgentMCPServer*>*)servers;

// Resolves the agent’s command in the login shell environment, adds the
// agent’s environment and API key, and creates an (unstarted) session whose
// callbacks run on the main queue, with the enabled MCP servers. Completion
// runs on the main queue with either a session or an error.
+ (void)makeSessionForAgent:(AgentDescriptor*)agent workingDirectory:(NSString*)workingDirectory completion:(void(^)(AgentSession* session, NSError* error))completion;
@end
