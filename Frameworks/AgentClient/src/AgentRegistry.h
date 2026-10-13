#import "AgentSession.h"

// Known agents and how to start them. Built-in defaults for now; user
// configuration (Preferences, .tm_properties) is milestone M4.

@interface AgentDescriptor : NSObject
- (instancetype)initWithIdentifier:(NSString*)identifier name:(NSString*)name command:(NSString*)command arguments:(NSArray<NSString*>*)arguments;
@property (nonatomic, readonly) NSString* identifier;
@property (nonatomic, readonly) NSString* name;
@property (nonatomic, readonly) NSString* command;
@property (nonatomic, readonly) NSArray<NSString*>* arguments;
@end

@interface AgentRegistry : NSObject
@property (class, nonatomic, readonly) NSArray<AgentDescriptor*>* agents;
+ (AgentDescriptor*)agentWithIdentifier:(NSString*)identifier;

// Resolves the agent’s command in the login shell environment and creates
// an (unstarted) session whose callbacks run on the main queue. Completion
// runs on the main queue with either a session or an error.
+ (void)makeSessionForAgent:(AgentDescriptor*)agent workingDirectory:(NSString*)workingDirectory completion:(void(^)(AgentSession* session, NSError* error))completion;
@end
