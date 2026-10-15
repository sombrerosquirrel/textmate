#import <MarkdownPreview/MarkdownPreviewCmark.h>

static NSDictionary* const kEnvironment = @{ @"PATH": @"/usr/bin:/bin" };

void test_arguments ()
{
	NSArray* arguments = [MarkdownPreviewCmark argumentsAllowingRawHTML:NO];
	OAK_ASSERT([arguments containsObject:@"--sourcepos"]);
	OAK_ASSERT([arguments containsObject:@"table"]);
	OAK_ASSERT([arguments containsObject:@"tasklist"]);
	OAK_ASSERT(![arguments containsObject:@"--unsafe"]);
	OAK_ASSERT([[MarkdownPreviewCmark argumentsAllowingRawHTML:YES] containsObject:@"--unsafe"]);
}

void test_pipes_markdown_through_command ()
{
	NSString* error;
	OAK_ASSERT([[MarkdownPreviewCmark HTMLFromMarkdown:@"# Café ☕︎\n" executable:@"/bin/cat" arguments:@[ ] environment:kEnvironment error:&error] isEqualToString:@"# Café ☕︎\n"]);

	// Larger than a pipe’s buffer, in both directions
	NSString* large = [@"" stringByPaddingToLength:1024*1024 withString:@"Lorem ipsum dolor sit amet.\n" startingAtIndex:0];
	OAK_ASSERT_EQ([MarkdownPreviewCmark HTMLFromMarkdown:large executable:@"/bin/cat" arguments:@[ ] environment:kEnvironment error:&error].length, large.length);
}

void test_reports_errors ()
{
	NSString* error;
	NSArray* arguments = @[ @"-c", @"echo 'bad option' >&2; exit 3" ];
	OAK_ASSERT([MarkdownPreviewCmark HTMLFromMarkdown:@"text" executable:@"/bin/sh" arguments:arguments environment:kEnvironment error:&error] == nil);
	OAK_ASSERT([error isEqualToString:@"bad option"]);

	error = nil;
	OAK_ASSERT([MarkdownPreviewCmark HTMLFromMarkdown:@"text" executable:@"/usr/bin/false" arguments:@[ ] environment:kEnvironment error:&error] == nil);
	OAK_ASSERT([error isEqualToString:@"false exited with status 1."]);

	error = nil;
	OAK_ASSERT([MarkdownPreviewCmark HTMLFromMarkdown:@"text" executable:@"/nonexistent/cmark-gfm" arguments:@[ ] environment:kEnvironment error:&error] == nil);
	OAK_ASSERT(error.length > 0);

	// A command that exits without reading its input
	error = nil;
	NSString* large = [@"" stringByPaddingToLength:1024*1024 withString:@"x" startingAtIndex:0];
	OAK_ASSERT([[MarkdownPreviewCmark HTMLFromMarkdown:large executable:@"/bin/echo" arguments:@[ @"done" ] environment:kEnvironment error:&error] isEqualToString:@"done\n"]);
}

void test_cmark_gfm ()
{
	NSString* path = [MarkdownPreviewCmark executablePathInEnvironment:NSProcessInfo.processInfo.environment];
	if(!path)
		return; // not installed

	NSString* error;
	NSString* markdown = @"# Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n<b>raw</b>\n";
	NSString* html = [MarkdownPreviewCmark HTMLFromMarkdown:markdown executable:path arguments:[MarkdownPreviewCmark argumentsAllowingRawHTML:NO] environment:kEnvironment error:&error];
	OAK_ASSERT(html != nil);
	OAK_ASSERT([html containsString:@"<h1 data-sourcepos=\"1:1-1:7\">Title</h1>"]);
	OAK_ASSERT([html containsString:@"<table"]);
	OAK_ASSERT([html containsString:@"type=\"checkbox\""]);
	OAK_ASSERT(![html containsString:@"<b>raw</b>"]);

	html = [MarkdownPreviewCmark HTMLFromMarkdown:markdown executable:path arguments:[MarkdownPreviewCmark argumentsAllowingRawHTML:YES] environment:kEnvironment error:&error];
	OAK_ASSERT([html containsString:@"<b>raw</b>"]);
}
