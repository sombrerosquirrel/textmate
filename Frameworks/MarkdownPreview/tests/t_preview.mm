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

static void footnote_links_scroll_preview ()
{
	NSMutableString* markdown = [NSMutableString stringWithString:@"See the note[^1] and [another file](other.md).\n\n"];
	for(NSUInteger i = 0; i < 200; ++i)
		[markdown appendFormat:@"Paragraph %lu\n\n", i];
	[markdown appendString:@"[^1]: The note.\n"];

	NSURL* document = [NSURL fileURLWithPath:@"/tmp/project/README.md"];
	MarkdownPreviewViewController* preview = MakePreview();
	[preview showMarkdown:markdown baseURL:document];

	// The preview is its text view’s delegate
	id<NSTextViewDelegate> textViewDelegate = (id<NSTextViewDelegate>)preview;
	NSTextView* textView = [[NSTextView alloc] init];
	[textViewDelegate textView:textView clickedOnLink:[NSURL URLWithString:@"#fn-1" relativeToURL:document] atIndex:0];
	OAK_ASSERT(preview.scrollFraction > 0.9);

	[textViewDelegate textView:textView clickedOnLink:[NSURL URLWithString:@"#fnref-1" relativeToURL:document] atIndex:0];
	OAK_ASSERT(preview.scrollFraction < 0.01); // the reference, with a small margin above it

	// A footnote in another file doesn’t scroll this one
	preview.scrollFraction = 0.5;
	[textViewDelegate textView:textView clickedOnLink:[NSURL URLWithString:@"other.md#fn-1" relativeToURL:document] atIndex:0];
	OAK_ASSERT(fabs(preview.scrollFraction - 0.5) < 0.01);
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

static void scrolls_to_source_line ()
{
	NSMutableString* markdown = [NSMutableString string];
	for(NSUInteger i = 0; i < 200; ++i)
		[markdown appendFormat:@"Paragraph %lu\n\n", i]; // paragraph i is on line 2i+1

	MarkdownPreviewViewController* preview = MakePreview();
	[preview showMarkdown:markdown baseURL:nil];

	NSTextView* textView = nil;
	NSMutableArray* queue = [NSMutableArray arrayWithObject:preview.view];
	while(queue.count && !textView)
	{
		NSView* view = queue.firstObject;
		[queue removeObjectAtIndex:0];
		if([view isKindOfClass:[NSTextView class]])
			textView = (NSTextView*)view;
		[queue addObjectsFromArray:view.subviews];
	}
	OAK_ASSERT(textView != nil);

	auto topOfParagraph = [&](NSUInteger i) -> CGFloat {
		NSRange range = [textView.string rangeOfString:[NSString stringWithFormat:@"Paragraph %lu\n", i]];
		NSUInteger glyph = [textView.layoutManager glyphIndexForCharacterAtIndex:range.location];
		return NSMinY([textView.layoutManager lineFragmentRectForGlyphAtIndex:glyph effectiveRange:nullptr]) + textView.textContainerOrigin.y;
	};
	auto scrollY = [&]() -> CGFloat { return NSMinY(textView.enclosingScrollView.contentView.bounds); };

	// The editor maps its position between these lines
	NSArray<NSNumber*>* anchorLines = preview.anchorLines;
	OAK_ASSERT_EQ(anchorLines.firstObject.intValue, 1);
	OAK_ASSERT([anchorLines containsObject:@101]);
	for(NSUInteger i = 1; i < anchorLines.count; ++i)
		OAK_ASSERT(anchorLines[i-1].doubleValue < anchorLines[i].doubleValue);

	// Line 101 is paragraph 50: it should be at the top
	[preview scrollToSourceLine:101 fraction:0];
	OAK_ASSERT(fabs(scrollY() - topOfParagraph(50)) < 1);

	// Halfway to the next paragraph, whatever the fraction says
	[preview scrollToSourceLine:102 fraction:0.9];
	OAK_ASSERT(fabs(scrollY() - (topOfParagraph(50) + topOfParagraph(51)) / 2) < 1);
}

void test_renders_markdown () { RunOnMainThread(renders_markdown); }
void test_scrolls_to_source_line () { RunOnMainThread(scrolls_to_source_line); }
void test_switches_between_renderers () { RunOnMainThread(switches_between_renderers); }
void test_notice () { RunOnMainThread(notice); }
void test_placeholder () { RunOnMainThread(placeholder); }
void test_keeps_scroll_position () { RunOnMainThread(keeps_scroll_position); }
void test_footnote_links_scroll_preview () { RunOnMainThread(footnote_links_scroll_preview); }
