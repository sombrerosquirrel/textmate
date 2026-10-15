#import "MarkdownPreviewCmark.h"
#import <AgentClient/AgentEnvironment.h>
#import <Preferences/Keys.h>
#import <fcntl.h>

static NSTimeInterval const kTimeout = 10;

@implementation MarkdownPreviewCmark
+ (NSArray<NSString*>*)argumentsAllowingRawHTML:(BOOL)allowRawHTML
{
	NSMutableArray* res = [NSMutableArray arrayWithObject:@"--sourcepos"];
	for(NSString* extension in @[ @"table", @"tasklist", @"strikethrough", @"autolink", @"footnotes" ])
		[res addObjectsFromArray:@[ @"--extension", extension ]];
	if(allowRawHTML)
		[res addObject:@"--unsafe"];
	return res;
}

+ (NSString*)executablePathInEnvironment:(NSDictionary<NSString*, NSString*>*)environment
{
	if(NSString* path = [AgentEnvironment executablePathForCommand:@"cmark-gfm" environment:environment])
		return path;
	return [AgentEnvironment executablePathForCommand:@"cmark-gfm" environment:@{ @"PATH": @"/opt/homebrew/bin:/usr/local/bin" }];
}

+ (void)locateWithCompletion:(void(^)(NSString* path, NSDictionary<NSString*, NSString*>* environment))completion
{
	[AgentEnvironment loadLoginShellEnvironmentWithCompletion:^(NSDictionary<NSString*, NSString*>* environment){
		NSString* path = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsMarkdownPreviewCmarkPathKey];
		if(!path || ![NSFileManager.defaultManager isExecutableFileAtPath:path])
			path = [self executablePathInEnvironment:environment];
		completion(path, environment);
	}];
}

+ (NSString*)HTMLFromMarkdown:(NSString*)markdown executable:(NSString*)path arguments:(NSArray<NSString*>*)arguments environment:(NSDictionary<NSString*, NSString*>*)environment error:(NSString**)error
{
	NSTask* task = [[NSTask alloc] init];
	task.executableURL = [NSURL fileURLWithPath:path];
	task.arguments     = arguments;
	task.environment   = environment;

	NSPipe* stdinPipe  = [NSPipe pipe];
	NSPipe* stdoutPipe = [NSPipe pipe];
	NSPipe* stderrPipe = [NSPipe pipe];

	// Writing to a command that exits without reading must fail with EPIPE rather than raise SIGPIPE
	fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1);
	task.standardInput  = stdinPipe;
	task.standardOutput = stdoutPipe;
	task.standardError  = stderrPipe;

	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	task.terminationHandler = ^(NSTask*){
		dispatch_semaphore_signal(done);
	};

	NSError* launchError;
	if(![task launchAndReturnError:&launchError])
	{
		if(error)
			*error = launchError.localizedDescription;
		return nil;
	}

	// Write and read concurrently, so a large document can’t fill a pipe and stall both sides
	__block NSData* output;
	__block NSData* errorOutput;
	dispatch_group_t io = dispatch_group_create();
	dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
	dispatch_group_async(io, queue, ^{
		NSFileHandle* handle = stdinPipe.fileHandleForWriting;
		[handle writeData:[markdown dataUsingEncoding:NSUTF8StringEncoding] error:nil];
		[handle closeAndReturnError:nil];
	});
	dispatch_group_async(io, queue, ^{
		output = [stdoutPipe.fileHandleForReading readDataToEndOfFileAndReturnError:nil];
	});
	dispatch_group_async(io, queue, ^{
		errorOutput = [stderrPipe.fileHandleForReading readDataToEndOfFileAndReturnError:nil];
	});

	if(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTimeout * NSEC_PER_SEC))) != 0)
	{
		[task terminate];
		if(error)
			*error = [NSString stringWithFormat:@"%@ took longer than %.0f seconds.", path.lastPathComponent, kTimeout];
		return nil;
	}

	if(dispatch_group_wait(io, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTimeout * NSEC_PER_SEC))) != 0)
	{
		if(error)
			*error = [NSString stringWithFormat:@"%@ didn’t close its output.", path.lastPathComponent];
		return nil;
	}

	if(task.terminationReason != NSTaskTerminationReasonExit || task.terminationStatus != 0)
	{
		if(error)
		{
			NSString* message = [[[NSString alloc] initWithData:(errorOutput ?: [NSData data]) encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
			*error = message.length ? message : [NSString stringWithFormat:@"%@ exited with status %d.", path.lastPathComponent, task.terminationStatus];
		}
		return nil;
	}

	NSString* html = [[NSString alloc] initWithData:(output ?: [NSData data]) encoding:NSUTF8StringEncoding];
	if(!html && error)
		*error = [NSString stringWithFormat:@"%@ didn’t produce UTF-8 output.", path.lastPathComponent];
	return html;
}
@end
