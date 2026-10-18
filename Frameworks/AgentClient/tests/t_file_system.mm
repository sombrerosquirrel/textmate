#import "agent_test_support.h"
#import "fake_document_provider.h"

static NSString* MakeProjectDirectory ()
{
	NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"agent-fs-%@", NSUUID.UUID.UUIDString]];
	[NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nullptr];
	return path;
}

static void WriteFile (NSString* path, NSString* text)
{
	[NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nullptr];
	[text writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nullptr];
}

static NSString* ReadFile (NSString* path)
{
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nullptr];
}

struct test_fs_t
{
	test_fs_t ()
	{
		project    = MakeProjectDirectory();
		provider   = [[FakeDocumentProvider alloc] init];
		fileSystem = [[AgentFileSystem alloc] initWithRootDirectory:project];
		fileSystem.documentProvider = provider;
	}

	~test_fs_t ()
	{
		[NSFileManager.defaultManager removeItemAtPath:project error:nullptr];
	}

	NSString* path (NSString* relative) { return [project stringByAppendingPathComponent:relative]; }

	NSString* project;
	FakeDocumentProvider* provider;
	AgentFileSystem* fileSystem;
};

void test_read_from_disk ()
{
	test_fs_t t;
	WriteFile(t.path(@"a.txt"), @"one\ntwo\nthree\nfour\n");

	OAK_ASSERT([[t.fileSystem readTextFileAtPath:t.path(@"a.txt") line:0 limit:0 error:nullptr] isEqualToString:@"one\ntwo\nthree\nfour\n"]);
	OAK_ASSERT([[t.fileSystem readTextFileAtPath:t.path(@"a.txt") line:2 limit:2 error:nullptr] isEqualToString:@"two\nthree\n"]);
	OAK_ASSERT([[t.fileSystem readTextFileAtPath:t.path(@"a.txt") line:0 limit:1 error:nullptr] isEqualToString:@"one\n"]);
	OAK_ASSERT([[t.fileSystem readTextFileAtPath:t.path(@"a.txt") line:4 limit:0 error:nullptr] isEqualToString:@"four\n"]);
	OAK_ASSERT([[t.fileSystem readTextFileAtPath:t.path(@"a.txt") line:9 limit:0 error:nullptr] isEqualToString:@""]);

	NSError* error;
	OAK_ASSERT([t.fileSystem readTextFileAtPath:t.path(@"missing.txt") line:0 limit:0 error:&error] == nil);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentFileSystemErrorNotFound);
}

void test_read_open_document_first ()
{
	test_fs_t t;
	WriteFile(t.path(@"a.txt"), @"saved");
	t.provider.documents[t.path(@"a.txt")] = @"unsaved\nedit";

	OAK_ASSERT([[t.fileSystem readTextFileAtPath:t.path(@"a.txt") line:0 limit:0 error:nullptr] isEqualToString:@"unsaved\nedit"]);
	OAK_ASSERT([[t.fileSystem readTextFileAtPath:t.path(@"a.txt") line:2 limit:0 error:nullptr] isEqualToString:@"edit"]);
}

void test_project_boundary ()
{
	test_fs_t t;
	NSString* outside = MakeProjectDirectory();
	WriteFile([outside stringByAppendingPathComponent:@"secret.txt"], @"secret");
	[NSFileManager.defaultManager createSymbolicLinkAtPath:t.path(@"link") withDestinationPath:outside error:nullptr];

	OAK_ASSERT([t.fileSystem isPathAllowed:t.path(@"a.txt")]);
	OAK_ASSERT([t.fileSystem isPathAllowed:t.path(@"new/dir/b.txt")]);
	OAK_ASSERT(![t.fileSystem isPathAllowed:@"relative.txt"]);
	OAK_ASSERT(![t.fileSystem isPathAllowed:[outside stringByAppendingPathComponent:@"secret.txt"]]);
	OAK_ASSERT(![t.fileSystem isPathAllowed:[t.project stringByAppendingString:@"/../x.txt"]]);
	OAK_ASSERT(![t.fileSystem isPathAllowed:[t.project stringByAppendingString:@"-sibling/x.txt"]]);
	OAK_ASSERT(![t.fileSystem isPathAllowed:t.path(@"link/secret.txt")]);
	OAK_ASSERT(![t.fileSystem isPathAllowed:t.path(@"link/new.txt")]);

	NSError* error;
	OAK_ASSERT(![t.fileSystem writeText:@"x" toFileAtPath:t.path(@"link/new.txt") error:&error]);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentFileSystemErrorOutsideProject);
	OAK_ASSERT(![NSFileManager.defaultManager fileExistsAtPath:[outside stringByAppendingPathComponent:@"new.txt"]]);

	t.fileSystem.additionalDirectories = @[ outside ];
	OAK_ASSERT([t.fileSystem isPathAllowed:[outside stringByAppendingPathComponent:@"secret.txt"]]);

	[NSFileManager.defaultManager removeItemAtPath:outside error:nullptr];
}

void test_write_to_disk_and_open_document ()
{
	test_fs_t t;
	WriteFile(t.path(@"disk.txt"), @"old");
	WriteFile(t.path(@"open.txt"), @"saved");
	t.provider.documents[t.path(@"open.txt")] = @"unsaved";

	OAK_ASSERT([t.fileSystem writeText:@"new" toFileAtPath:t.path(@"disk.txt") error:nullptr]);
	OAK_ASSERT([ReadFile(t.path(@"disk.txt")) isEqualToString:@"new"]);

	// Open documents are edited in place and left unsaved
	OAK_ASSERT([t.fileSystem writeText:@"agent" toFileAtPath:t.path(@"open.txt") error:nullptr]);
	OAK_ASSERT([t.provider.documents[t.path(@"open.txt")] isEqualToString:@"agent"]);
	OAK_ASSERT([ReadFile(t.path(@"open.txt")) isEqualToString:@"saved"]);

	// New files and folders are created
	OAK_ASSERT([t.fileSystem writeText:@"created" toFileAtPath:t.path(@"sub/dir/new.txt") error:nullptr]);
	OAK_ASSERT([ReadFile(t.path(@"sub/dir/new.txt")) isEqualToString:@"created"]);
}

void test_changes ()
{
	test_fs_t t;
	WriteFile(t.path(@"a.txt"), @"a1");
	t.provider.documents[t.path(@"b.txt")] = @"b1";

	OAK_ASSERT([t.fileSystem writeText:@"a2" toFileAtPath:t.path(@"a.txt") error:nullptr]);
	OAK_ASSERT([t.fileSystem writeText:@"a3" toFileAtPath:t.path(@"a.txt") error:nullptr]);
	OAK_ASSERT([t.fileSystem writeText:@"b2" toFileAtPath:t.path(@"b.txt") error:nullptr]);
	OAK_ASSERT([t.fileSystem writeText:@"c1" toFileAtPath:t.path(@"c.txt") error:nullptr]);

	NSArray<AgentFileChange*>* changes = t.fileSystem.changes;
	OAK_ASSERT_EQ(changes.count, 3);
	OAK_ASSERT([changes[0].originalText isEqualToString:@"a1"]);
	OAK_ASSERT([changes[0].currentText isEqualToString:@"a3"]);
	OAK_ASSERT([changes[1].originalText isEqualToString:@"b1"]);
	OAK_ASSERT(changes[2].originalText == nil);

	// Undo restores the original, in the open document or on disk
	OAK_ASSERT([t.fileSystem undoChange:changes[0] force:NO error:nullptr]);
	OAK_ASSERT([ReadFile(t.path(@"a.txt")) isEqualToString:@"a1"]);
	OAK_ASSERT([t.fileSystem undoChange:changes[1] force:NO error:nullptr]);
	OAK_ASSERT([t.provider.documents[t.path(@"b.txt")] isEqualToString:@"b1"]);

	// A created file goes to the Trash
	OAK_ASSERT([t.fileSystem undoChange:changes[2] force:NO error:nullptr]);
	OAK_ASSERT(![NSFileManager.defaultManager fileExistsAtPath:t.path(@"c.txt")]);
	OAK_ASSERT_EQ(t.fileSystem.changes.count, 0);
}

void test_keep_and_write_back ()
{
	test_fs_t t;
	WriteFile(t.path(@"a.txt"), @"a1");
	WriteFile(t.path(@"b.txt"), @"b1");

	OAK_ASSERT([t.fileSystem writeText:@"a2" toFileAtPath:t.path(@"a.txt") error:nullptr]);
	OAK_ASSERT([t.fileSystem writeText:@"b2" toFileAtPath:t.path(@"b.txt") error:nullptr]);
	[t.fileSystem keepChange:t.fileSystem.changes.firstObject];
	OAK_ASSERT_EQ(t.fileSystem.changes.count, 1);
	OAK_ASSERT([ReadFile(t.path(@"a.txt")) isEqualToString:@"a2"]);

	// Writing the original text back leaves nothing to review
	OAK_ASSERT([t.fileSystem writeText:@"b1" toFileAtPath:t.path(@"b.txt") error:nullptr]);
	OAK_ASSERT_EQ(t.fileSystem.changes.count, 0);
}

void test_undo_after_user_edit ()
{
	test_fs_t t;
	t.provider.documents[t.path(@"a.txt")] = @"a1";
	OAK_ASSERT([t.fileSystem writeText:@"a2" toFileAtPath:t.path(@"a.txt") error:nullptr]);
	AgentFileChange* change = t.fileSystem.changes.firstObject;
	OAK_ASSERT(![t.fileSystem hasFileChangedSinceChange:change]);

	t.provider.documents[t.path(@"a.txt")] = @"a2 and the user’s edit";
	OAK_ASSERT([t.fileSystem hasFileChangedSinceChange:change]);

	NSError* error;
	OAK_ASSERT(![t.fileSystem undoChange:change force:NO error:&error]);
	OAK_ASSERT_EQ((NSInteger)error.code, (NSInteger)AgentFileSystemErrorChangedSince);
	OAK_ASSERT([t.provider.documents[t.path(@"a.txt")] hasPrefix:@"a2 and"]);

	OAK_ASSERT([t.fileSystem undoChange:change force:YES error:nullptr]);
	OAK_ASSERT([t.provider.documents[t.path(@"a.txt")] isEqualToString:@"a1"]);
}

// =================================
// = Requests from the fake agent =
// =================================

void test_session_file_requests ()
{
	test_fs_t fs;
	WriteFile(fs.path(@"a.txt"), @"one\ntwo\nthree\n");

	dispatch_queue_t queue = TestQueue();
	AgentTestRecorder* recorder = [[AgentTestRecorder alloc] init];
	AgentSession* session = [[AgentSession alloc] initWithConnection:FakeAgentConnection(queue) workingDirectory:fs.project];
	session.delegate   = recorder;
	session.fileSystem = fs.fileSystem;

	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[session startWithCompletion:^(NSError* error){ dispatch_semaphore_signal(done); }];
	OAK_ASSERT(Wait(done));

	auto prompt = [&](NSString* text) -> NSString* {
		dispatch_sync(queue, ^{ [recorder.messageText setString:@""]; });
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		[session sendPrompt:TextPrompt(text) completion:^(NSString* stopReason, NSError* error){ dispatch_semaphore_signal(done); }];
		OAK_ASSERT(Wait(done));
		__block NSString* res;
		dispatch_sync(queue, ^{ res = [recorder.messageText copy]; });
		return res;
	};

	OAK_ASSERT([prompt([@"read " stringByAppendingString:fs.path(@"a.txt")]) isEqualToString:@"Read: one\ntwo\nthree\n"]);
	OAK_ASSERT([prompt([NSString stringWithFormat:@"read %@ 2 1", fs.path(@"a.txt")]) isEqualToString:@"Read: two\n"]);
	OAK_ASSERT([prompt([@"read " stringByAppendingString:fs.path(@"missing.txt")]) isEqualToString:@"Error: -32002"]);
	OAK_ASSERT([prompt(@"read /etc/hosts") isEqualToString:@"Error: -32603"]);

	OAK_ASSERT([prompt([NSString stringWithFormat:@"write %@ hello\nworld", fs.path(@"b.txt")]) isEqualToString:@"Wrote"]);
	OAK_ASSERT([ReadFile(fs.path(@"b.txt")) isEqualToString:@"hello\nworld"]);
	__block NSUInteger changeCount;
	dispatch_sync(queue, ^{ changeCount = fs.fileSystem.changes.count; });
	OAK_ASSERT_EQ(changeCount, 1);

	[session close];
}

void test_session_without_file_system ()
{
	dispatch_queue_t queue = TestQueue();
	AgentTestRecorder* recorder = [[AgentTestRecorder alloc] init];
	AgentSession* session = [[AgentSession alloc] initWithConnection:FakeAgentConnection(queue) workingDirectory:@"/tmp/project"];
	session.delegate = recorder;

	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[session startWithCompletion:^(NSError* error){ dispatch_semaphore_signal(done); }];
	OAK_ASSERT(Wait(done));

	[session sendPrompt:TextPrompt(@"read /tmp/project/a.txt") completion:^(NSString* stopReason, NSError* error){ dispatch_semaphore_signal(done); }];
	OAK_ASSERT(Wait(done));
	__block NSString* text;
	dispatch_sync(queue, ^{ text = [recorder.messageText copy]; });
	OAK_ASSERT([text isEqualToString:@"Error: no capability"]);

	[session close];
}

// =====================================
// = Edits the agent makes on its own =
// =====================================

void test_external_changes ()
{
	test_fs_t t;
	WriteFile(t.path(@"a.txt"), @"a1");
	WriteFile(t.path(@"gone.txt"), @"bye");

	[t.fileSystem willChangeFileAtPath:t.path(@"a.txt")];
	[t.fileSystem willChangeFileAtPath:t.path(@"new.txt")];
	[t.fileSystem willChangeFileAtPath:t.path(@"gone.txt")];
	[t.fileSystem willChangeFileAtPath:t.path(@"same.txt")];
	WriteFile(t.path(@"a.txt"), @"a2");
	WriteFile(t.path(@"new.txt"), @"created");
	[NSFileManager.defaultManager removeItemAtPath:t.path(@"gone.txt") error:nullptr];
	[t.fileSystem didChangeFileAtPath:t.path(@"a.txt")];
	[t.fileSystem didChangeFileAtPath:t.path(@"new.txt")];
	[t.fileSystem didChangeFileAtPath:t.path(@"gone.txt")];
	[t.fileSystem didChangeFileAtPath:t.path(@"same.txt")]; // unchanged: not listed
	[t.fileSystem didChangeFileAtPath:t.path(@"unknown.txt")]; // no snapshot: ignored

	NSArray<AgentFileChange*>* changes = t.fileSystem.changes;
	OAK_ASSERT_EQ(changes.count, 3);
	OAK_ASSERT(changes[0].isExternal);
	OAK_ASSERT([changes[0].originalText isEqualToString:@"a1"] && [changes[0].currentText isEqualToString:@"a2"]);
	OAK_ASSERT(changes[1].originalText == nil && [changes[1].currentText isEqualToString:@"created"]);
	OAK_ASSERT([changes[2].originalText isEqualToString:@"bye"] && changes[2].currentText == nil);

	// A second edit keeps the first original, and reports the text just before it
	[t.fileSystem willChangeFileAtPath:t.path(@"a.txt")];
	WriteFile(t.path(@"a.txt"), @"a3");
	NSString* previousText;
	OAK_ASSERT([t.fileSystem didChangeFileAtPath:t.path(@"a.txt") previousText:&previousText]);
	OAK_ASSERT([previousText isEqualToString:@"a2"]);
	OAK_ASSERT_EQ(t.fileSystem.changes.count, 3);
	OAK_ASSERT([t.fileSystem.changes[0].originalText isEqualToString:@"a1"] && [t.fileSystem.changes[0].currentText isEqualToString:@"a3"]);

	// Undo writes the disk, even when the file is open (the editor reloads it)
	t.provider.documents[t.path(@"a.txt")] = @"a3";
	OAK_ASSERT([t.fileSystem undoChange:t.fileSystem.changes[0] force:NO error:nullptr]);
	OAK_ASSERT([ReadFile(t.path(@"a.txt")) isEqualToString:@"a1"]);
	OAK_ASSERT([t.fileSystem undoChange:t.fileSystem.changes[0] force:NO error:nullptr]); // new.txt
	OAK_ASSERT(![NSFileManager.defaultManager fileExistsAtPath:t.path(@"new.txt")]);
	OAK_ASSERT([t.fileSystem undoChange:t.fileSystem.changes[0] force:NO error:nullptr]); // gone.txt
	OAK_ASSERT([ReadFile(t.path(@"gone.txt")) isEqualToString:@"bye"]);
}

void test_external_change_after_client_write ()
{
	test_fs_t t;
	WriteFile(t.path(@"a.txt"), @"a1");
	t.provider.documents[t.path(@"a.txt")] = @"a1";

	// An agent that writes through the client also reports the tool call
	[t.fileSystem willChangeFileAtPath:t.path(@"a.txt")];
	OAK_ASSERT([t.fileSystem writeText:@"a2" toFileAtPath:t.path(@"a.txt") error:nullptr]);
	[t.fileSystem didChangeFileAtPath:t.path(@"a.txt")];

	OAK_ASSERT_EQ(t.fileSystem.changes.count, 1);
	OAK_ASSERT(!t.fileSystem.changes[0].isExternal);
	OAK_ASSERT([t.fileSystem.changes[0].currentText isEqualToString:@"a2"]);
}

void test_external_changes_outside_project ()
{
	test_fs_t t;
	[t.fileSystem willChangeFileAtPath:@"/etc/hosts"];
	[t.fileSystem didChangeFileAtPath:@"/etc/hosts"];
	OAK_ASSERT_EQ(t.fileSystem.changes.count, 0);
}
