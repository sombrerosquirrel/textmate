#import <MarkdownPreview/MarkdownPreviewDocument.h>

void test_markdown_documents ()
{
	OAK_ASSERT(MarkdownPreviewIsMarkdownDocument(@"text.html.markdown", nil));
	OAK_ASSERT(MarkdownPreviewIsMarkdownDocument(@"text.html.markdown.gfm", @"/tmp/notes.txt"));
	OAK_ASSERT(MarkdownPreviewIsMarkdownDocument(nil, @"/tmp/README.MD"));
	OAK_ASSERT(MarkdownPreviewIsMarkdownDocument(@"text.plain", @"/tmp/notes.markdown"));

	OAK_ASSERT(!MarkdownPreviewIsMarkdownDocument(@"text.html.basic", @"/tmp/index.html"));
	OAK_ASSERT(!MarkdownPreviewIsMarkdownDocument(@"source.c++", @"/tmp/md"));
	OAK_ASSERT(!MarkdownPreviewIsMarkdownDocument(nil, nil));
}

void test_read_access_url ()
{
	OAK_ASSERT([MarkdownPreviewReadAccessURL(@"/p/docs/a.md", @"/p").path isEqualToString:@"/p"]);
	OAK_ASSERT([MarkdownPreviewReadAccessURL(@"/p/a.md", @"/p/").path isEqualToString:@"/p"]);

	// Outside the project, including a folder that only starts with its name
	OAK_ASSERT([MarkdownPreviewReadAccessURL(@"/q/notes/a.md", @"/p").path isEqualToString:@"/q/notes"]);
	OAK_ASSERT([MarkdownPreviewReadAccessURL(@"/project2/a.md", @"/project").path isEqualToString:@"/project2"]);
	OAK_ASSERT([MarkdownPreviewReadAccessURL(@"/q/a.md", nil).path isEqualToString:@"/q"]);

	OAK_ASSERT(MarkdownPreviewReadAccessURL(nil, @"/p") == nil);
}
