#ifndef AGENT_TEST_SUPPORT_H_9C41E2
#define AGENT_TEST_SUPPORT_H_9C41E2

#import <AgentClient/AgentConnection.h>
#import <AgentClient/AgentSession.h>

// Tests run on background threads while the main run loop runs. Each test
// gets its own serial callback queue and waits on semaphores.

static NSTimeInterval const kAgentTestTimeout = 15;

static NSString* FakeAgentPath ()
{
	return [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"fake_agent.rb"];
}

static AgentConnection* FakeAgentConnection (dispatch_queue_t queue, NSArray<NSString*>* extraArguments = @[ ])
{
	NSArray* arguments = [@[ @"ruby", FakeAgentPath() ] arrayByAddingObjectsFromArray:extraArguments];
	AgentConnection* connection = [[AgentConnection alloc] initWithExecutable:@"/usr/bin/env" arguments:arguments environment:NSProcessInfo.processInfo.environment workingDirectory:NSTemporaryDirectory()];
	connection.callbackQueue = queue;
	return connection;
}

static dispatch_queue_t TestQueue ()
{
	return dispatch_queue_create("org.macromates.TextMate.AgentClient.test", DISPATCH_QUEUE_SERIAL);
}

static bool Wait (dispatch_semaphore_t semaphore)
{
	return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAgentTestTimeout * NSEC_PER_SEC))) == 0;
}

static NSArray<NSDictionary*>* TextPrompt (NSString* text)
{
	return @[ @{ @"type": @"text", @"text": text } ];
}

// Records everything a connection or session reports. All callbacks arrive on
// the test’s serial callback queue; read the properties via dispatch_sync.
@interface AgentTestRecorder : NSObject <AgentConnectionDelegate, AgentSessionDelegate>
@property (nonatomic) NSMutableArray<NSString*>* notificationMethods;
@property (nonatomic) NSMutableString* standardError;
@property (nonatomic) NSMutableString* messageText;
@property (nonatomic) dispatch_semaphore_t terminated;
@property (nonatomic) dispatch_semaphore_t updateReceived;
@property (nonatomic) dispatch_semaphore_t notificationReceived;
@property (nonatomic) dispatch_semaphore_t configurationChanged;
// When set, permission requests are answered with this outcome; when nil the
// recorder doesn’t implement the permission delegate method at all.
@property (nonatomic) NSDictionary* permissionOutcome;
@end

@implementation AgentTestRecorder
- (instancetype)init
{
	if(self = [super init])
	{
		_notificationMethods  = [NSMutableArray array];
		_standardError        = [NSMutableString string];
		_messageText          = [NSMutableString string];
		_terminated           = dispatch_semaphore_create(0);
		_updateReceived       = dispatch_semaphore_create(0);
		_notificationReceived = dispatch_semaphore_create(0);
		_configurationChanged = dispatch_semaphore_create(0);
	}
	return self;
}

- (BOOL)respondsToSelector:(SEL)selector
{
	if(selector == @selector(agentSession:requestPermission:reply:))
		return _permissionOutcome != nil;
	return [super respondsToSelector:selector];
}

- (void)agentConnection:(AgentConnection*)connection didReceiveNotification:(NSString*)method params:(id)params
{
	[_notificationMethods addObject:method];
	dispatch_semaphore_signal(_notificationReceived);
}

- (void)agentConnection:(AgentConnection*)connection didReceiveStandardError:(NSString*)text  { [_standardError appendString:text]; }
- (void)agentSession:(AgentSession*)session didReceiveStandardError:(NSString*)text           { [_standardError appendString:text]; }
- (void)agentConnectionDidTerminate:(AgentConnection*)connection                              { dispatch_semaphore_signal(_terminated); }

- (void)agentSessionDidChangeState:(AgentSession*)session
{
	if(session.state == AgentSessionStateTerminated || session.state == AgentSessionStateFailed)
		dispatch_semaphore_signal(_terminated);
}

- (void)agentSession:(AgentSession*)session didReceiveUpdate:(NSDictionary*)update
{
	if([update[@"sessionUpdate"] isEqualToString:@"agent_message_chunk"] && [update[@"content"][@"type"] isEqualToString:@"text"])
	{
		[_messageText appendString:update[@"content"][@"text"]];
		dispatch_semaphore_signal(_updateReceived);
	}
}

- (void)agentSessionDidChangeConfiguration:(AgentSession*)session
{
	dispatch_semaphore_signal(_configurationChanged);
}

- (void)agentSession:(AgentSession*)session didReceiveNotification:(NSString*)method params:(id)params
{
	[_notificationMethods addObject:method];
	dispatch_semaphore_signal(_notificationReceived);
}

- (void)agentSession:(AgentSession*)session requestPermission:(NSDictionary*)params reply:(void(^)(NSDictionary* outcome))reply
{
	reply(_permissionOutcome);
}
@end

#endif
