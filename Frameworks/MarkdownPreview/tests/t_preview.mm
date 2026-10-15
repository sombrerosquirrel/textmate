#import <MarkdownPreview/MarkdownPreviewViewController.h>

// Tests run on background threads, but views must be used on the main thread
static void RunOnMainThread (void(*test)())
{
	__block std::string error;
	dispatch_sync(dispatch_get_main_queue(), ^{
		try {
			test();
		}
		catch(std::exception const& e) {
			error = e.what();
		}
	});
	if(!error.empty())
		throw std::runtime_error(error);
}

static std::string S (NSString* str)
{
	return str ? std::string(str.UTF8String) : "«nil»";
}

static MarkdownPreviewViewController* MakePreview ()
{
	MarkdownPreviewViewController* preview = [[MarkdownPreviewViewController alloc] init];
	preview.view.frame = NSMakeRect(0, 0, 400, 300);
	[preview.view layoutSubtreeIfNeeded];
	return preview;
}

static void renders_markdown ()
{
	MarkdownPreviewViewController* preview = MakePreview();
	[preview showMarkdown:@"# Title\n\n- [x] done" baseURL:nil];
	OAK_ASSERT_EQ(S(preview.renderedText), "Title\n☑\tdone");
}

static void placeholder ()
{
	MarkdownPreviewViewController* preview = MakePreview();
	[preview showMarkdown:@"Text" baseURL:nil];
	[preview showPlaceholder:@"Not a Markdown document"];
	OAK_ASSERT_EQ(S(preview.renderedText), "Not a Markdown document");

	[preview showMarkdown:@"Back" baseURL:nil];
	OAK_ASSERT_EQ(S(preview.renderedText), "Back");
}

static void keeps_scroll_position ()
{
	NSMutableString* markdown = [NSMutableString string];
	for(NSUInteger i = 0; i < 200; ++i)
		[markdown appendFormat:@"Paragraph %lu\n\n", i];

	MarkdownPreviewViewController* preview = MakePreview();
	[preview showMarkdown:markdown baseURL:nil];
	OAK_ASSERT_EQ(preview.scrollFraction, 0);

	preview.scrollFraction = 0.5;
	OAK_ASSERT(fabs(preview.scrollFraction - 0.5) < 0.01);

	// Typing re-renders; the view mustn’t jump back to the top
	[markdown appendString:@"One more\n"];
	[preview showMarkdown:markdown baseURL:nil];
	OAK_ASSERT(fabs(preview.scrollFraction - 0.5) < 0.01);

	preview.scrollFraction = 2;
	OAK_ASSERT_EQ(preview.scrollFraction, 1);
}

static void switches_between_renderers ()
{
	MarkdownPreviewViewController* preview = MakePreview();
	[preview showHTML:@"<p>HTML</p>" documentURL:nil readAccessURL:nil];
	OAK_ASSERT(preview.showsHTML);

	[preview showMarkdown:@"Text" baseURL:nil];
	OAK_ASSERT(!preview.showsHTML);
	OAK_ASSERT_EQ(S(preview.renderedText), "Text");

	[preview showHTML:@"<p>HTML</p>" documentURL:nil readAccessURL:nil];
	[preview showPlaceholder:@"Not a Markdown document"];
	OAK_ASSERT(!preview.showsHTML);
}

static void notice ()
{
	MarkdownPreviewViewController* preview = MakePreview();
	OAK_ASSERT(preview.notice == nil);
	[preview showNotice:@"cmark-gfm isn’t installed." actionTitle:@"Install…"];
	OAK_ASSERT_EQ(S(preview.notice), "cmark-gfm isn’t installed.");
	[preview showNotice:nil actionTitle:nil];
	OAK_ASSERT(preview.notice == nil);
}

void test_renders_markdown () { RunOnMainThread(renders_markdown); }
void test_switches_between_renderers () { RunOnMainThread(switches_between_renderers); }
void test_notice () { RunOnMainThread(notice); }
void test_placeholder () { RunOnMainThread(placeholder); }
void test_keeps_scroll_position () { RunOnMainThread(keeps_scroll_position); }
