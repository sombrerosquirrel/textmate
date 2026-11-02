#import <MarkdownPreview/MarkdownPreviewViewController.h>
#import "preview_scroll_recorder.h"

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

static void reports_anchors_and_scrolls ()
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

	// The editor maps its position through these
	NSArray<NSValue*>* anchors = preview.anchors;
	OAK_ASSERT_EQ(anchors.firstObject.pointValue.x, 1);
	for(NSUInteger i = 1; i < anchors.count; ++i)
	{
		OAK_ASSERT(anchors[i-1].pointValue.x < anchors[i].pointValue.x);
		OAK_ASSERT(anchors[i-1].pointValue.y < anchors[i].pointValue.y);
	}
	NSUInteger line101 = [anchors indexOfObjectPassingTest:^BOOL(NSValue* anchor, NSUInteger i, BOOL* stop){ return anchor.pointValue.x == 101; }];
	OAK_ASSERT(line101 != NSNotFound);
	OAK_ASSERT(fabs(anchors[line101].pointValue.y - topOfParagraph(50)) < 1); // line 101 is paragraph 50

	[preview scrollToPosition:topOfParagraph(50) animated:NO];
	OAK_ASSERT(fabs(scrollY() - topOfParagraph(50)) < 1);

	// Not in a window: animating jumps
	[preview scrollToPosition:topOfParagraph(60) animated:YES];
	OAK_ASSERT(fabs(scrollY() - topOfParagraph(60)) < 1);

	[preview scrollToFraction:1 animated:NO];
	OAK_ASSERT(preview.scrollFraction > 0.99);
}

static void reports_user_scrolling ()
{
	NSMutableString* markdown = [NSMutableString string];
	for(NSUInteger i = 0; i < 200; ++i)
		[markdown appendFormat:@"Paragraph %lu\n\n", i];

	PreviewScrollRecorder* recorder = [[PreviewScrollRecorder alloc] init];
	recorder.positions = [NSMutableArray array];
	MarkdownPreviewViewController* preview = MakePreview();
	preview.delegate = recorder;
	[preview showMarkdown:markdown baseURL:nil];

	NSScrollView* scrollView = nil;
	NSMutableArray* queue = [NSMutableArray arrayWithObject:preview.view];
	while(queue.count && !scrollView)
	{
		NSView* view = queue.firstObject;
		[queue removeObjectAtIndex:0];
		if([view isKindOfClass:[NSScrollView class]])
			scrollView = (NSScrollView*)view;
		[queue addObjectsFromArray:view.subviews];
	}
	OAK_ASSERT(scrollView != nil);

	// Following the editor, or re-rendering, isn’t reported
	[preview scrollToPosition:300 animated:NO];
	[preview showMarkdown:[markdown stringByAppendingString:@"More\n"] baseURL:nil];
	OAK_ASSERT_EQ(recorder.positions.count, 0);

	// The user scrolling is
	[scrollView.contentView scrollToPoint:NSMakePoint(0, 500)];
	OAK_ASSERT_EQ(recorder.positions.count, 1);
	OAK_ASSERT(fabs(recorder.positions.lastObject.doubleValue - 500) < 1);
}

// The GitHub view scrolls like the built-in one. Its page loads on the main
// thread, so this runs on the test thread and only uses the views there.
void test_github_view_scrolls_as_the_built_in_one ()
{
	__block MarkdownPreviewViewController* preview;
	__block NSScrollView* scrollView;
	PreviewScrollRecorder* recorder = [[PreviewScrollRecorder alloc] init];
	recorder.positions = [NSMutableArray array];

	NSMutableString* html = [NSMutableString string];
	for(NSUInteger i = 0; i < 200; ++i)
		[html appendFormat:@"<p data-sourcepos=\"%1$lu:1-%1$lu:10\">Paragraph %1$lu</p>\n", 2*i + 1];

	dispatch_sync(dispatch_get_main_queue(), ^{
		preview = [[MarkdownPreviewViewController alloc] init];
		preview.delegate = recorder;
		[preview showHTML:html documentURL:nil readAccessURL:nil];

		NSMutableArray<NSView*>* queue = [NSMutableArray arrayWithObject:preview.view];
		while(queue.count)
		{
			NSView* view = queue.firstObject;
			[queue removeObjectAtIndex:0];
			if([view isKindOfClass:[NSScrollView class]] && !view.isHiddenOrHasHiddenAncestor)
				scrollView = (NSScrollView*)view;
			[queue addObjectsFromArray:view.subviews];
		}
	});
	OAK_ASSERT(scrollView != nil);

	__block NSUInteger anchors = 0;
	for(NSUInteger i = 0; i < 200 && anchors < 201; ++i)
	{
		usleep(50000);
		dispatch_sync(dispatch_get_main_queue(), ^{
			anchors = preview.anchors.count;
		});
	}
	OAK_ASSERT_EQ(anchors, 201);

	dispatch_sync(dispatch_get_main_queue(), ^{
		// Following the editor moves the scroll view, on device pixels, and isn’t reported
		[preview scrollToPosition:300.3 animated:NO];
		CGFloat y = NSMinY(scrollView.contentView.bounds);
		OAK_ASSERT(fabs(y - 300.3) <= 0.5);
		OAK_ASSERT_EQ(y * 2, round(y * 2));
		OAK_ASSERT_EQ(recorder.positions.count, 0);

		// The user scrolling is
		[scrollView.contentView scrollToPoint:NSMakePoint(0, 500)];
		OAK_ASSERT_EQ(recorder.positions.count, 1);
		OAK_ASSERT(fabs(recorder.positions.lastObject.doubleValue - 500) < 1);
	});
}

static void switching_back_from_github_follows_the_editor ()
{
	NSMutableString* markdown = [NSMutableString string];
	for(NSUInteger i = 0; i < 200; ++i)
		[markdown appendFormat:@"Paragraph %lu\n\n", i];

	MarkdownPreviewViewController* preview = [[MarkdownPreviewViewController alloc] init];
	PreviewScrollRecorder* recorder = [[PreviewScrollRecorder alloc] init];
	recorder.positions = [NSMutableArray array];
	preview.delegate = recorder;
	preview.view.frame = NSMakeRect(0, 0, 400, 300);
	[preview showMarkdown:markdown baseURL:nil];
	[preview scrollToPosition:100 animated:NO];
	[preview showHTML:@"<p>Text</p>" documentURL:nil readAccessURL:nil];

	// As the window does: the editor’s position, through the new anchors
	__weak MarkdownPreviewViewController* weakPreview = preview;
	recorder.didUpdateAnchors = ^{
		[weakPreview scrollToPosition:600 animated:NO];
	};
	[preview showMarkdown:markdown baseURL:nil];

	OAK_ASSERT(preview.scrollFraction > 0);
	OAK_ASSERT_EQ(recorder.positions.count, 0); // or the editor would follow
}

static void keeps_focus_when_switching_renderers ()
{
	MarkdownPreviewViewController* preview = [[MarkdownPreviewViewController alloc] init];
	[preview showMarkdown:@"Text\n" baseURL:nil];

	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
	window.releasedWhenClosed = NO;
	window.contentView = preview.view;

	// Without focus, it doesn’t take it
	[window makeFirstResponder:nil];
	[preview showHTML:@"<p>Text</p>" documentURL:nil readAccessURL:nil];
	[preview showMarkdown:@"Text\n" baseURL:nil];
	OAK_ASSERT(!preview.hasFocus);

	[preview focus];
	OAK_ASSERT(preview.hasFocus);
	OAK_ASSERT([window.firstResponder isKindOfClass:[NSTextView class]]);

	[preview showHTML:@"<p>Text</p>" documentURL:nil readAccessURL:nil];
	OAK_ASSERT(preview.hasFocus);
	OAK_ASSERT(![(NSView*)window.firstResponder isHiddenOrHasHiddenAncestor]);
	OAK_ASSERT(![window.firstResponder isKindOfClass:[NSTextView class]]);

	[preview showMarkdown:@"Text\n" baseURL:nil];
	OAK_ASSERT(preview.hasFocus);
	OAK_ASSERT([window.firstResponder isKindOfClass:[NSTextView class]]);

	// Asked for while the placeholder shows, as coming back from a non-Markdown document
	[window makeFirstResponder:nil];
	[preview showPlaceholder:@"Nothing"];
	[preview focus];
	OAK_ASSERT(!preview.hasFocus);
	[preview showMarkdown:@"Text\n" baseURL:nil];
	OAK_ASSERT(preview.hasFocus);
}

static void scrolling_key_equivalents ()
{
	NSMutableString* markdown = [NSMutableString string];
	for(NSUInteger i = 0; i < 200; ++i)
		[markdown appendFormat:@"Paragraph %lu\n\n", i];

	MarkdownPreviewViewController* preview = [[MarkdownPreviewViewController alloc] init];
	PreviewScrollRecorder* recorder = [[PreviewScrollRecorder alloc] init];
	recorder.positions = [NSMutableArray array];
	preview.delegate = recorder;
	preview.view.frame = NSMakeRect(0, 0, 400, 300);
	[preview showMarkdown:markdown baseURL:nil];

	NSTextView* textView;
	NSMutableArray<NSView*>* queue = [NSMutableArray arrayWithObject:preview.view];
	while(queue.count && !textView)
	{
		NSView* view = queue.firstObject;
		[queue removeObjectAtIndex:0];
		if([view isKindOfClass:[NSTextView class]])
			textView = (NSTextView*)view;
		[queue addObjectsFromArray:view.subviews];
	}
	OAK_ASSERT(textView != nil);

	auto event = [&](unichar character, NSEventModifierFlags flags) -> NSEvent* {
		NSString* key = [NSString stringWithCharacters:&character length:1];
		return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil characters:key charactersIgnoringModifiers:key isARepeat:NO keyCode:0];
	};
	auto press = [&](unichar character, NSEventModifierFlags flags) -> BOOL {
		return [textView performKeyEquivalent:event(character, flags)];
	};

	// Only with focus
	OAK_ASSERT(!press(NSDownArrowFunctionKey, NSEventModifierFlagCommand));
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
	window.releasedWhenClosed = NO;
	window.contentView = preview.view;
	[window makeFirstResponder:textView];

	// Space isn’t a key equivalent: it goes through the window to keyDown:
	[window sendEvent:event(' ', 0)];
	OAK_ASSERT(preview.scrollFraction > 0);
	[window sendEvent:event(' ', NSEventModifierFlagShift)];
	OAK_ASSERT_EQ(preview.scrollFraction, 0);
	OAK_ASSERT(recorder.positions.count > 0); // the editor follows; the first move after a resize doesn’t count
	OAK_ASSERT_EQ(recorder.positions.lastObject.doubleValue, 0);
	OAK_ASSERT(press(NSDownArrowFunctionKey, NSEventModifierFlagCommand));
	OAK_ASSERT_EQ(preview.scrollFraction, 1);
	OAK_ASSERT(press(NSUpArrowFunctionKey, NSEventModifierFlagCommand));
	OAK_ASSERT_EQ(preview.scrollFraction, 0);

	// Others aren’t ours
	OAK_ASSERT(!press(NSDownArrowFunctionKey, NSEventModifierFlagCommand|NSEventModifierFlagShift));
	OAK_ASSERT_EQ(preview.scrollFraction, 0);
	OAK_ASSERT(!press('a', NSEventModifierFlagCommand));
}

void test_switching_back_from_github_follows_the_editor () { RunOnMainThread(switching_back_from_github_follows_the_editor); }
void test_keeps_focus_when_switching_renderers () { RunOnMainThread(keeps_focus_when_switching_renderers); }
void test_scrolling_key_equivalents () { RunOnMainThread(scrolling_key_equivalents); }
void test_reports_user_scrolling () { RunOnMainThread(reports_user_scrolling); }
void test_renders_markdown () { RunOnMainThread(renders_markdown); }
void test_reports_anchors_and_scrolls () { RunOnMainThread(reports_anchors_and_scrolls); }
void test_switches_between_renderers () { RunOnMainThread(switches_between_renderers); }
void test_notice () { RunOnMainThread(notice); }
void test_placeholder () { RunOnMainThread(placeholder); }
void test_keeps_scroll_position () { RunOnMainThread(keeps_scroll_position); }
void test_footnote_links_scroll_preview () { RunOnMainThread(footnote_links_scroll_preview); }
