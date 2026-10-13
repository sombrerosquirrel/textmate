#import "AgentEnvironment.h"
#import <pwd.h>

static NSTimeInterval const kShellTimeout = 10;
static char const* const kMarker = "__TEXTMATE_AGENT_ENV__";

static NSString* LoginShell ()
{
	if(struct passwd* pw = getpwuid(getuid()))
	{
		if(pw->pw_shell && *pw->pw_shell)
			return [NSFileManager.defaultManager stringWithFileSystemRepresentation:pw->pw_shell length:strlen(pw->pw_shell)];
	}
	return NSProcessInfo.processInfo.environment[@"SHELL"] ?: @"/bin/zsh";
}

// Output is “<marker><NUL-separated KEY=VALUE pairs><marker>”; anything the
// shell’s startup files print before or after is ignored.
static NSDictionary<NSString*, NSString*>* ParseEnvironment (NSData* output)
{
	NSData* marker = [NSData dataWithBytes:kMarker length:strlen(kMarker)];
	NSRange first = [output rangeOfData:marker options:0 range:NSMakeRange(0, output.length)];
	if(first.location == NSNotFound)
		return nil;
	NSRange last = [output rangeOfData:marker options:NSDataSearchBackwards range:NSMakeRange(NSMaxRange(first), output.length - NSMaxRange(first))];
	if(last.location == NSNotFound)
		return nil;

	NSData* body = [output subdataWithRange:NSMakeRange(NSMaxRange(first), last.location - NSMaxRange(first))];
	NSMutableDictionary* res = [NSMutableDictionary dictionary];

	char const* bytes = (char const*)body.bytes;
	char const* end   = bytes + body.length;
	while(bytes < end)
	{
		char const* eos = (char const*)memchr(bytes, '\0', end - bytes) ?: end;
		if(char const* eq = (char const*)memchr(bytes, '=', eos - bytes))
		{
			NSString* key   = [[NSString alloc] initWithBytes:bytes length:eq - bytes encoding:NSUTF8StringEncoding];
			NSString* value = [[NSString alloc] initWithBytes:eq + 1 length:eos - eq - 1 encoding:NSUTF8StringEncoding];
			if(key.length && value)
				res[key] = value;
		}
		bytes = eos + 1;
	}
	return res[@"PATH"] ? res : nil;
}

static NSDictionary<NSString*, NSString*>* CaptureLoginShellEnvironment ()
{
	NSTask* task = [[NSTask alloc] init];
	task.executableURL  = [NSURL fileURLWithPath:LoginShell()];
	task.arguments      = @[ @"-l", @"-i", @"-c", [NSString stringWithFormat:@"printf %%s %1$s; /usr/bin/env -0; printf %%s %1$s", kMarker] ];
	task.standardInput  = [NSFileHandle fileHandleWithNullDevice];
	task.standardError  = [NSFileHandle fileHandleWithNullDevice];

	NSPipe* stdoutPipe = [NSPipe pipe];
	task.standardOutput = stdoutPipe;

	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	task.terminationHandler = ^(NSTask*){
		dispatch_semaphore_signal(done);
	};

	if(![task launchAndReturnError:nil])
		return nil;

	// Read concurrently so a large environment can’t fill the pipe and stall the shell
	__block NSData* output;
	dispatch_group_t reading = dispatch_group_create();
	dispatch_group_async(reading, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		output = [stdoutPipe.fileHandleForReading readDataToEndOfFileAndReturnError:nil];
	});

	if(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShellTimeout * NSEC_PER_SEC))) != 0)
	{
		[task terminate];
		return nil;
	}

	if(dispatch_group_wait(reading, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShellTimeout * NSEC_PER_SEC))) != 0)
		return nil;

	return task.terminationStatus == 0 ? ParseEnvironment(output) : nil;
}

@implementation AgentEnvironment
+ (void)loadLoginShellEnvironmentWithCompletion:(void(^)(NSDictionary<NSString*, NSString*>* environment))completion
{
	static dispatch_queue_t queue = dispatch_queue_create("org.macromates.TextMate.AgentEnvironment", DISPATCH_QUEUE_SERIAL);
	static NSDictionary<NSString*, NSString*>* cachedEnvironment;

	// Serial queue: concurrent callers wait for the first capture instead of starting their own
	dispatch_async(queue, ^{
		if(!cachedEnvironment)
			cachedEnvironment = CaptureLoginShellEnvironment() ?: NSProcessInfo.processInfo.environment;

		NSDictionary<NSString*, NSString*>* environment = cachedEnvironment;
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(environment);
		});
	});
}

+ (NSString*)executablePathForCommand:(NSString*)command environment:(NSDictionary<NSString*, NSString*>*)environment
{
	NSFileManager* fm = NSFileManager.defaultManager;
	if([command hasPrefix:@"/"])
		return [fm isExecutableFileAtPath:command] ? command : nil;

	NSString* path = environment[@"PATH"] ?: @"/usr/bin:/bin:/usr/sbin:/sbin";
	for(NSString* dir in [path componentsSeparatedByString:@":"])
	{
		if(!dir.length)
			continue;
		NSString* candidate = [dir stringByAppendingPathComponent:command];
		BOOL isDirectory = NO;
		if([fm fileExistsAtPath:candidate isDirectory:&isDirectory] && !isDirectory && [fm isExecutableFileAtPath:candidate])
			return candidate;
	}
	return nil;
}
@end
