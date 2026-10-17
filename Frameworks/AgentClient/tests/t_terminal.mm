#import "agent_test_support.h"
#import <AgentClient/AgentTerminal.h>

struct test_terminals_t
{
	test_terminals_t ()
	{
		queue     = TestQueue();
		terminals = [[AgentTerminalManager alloc] initWithWorkingDirectory:NSTemporaryDirectory() queue:queue];
	}

	~test_terminals_t ()
	{
		dispatch_sync(queue, ^{ [terminals killAll]; });
	}

	// Performs a request on the manager’s queue and waits for the reply
	id request (NSString* method, NSDictionary* params, NSError** error = nullptr)
	{
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		__block id res;
		__block NSError* err;
		dispatch_async(queue, ^{
			[terminals handleRequest:method params:params reply:^(id result, NSError* error){
				res = result;
				err = error;
				dispatch_semaphore_signal(done);
			}];
		});
		OAK_ASSERT(Wait(done));
		if(error)
			*error = err;
		return res;
	}

	NSString* create (NSDictionary* params)
	{
		return request(@"terminal/create", params)[@"terminalId"];
	}

	NSDictionary* run (NSDictionary* params)
	{
		NSString* terminalId = create(params);
		OAK_ASSERT(terminalId != nil);
		NSDictionary* exitStatus = request(@"terminal/wait_for_exit", @{ @"terminalId": terminalId });
		NSDictionary* output     = request(@"terminal/output", @{ @"terminalId": terminalId });
		NSMutableDictionary* res = [output mutableCopy];
		res[@"waitResult"] = exitStatus;
		res[@"terminalId"] = terminalId;
		return res;
	}

	dispatch_queue_t queue;
	AgentTerminalManager* terminals;
};

void test_terminal_shell_command ()
{
	test_terminals_t t;
	NSDictionary* res = t.run(@{ @"command": @"echo hello; echo err >&2; exit 3" });
	OAK_ASSERT([res[@"output"] isEqualToString:@"hello\nerr\n"]);
	OAK_ASSERT([res[@"truncated"] isEqual:@NO]);
	OAK_ASSERT([res[@"exitStatus"][@"exitCode"] isEqual:@3]);
	OAK_ASSERT([res[@"waitResult"][@"exitCode"] isEqual:@3]);
	OAK_ASSERT(res[@"waitResult"][@"signal"] == [NSNull null]);
}

void test_terminal_arguments_env_and_cwd ()
{
	test_terminals_t t;
	NSDictionary* res = t.run(@{ @"command": @"printf", @"args": @[ @"%s-%s", @"a b", @"c" ] });
	OAK_ASSERT([res[@"output"] isEqualToString:@"a b-c"]);

	res = t.run(@{ @"command": @"echo \"$AGENT_TEST\"", @"env": @[ @{ @"name": @"AGENT_TEST", @"value": @"from env" } ] });
	OAK_ASSERT([res[@"output"] isEqualToString:@"from env\n"]);

	res = t.run(@{ @"command": @"pwd -P", @"cwd": @"/usr/bin" });
	OAK_ASSERT([res[@"output"] isEqualToString:@"/usr/bin\n"]);

	NSError* error;
	OAK_ASSERT(t.request(@"terminal/create", @{ @"command": @"no-such-command-xyz", @"args": @[ @"x" ] }, &error) == nil);
	OAK_ASSERT(error != nil);
	OAK_ASSERT(t.request(@"terminal/create", @{ @"command": @"pwd", @"cwd": @"relative" }, &error) == nil);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentJSONRPCErrorInvalidParams);
}

void test_terminal_output_limit ()
{
	test_terminals_t t;
	// 100 × “é” (2 bytes each); 11 bytes would start mid-character
	NSDictionary* res = t.run(@{ @"command": @"i=0; while [ $i -lt 100 ]; do printf '\\303\\251'; i=$((i+1)); done", @"outputByteLimit": @11 });
	OAK_ASSERT([res[@"truncated"] isEqual:@YES]);
	OAK_ASSERT([res[@"output"] isEqualToString:@"ééééé"]);
}

void test_terminal_kill_and_release ()
{
	test_terminals_t t;
	NSString* terminalId = t.create(@{ @"command": @"sleep 30 & wait" });
	OAK_ASSERT(terminalId != nil);

	NSDictionary* output = t.request(@"terminal/output", @{ @"terminalId": terminalId });
	OAK_ASSERT(output[@"exitStatus"] == nil);

	OAK_ASSERT(t.request(@"terminal/kill", @{ @"terminalId": terminalId }) != nil);
	NSDictionary* exitStatus = t.request(@"terminal/wait_for_exit", @{ @"terminalId": terminalId });
	OAK_ASSERT([exitStatus[@"signal"] isEqualToString:@"SIGTERM"]);

	// Still valid after kill, gone after release, but kept for display
	OAK_ASSERT(t.request(@"terminal/output", @{ @"terminalId": terminalId })[@"exitStatus"] != nil);
	OAK_ASSERT(t.request(@"terminal/release", @{ @"terminalId": terminalId }) != nil);
	NSError* error;
	OAK_ASSERT(t.request(@"terminal/output", @{ @"terminalId": terminalId }, &error) == nil);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentJSONRPCErrorInvalidParams);

	__block BOOL released;
	dispatch_sync(t.queue, ^{ released = [t.terminals terminalWithIdentifier:terminalId].released; });
	OAK_ASSERT(released);
}

void test_terminal_release_kills ()
{
	test_terminals_t t;
	NSString* terminalId = t.create(@{ @"command": @"sleep", @"args": @[ @"30" ] });
	OAK_ASSERT(t.request(@"terminal/release", @{ @"terminalId": terminalId }) != nil);

	// The process is gone shortly after
	__block BOOL exited = NO;
	for(int i = 0; i < 50 && !exited; ++i)
	{
		usleep(100000);
		dispatch_sync(t.queue, ^{ exited = [t.terminals terminalWithIdentifier:terminalId].exited; });
	}
	OAK_ASSERT(exited);
}

void test_session_terminal_requests ()
{
	dispatch_queue_t queue = TestQueue();
	AgentTestRecorder* recorder = [[AgentTestRecorder alloc] init];
	AgentSession* session = [[AgentSession alloc] initWithConnection:FakeAgentConnection(queue) workingDirectory:NSTemporaryDirectory()];
	session.delegate  = recorder;
	session.terminals = [[AgentTerminalManager alloc] initWithWorkingDirectory:NSTemporaryDirectory() queue:queue];

	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[session startWithCompletion:^(NSError* error){ dispatch_semaphore_signal(done); }];
	OAK_ASSERT(Wait(done));

	[session sendPrompt:TextPrompt(@"run echo one; echo two") completion:^(NSString* stopReason, NSError* error){ dispatch_semaphore_signal(done); }];
	OAK_ASSERT(Wait(done));
	__block NSString* text;
	dispatch_sync(queue, ^{ text = [recorder.messageText copy]; });
	OAK_ASSERT([text isEqualToString:@"Exit: 0 one\ntwo\n"]);

	[session close];
}
