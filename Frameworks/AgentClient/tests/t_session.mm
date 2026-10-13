#import "agent_test_support.h"

struct test_session_t
{
	test_session_t (NSArray<NSString*>* agentArguments = @[ ])
	{
		queue    = TestQueue();
		recorder = [[AgentTestRecorder alloc] init];
		session  = [[AgentSession alloc] initWithConnection:FakeAgentConnection(queue, agentArguments) workingDirectory:@"/tmp/project"];
		session.delegate = recorder;
	}

	~test_session_t ()
	{
		[session close];
	}

	// Blocks capture C++ objects by copy, and a copy’s destructor would close the
	// session. Use member functions (which capture `this`) instead.
	test_session_t (test_session_t const&) = delete;
	test_session_t& operator= (test_session_t const&) = delete;

	NSString* currentMode ()
	{
		__block NSString* res;
		dispatch_sync(queue, ^{ res = session.configOptions.firstObject[@"currentValue"]; });
		return res;
	}

	NSArray* commandNames ()
	{
		__block NSArray* res;
		dispatch_sync(queue, ^{ res = [session.availableCommands valueForKey:@"name"]; });
		return res;
	}

	NSError* setConfigOption (NSString* configId, id value)
	{
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		__block NSError* res;
		[session setConfigOption:configId value:value completion:^(NSError* error){
			res = error;
			dispatch_semaphore_signal(done);
		}];
		OAK_ASSERT(Wait(done));
		return res;
	}

	NSError* start ()
	{
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		__block NSError* res;
		[session startWithCompletion:^(NSError* error){
			res = error;
			dispatch_semaphore_signal(done);
		}];
		OAK_ASSERT(Wait(done));
		return res;
	}

	NSString* prompt (NSString* text, NSError** error = nullptr)
	{
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		__block NSString* res;
		__block NSError* err;
		[session sendPrompt:TextPrompt(text) completion:^(NSString* stopReason, NSError* error){
			res = stopReason;
			err = error;
			dispatch_semaphore_signal(done);
		}];
		OAK_ASSERT(Wait(done));
		if(error)
			*error = err;
		return res;
	}

	NSString* messageText ()
	{
		__block NSString* res;
		dispatch_sync(queue, ^{ res = [recorder.messageText copy]; });
		return res;
	}

	AgentSessionState state ()
	{
		__block AgentSessionState res;
		dispatch_sync(queue, ^{ res = session.state; });
		return res;
	}

	dispatch_queue_t queue;
	AgentTestRecorder* recorder;
	AgentSession* session;
};

void test_handshake ()
{
	test_session_t t;
	OAK_ASSERT_EQ((NSInteger)t.state(), (NSInteger)AgentSessionStateIdle);
	OAK_ASSERT(t.start() == nil);
	OAK_ASSERT_EQ((NSInteger)t.state(), (NSInteger)AgentSessionStateReady);
	OAK_ASSERT([t.session.sessionId isEqualToString:@"sess-/tmp/project"]);
	OAK_ASSERT([t.session.agentInfo[@"name"] isEqualToString:@"fake-agent"]);
	OAK_ASSERT([t.session.agentCapabilities[@"loadSession"] isEqual:@NO]);
	OAK_ASSERT_EQ(t.session.authMethods.count, 0);

	// Notifications other than session/update reach the delegate
	OAK_ASSERT(Wait(t.recorder.notificationReceived));
}

void test_start_twice ()
{
	test_session_t t;
	OAK_ASSERT(t.start() == nil);
	NSError* error = t.start();
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentSessionErrorInvalidState);
	OAK_ASSERT_EQ((NSInteger)t.state(), (NSInteger)AgentSessionStateReady);
}

void test_prompt_streaming ()
{
	test_session_t t;
	OAK_ASSERT(t.start() == nil);

	NSError* error;
	OAK_ASSERT([t.prompt(@"hello", &error) isEqualToString:@"end_turn"]);
	OAK_ASSERT(error == nil);
	OAK_ASSERT([t.messageText() isEqualToString:@"Echo: hello"]);
	OAK_ASSERT_EQ((NSInteger)t.state(), (NSInteger)AgentSessionStateReady);

	// A second turn on the same session
	OAK_ASSERT([t.prompt(@"again") isEqualToString:@"end_turn"]);
	OAK_ASSERT([t.messageText() isEqualToString:@"Echo: helloEcho: again"]);
}

void test_large_message ()
{
	test_session_t t;
	OAK_ASSERT(t.start() == nil);
	OAK_ASSERT([t.prompt(@"big") isEqualToString:@"end_turn"]);
	OAK_ASSERT_EQ(t.messageText().length, 1024 * 1024);
}

void test_prompt_before_start ()
{
	test_session_t t;
	NSError* error;
	OAK_ASSERT(t.prompt(@"hello", &error) == nil);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentSessionErrorInvalidState);
}

void test_cancel ()
{
	test_session_t t;
	OAK_ASSERT(t.start() == nil);

	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSString* stopReason;
	[t.session sendPrompt:TextPrompt(@"wait") completion:^(NSString* reason, NSError* error){
		stopReason = reason;
		dispatch_semaphore_signal(done);
	}];

	OAK_ASSERT(Wait(t.recorder.updateReceived)); // agent is now waiting for session/cancel
	OAK_ASSERT_EQ((NSInteger)t.state(), (NSInteger)AgentSessionStatePrompting);
	[t.session cancel];

	OAK_ASSERT(Wait(done));
	OAK_ASSERT([stopReason isEqualToString:@"cancelled"]);
	OAK_ASSERT_EQ((NSInteger)t.state(), (NSInteger)AgentSessionStateReady);
}

void test_permission_without_handler_is_cancelled ()
{
	test_session_t t;
	OAK_ASSERT(t.start() == nil);
	OAK_ASSERT([t.prompt(@"permission") isEqualToString:@"end_turn"]);
	OAK_ASSERT([t.messageText() isEqualToString:@"Outcome: cancelled"]);
}

void test_permission_selected ()
{
	test_session_t t;
	t.recorder.permissionOutcome = @{ @"outcome": @"selected", @"optionId": @"allow" };
	OAK_ASSERT(t.start() == nil);
	OAK_ASSERT([t.prompt(@"permission") isEqualToString:@"end_turn"]);
	OAK_ASSERT([t.messageText() isEqualToString:@"Outcome: selected allow"]);
}

void test_unsupported_protocol_version ()
{
	test_session_t t(@[ @"--version", @"2" ]);
	NSError* error = t.start();
	OAK_ASSERT([error.domain isEqualToString:AgentSessionErrorDomain]);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentSessionErrorUnsupportedProtocolVersion);
	OAK_ASSERT_EQ((NSInteger)t.state(), (NSInteger)AgentSessionStateFailed);
}

void test_session_new_failure ()
{
	test_session_t t(@[ @"--fail-new" ]);
	NSError* error = t.start();
	OAK_ASSERT([error.domain isEqualToString:AgentJSONRPCErrorDomain]);
	OAK_ASSERT_EQ(error.code, -32000);
	OAK_ASSERT([error.localizedDescription isEqualToString:@"Authentication required"]);
	OAK_ASSERT_EQ((NSInteger)t.state(), (NSInteger)AgentSessionStateFailed);
}

void test_agent_crash_during_prompt ()
{
	test_session_t t;
	OAK_ASSERT(t.start() == nil);

	NSError* error;
	OAK_ASSERT(t.prompt(@"crash", &error) == nil);
	OAK_ASSERT([error.domain isEqualToString:AgentConnectionErrorDomain]);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentConnectionErrorTerminated);

	OAK_ASSERT(Wait(t.recorder.terminated));
	OAK_ASSERT_EQ((NSInteger)t.state(), (NSInteger)AgentSessionStateTerminated);
}

void test_launch_failure ()
{
	dispatch_queue_t queue = TestQueue();
	AgentConnection* connection = [[AgentConnection alloc] initWithExecutable:@"/nonexistent/agent" arguments:@[ ] environment:nil workingDirectory:NSTemporaryDirectory()];
	connection.callbackQueue = queue;
	AgentSession* session = [[AgentSession alloc] initWithConnection:connection workingDirectory:@"/tmp"];

	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSError* error;
	[session startWithCompletion:^(NSError* err){
		error = err;
		dispatch_semaphore_signal(done);
	}];
	OAK_ASSERT(Wait(done));
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentConnectionErrorLaunchFailed);

	__block AgentSessionState state;
	dispatch_sync(queue, ^{ state = session.state; });
	OAK_ASSERT_EQ((NSInteger)state, (NSInteger)AgentSessionStateFailed);
}

void test_configuration ()
{
	test_session_t t;
	OAK_ASSERT(t.start() == nil);

	// Config options and modes arrive with session/new, commands right after
	OAK_ASSERT([t.currentMode() isEqualToString:@"ask"]);
	OAK_ASSERT([t.session.modes[@"currentModeId"] isEqualToString:@"ask"]);
	for(size_t i = 0; i < 3 && !t.commandNames(); ++i)
		OAK_ASSERT(Wait(t.recorder.configurationChanged));
	OAK_ASSERT([t.commandNames() isEqual:(@[ @"plan", @"review" ])]);

	OAK_ASSERT(t.setConfigOption(@"mode", @"code") == nil);
	OAK_ASSERT([t.currentMode() isEqualToString:@"code"]);

	NSError* error = t.setConfigOption(@"mode", @"bogus");
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentJSONRPCErrorInvalidParams);
	OAK_ASSERT([t.currentMode() isEqualToString:@"code"]);
}

void test_set_mode ()
{
	test_session_t t;
	OAK_ASSERT(t.start() == nil);

	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSError* error;
	[t.session setMode:@"code" completion:^(NSError* err){
		error = err;
		dispatch_semaphore_signal(done);
	}];
	OAK_ASSERT(Wait(done));
	OAK_ASSERT(error == nil);
	OAK_ASSERT([t.session.modes[@"currentModeId"] isEqualToString:@"code"]);
}

void test_close ()
{
	test_session_t t;
	OAK_ASSERT(t.start() == nil);
	[t.session close];
	OAK_ASSERT(Wait(t.recorder.terminated));
	OAK_ASSERT_EQ((NSInteger)t.state(), (NSInteger)AgentSessionStateTerminated);
}
