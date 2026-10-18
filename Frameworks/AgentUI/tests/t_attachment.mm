#import <AgentUI/AgentAttachment.h>

static NSDictionary* const kEmbedded = @{ @"embeddedContext": @YES, @"image": @YES };
static NSDictionary* const kBasic    = @{ };

void test_file_attachment ()
{
	AgentAttachment* file = [AgentAttachment fileAttachmentWithPath:@"/tmp/project/main.cc" text:@"int main () { }"];
	OAK_ASSERT([file.name isEqualToString:@"main.cc"]);

	NSDictionary* embedded = [file contentBlockWithPromptCapabilities:kEmbedded];
	OAK_ASSERT([embedded[@"type"] isEqualToString:@"resource"]);
	OAK_ASSERT([embedded[@"resource"][@"uri"] isEqualToString:@"file:///tmp/project/main.cc"]);
	OAK_ASSERT([embedded[@"resource"][@"text"] isEqualToString:@"int main () { }"]);

	NSDictionary* link = [file contentBlockWithPromptCapabilities:kBasic];
	OAK_ASSERT([link[@"type"] isEqualToString:@"resource_link"]);
	OAK_ASSERT([link[@"name"] isEqualToString:@"main.cc"]);
}

void test_file_read_from_disk ()
{
	NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"agent-attachment-%@.txt", NSUUID.UUID.UUIDString]];
	[@"on disk" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

	NSDictionary* block = [[AgentAttachment fileAttachmentWithPath:path text:nil] contentBlockWithPromptCapabilities:kEmbedded];
	OAK_ASSERT([block[@"resource"][@"text"] isEqualToString:@"on disk"]);
	[NSFileManager.defaultManager removeItemAtPath:path error:nil];

	// A file that can’t be read falls back to a link
	NSDictionary* missing = [[AgentAttachment fileAttachmentWithPath:@"/nonexistent/file.txt" text:nil] contentBlockWithPromptCapabilities:kEmbedded];
	OAK_ASSERT([missing[@"type"] isEqualToString:@"resource_link"]);
}

void test_file_attachment_with_cursor ()
{
	AgentAttachment* file = [AgentAttachment fileAttachmentWithPath:@"/tmp/project/main.cc" text:@"int main () { }" cursorLine:42 column:7];
	OAK_ASSERT([file.name isEqualToString:@"main.cc:42:7"]);

	NSArray* blocks = [file contentBlocksWithPromptCapabilities:kEmbedded];
	OAK_ASSERT_EQ(blocks.count, 2);
	OAK_ASSERT([blocks[0][@"type"] isEqualToString:@"resource"]);
	OAK_ASSERT([blocks[1][@"text"] isEqualToString:@"The cursor is at line 42, column 7 of /tmp/project/main.cc."]);

	NSArray* prompt = [AgentAttachment promptWithText:@"Add a comment here" attachments:@[ file ] promptCapabilities:kBasic];
	OAK_ASSERT_EQ(prompt.count, 3);
	OAK_ASSERT([prompt[1][@"type"] isEqualToString:@"resource_link"]);
	OAK_ASSERT([prompt[2][@"text"] hasPrefix:@"The cursor is at line 42"]);

	// Without a cursor there’s no note
	OAK_ASSERT_EQ([[AgentAttachment fileAttachmentWithPath:@"/tmp/b.txt" text:@"b"] contentBlocksWithPromptCapabilities:kBasic].count, 1);
}

void test_prompt_with_current_file ()
{
	AgentAttachment* current = [AgentAttachment fileAttachmentWithPath:@"/tmp/project/main.cc" text:@"int main () { }" cursorLine:3 column:1];
	NSArray* prompt = [AgentAttachment promptWithText:@"Add a comment here" attachments:@[ ] currentFile:current promptCapabilities:kEmbedded];
	OAK_ASSERT_EQ(prompt.count, 2); // the file’s contents aren’t sent
	OAK_ASSERT([prompt[1][@"text"] isEqualToString:@"The user has /tmp/project/main.cc open in the editor, with the cursor at line 3, column 1. Unless they say otherwise, “this file”, “here” and requests that don’t name a file refer to it."]);

	// Attaching the current file with its cursor already says where the user is
	prompt = [AgentAttachment promptWithText:@"Explain" attachments:@[ current ] currentFile:current promptCapabilities:kEmbedded];
	OAK_ASSERT_EQ(prompt.count, 3);
	OAK_ASSERT([prompt[2][@"text"] hasPrefix:@"The cursor is at"]);

	// Another attached file doesn’t replace the note
	AgentAttachment* other = [AgentAttachment fileAttachmentWithPath:@"/tmp/project/other.cc" text:@"x"];
	prompt = [AgentAttachment promptWithText:@"Compare" attachments:@[ other ] currentFile:current promptCapabilities:kEmbedded];
	OAK_ASSERT_EQ(prompt.count, 3);
	OAK_ASSERT([prompt[2][@"text"] hasPrefix:@"The user has /tmp/project/main.cc open"]);

	// Untitled documents have no path to name
	AgentAttachment* untitled = [AgentAttachment fileAttachmentWithPath:nil text:@"x"];
	OAK_ASSERT_EQ([AgentAttachment promptWithText:@"Hi" attachments:@[ ] currentFile:untitled promptCapabilities:kBasic].count, 1);
}

void test_selection_attachment ()
{
	AgentAttachment* selection = [AgentAttachment selectionAttachmentWithPath:@"/tmp/a.py" displayName:nil text:@"x = 1" firstLine:3 lastLine:4];
	OAK_ASSERT([selection.name isEqualToString:@"a.py:3–4"]);

	NSDictionary* embedded = [selection contentBlockWithPromptCapabilities:kEmbedded];
	OAK_ASSERT([embedded[@"resource"][@"uri"] isEqualToString:@"file:///tmp/a.py#L3-4"]);
	OAK_ASSERT([embedded[@"resource"][@"text"] isEqualToString:@"x = 1"]);

	NSDictionary* text = [selection contentBlockWithPromptCapabilities:kBasic];
	OAK_ASSERT([text[@"type"] isEqualToString:@"text"]);
	OAK_ASSERT([text[@"text"] isEqualToString:@"Selection from /tmp/a.py (lines 3–4):\n```\nx = 1\n```"]);

	AgentAttachment* untitled = [AgentAttachment selectionAttachmentWithPath:nil displayName:@"untitled" text:@"y" firstLine:1 lastLine:1];
	OAK_ASSERT([untitled.name isEqualToString:@"untitled:1"]);
	OAK_ASSERT([[untitled contentBlockWithPromptCapabilities:kEmbedded][@"resource"][@"uri"] isEqualToString:@"untitled:untitled:1"]);
}

void test_image_attachment ()
{
	NSData* png = [@"png" dataUsingEncoding:NSUTF8StringEncoding];
	AgentAttachment* image = [AgentAttachment imageAttachmentWithPNGData:png name:@"Screenshot"];
	NSDictionary* block = [image contentBlockWithPromptCapabilities:kEmbedded];
	OAK_ASSERT([block[@"type"] isEqualToString:@"image"]);
	OAK_ASSERT([block[@"data"] isEqualToString:@"cG5n"]);
	OAK_ASSERT([image contentBlockWithPromptCapabilities:kBasic] == nil);
}

void test_prompt ()
{
	NSArray* attachments = @[
		[AgentAttachment fileAttachmentWithPath:@"/tmp/b.txt" text:@"b"],
		[AgentAttachment imageAttachmentWithPNGData:[NSData data] name:@"img"],
	];
	NSArray* prompt = [AgentAttachment promptWithText:@"Explain" attachments:attachments promptCapabilities:kBasic];
	OAK_ASSERT_EQ(prompt.count, 2); // the image is dropped without the capability
	OAK_ASSERT([prompt[0][@"text"] isEqualToString:@"Explain"]);
	OAK_ASSERT([prompt[1][@"type"] isEqualToString:@"resource_link"]);

	OAK_ASSERT_EQ([AgentAttachment promptWithText:@"" attachments:@[ ] promptCapabilities:kBasic].count, 0);
}
