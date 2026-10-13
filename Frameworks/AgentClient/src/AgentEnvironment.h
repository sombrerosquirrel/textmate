// Environment for agent processes.
//
// Apps launched from the Dock don’t inherit the user’s shell setup, so tools
// installed via Homebrew, nvm, etc. aren’t on PATH. We run the user’s login
// shell once (interactive, so files like .zshrc are read), capture its
// environment, and cache it.

@interface AgentEnvironment : NSObject
// Completion runs on the main queue. Falls back to this process’ environment
// if the shell fails or takes longer than a few seconds.
+ (void)loadLoginShellEnvironmentWithCompletion:(void(^)(NSDictionary<NSString*, NSString*>* environment))completion;

// Absolute paths are returned as-is (if executable); other commands are
// looked up in the PATH of `environment`. Returns nil if not found.
+ (NSString*)executablePathForCommand:(NSString*)command environment:(NSDictionary<NSString*, NSString*>*)environment;
@end
