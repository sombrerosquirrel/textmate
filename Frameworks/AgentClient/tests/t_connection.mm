#import "agent_test_support.h"

// Sends a request and waits for its response.
static void Request (AgentConnection* connection, NSString* method, id params, id* result, NSError** error)
{
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block id blockResult;
	__block NSError* blockError;
	[connection sendRequest:method params:params completion:^(id res, NSError* err){
		blockResult = res;
		blockError  = err;
		dispatch_semaphore_signal(done);
	}];
	OAK_ASSERT(Wait(done));
	*result = blockResult;
	*error  = blockError;
}

void test_request_response ()
{
	AgentConnection* connection = FakeAgentConnection(TestQueue());
	OAK_ASSERT([connection launch:nil]);
	OAK_ASSERT(connection.isRunning);

	// The embedded newline must survive newline-delimited framing
	NSDictionary* params = @{ @"number": @42, @"text": @"line one\nline two", @"path": @"/tmp/a/b" };
	id result; NSError* error;
	Request(connection, @"_fake/echo", params, &result, &error);
	OAK_ASSERT(error == nil);
	OAK_ASSERT([result isEqual:params]);

	[connection terminateWithGracePeriod:1];
}

void test_error_response ()
{
	AgentConnection* connection = FakeAgentConnection(TestQueue());
	OAK_ASSERT([connection launch:nil]);

	id result; NSError* error;
	Request(connection, @"no/such/method", @{ }, &result, &error);
	OAK_ASSERT(result == nil);
	OAK_ASSERT([error.domain isEqualToString:AgentJSONRPCErrorDomain]);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentJSONRPCErrorMethodNotFound);

	[connection terminateWithGracePeriod:1];
}

void test_notification ()
{
	dispatch_queue_t queue = TestQueue();
	AgentTestRecorder* recorder = [[AgentTestRecorder alloc] init];
	AgentConnection* connection = FakeAgentConnection(queue);
	connection.delegate = recorder;
	OAK_ASSERT([connection launch:nil]);

	id result; NSError* error;
	Request(connection, @"initialize", @{ @"protocolVersion": @1 }, &result, &error);
	OAK_ASSERT(Wait(recorder.notificationReceived));

	__block NSArray* methods;
	dispatch_sync(queue, ^{ methods = [recorder.notificationMethods copy]; });
	OAK_ASSERT([methods isEqual:@[ @"_fake/hello" ]]);

	[connection terminateWithGracePeriod:1];
}

void test_unhandled_request_from_agent ()
{
	AgentConnection* connection = FakeAgentConnection(TestQueue());
	OAK_ASSERT([connection launch:nil]);

	// The agent asks us fs/read_text_file; without a delegate we must answer “method not found”
	id result; NSError* error;
	Request(connection, @"_fake/ask_client", @{ }, &result, &error);
	OAK_ASSERT(error == nil);
	OAK_ASSERT_EQ((NSInteger)[result[@"clientError"] integerValue], (NSInteger)AgentJSONRPCErrorMethodNotFound);

	[connection terminateWithGracePeriod:1];
}

void test_pending_requests_fail_when_agent_exits ()
{
	dispatch_queue_t queue = TestQueue();
	AgentTestRecorder* recorder = [[AgentTestRecorder alloc] init];
	AgentConnection* connection = FakeAgentConnection(queue);
	connection.delegate = recorder;
	OAK_ASSERT([connection launch:nil]);

	id result; NSError* error;
	Request(connection, @"session/prompt", @{ @"sessionId": @"s", @"prompt": TextPrompt(@"crash") }, &result, &error);
	OAK_ASSERT([error.domain isEqualToString:AgentConnectionErrorDomain]);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentConnectionErrorTerminated);

	OAK_ASSERT(Wait(recorder.terminated));
	OAK_ASSERT(!connection.isRunning);
	OAK_ASSERT_EQ(connection.terminationStatus, 3);

	Request(connection, @"_fake/echo", @{ }, &result, &error);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentConnectionErrorNotRunning);
}

void test_terminate ()
{
	AgentTestRecorder* recorder = [[AgentTestRecorder alloc] init];
	AgentConnection* connection = FakeAgentConnection(TestQueue());
	connection.delegate = recorder;
	OAK_ASSERT([connection launch:nil]);

	[connection terminateWithGracePeriod:1];
	OAK_ASSERT(Wait(recorder.terminated));
	OAK_ASSERT(!connection.isRunning);
}

void test_launch_failure ()
{
	AgentConnection* connection = [[AgentConnection alloc] initWithExecutable:@"/nonexistent/agent" arguments:@[ ] environment:nil workingDirectory:NSTemporaryDirectory()];
	NSError* error;
	OAK_ASSERT(![connection launch:&error]);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentConnectionErrorLaunchFailed);
	OAK_ASSERT(!connection.isRunning);

	// Terminating a connection that never launched must be harmless
	[connection terminateWithGracePeriod:1];
}

void test_request_before_launch ()
{
	AgentConnection* connection = FakeAgentConnection(TestQueue());
	id result; NSError* error;
	Request(connection, @"_fake/echo", @{ }, &result, &error);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentConnectionErrorNotRunning);
}

void test_standard_error_and_invalid_output ()
{
	dispatch_queue_t queue = TestQueue();
	AgentTestRecorder* recorder = [[AgentTestRecorder alloc] init];
	AgentConnection* connection = FakeAgentConnection(queue);
	connection.delegate = recorder;
	OAK_ASSERT([connection launch:nil]);

	id result; NSError* error;
	Request(connection, @"session/prompt", @{ @"sessionId": @"s", @"prompt": TextPrompt(@"stderr") }, &result, &error);
	OAK_ASSERT([result[@"stopReason"] isEqual:@"end_turn"]);
	Request(connection, @"session/prompt", @{ @"sessionId": @"s", @"prompt": TextPrompt(@"garbage") }, &result, &error);
	OAK_ASSERT([result[@"stopReason"] isEqual:@"end_turn"]);

	// stderr is read independently of stdout, so allow it to arrive after the response
	[connection terminateWithGracePeriod:1];
	OAK_ASSERT(Wait(recorder.terminated));

	__block NSString* standardError;
	dispatch_sync(queue, ^{ standardError = [recorder.standardError copy]; });
	OAK_ASSERT([standardError containsString:@"fake agent: stderr line"]);
	OAK_ASSERT([standardError containsString:@"Ignoring invalid message from agent: this is not json"]);
}
