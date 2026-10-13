#import <AgentClient/AgentEnvironment.h>

void test_executable_lookup ()
{
	NSDictionary* environment = @{ @"PATH": @"/nonexistent::/usr/bin:/bin" };
	OAK_ASSERT([[AgentEnvironment executablePathForCommand:@"ls" environment:environment] isEqualToString:@"/bin/ls"]);
	OAK_ASSERT([[AgentEnvironment executablePathForCommand:@"/bin/ls" environment:environment] isEqualToString:@"/bin/ls"]);
	OAK_ASSERT([AgentEnvironment executablePathForCommand:@"/nonexistent/ls" environment:environment] == nil);
	OAK_ASSERT([AgentEnvironment executablePathForCommand:@"no-such-command-xyz" environment:environment] == nil);
	// Directories on PATH aren’t executables
	OAK_ASSERT([AgentEnvironment executablePathForCommand:@"bin" environment:@{ @"PATH": @"/" }] == nil);
}

void test_login_shell_environment ()
{
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSDictionary* environment;
	[AgentEnvironment loadLoginShellEnvironmentWithCompletion:^(NSDictionary* env){
		environment = env;
		dispatch_semaphore_signal(done);
	}];
	OAK_ASSERT(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0);
	OAK_ASSERT([environment[@"PATH"] length] > 0);
	OAK_ASSERT([environment[@"HOME"] isEqualToString:NSHomeDirectory()]);
}
