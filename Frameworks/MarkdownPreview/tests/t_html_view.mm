#import <MarkdownPreview/MarkdownPreviewHTMLView.h>
#import "preview_scroll_recorder.h"

// The web view loads asynchronously on the main thread, so these tests run on
// the test thread and only touch the view on the main thread.

static MarkdownPreviewHTMLView* MakeView ()
{
	__block MarkdownPreviewHTMLView* view;
	dispatch_sync(dispatch_get_main_queue(), ^{
		view = [[MarkdownPreviewHTMLView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
	});
	return view;
}

static void ShowHTML (MarkdownPreviewHTMLView* view, NSString* html, NSURL* documentURL, NSURL* readAccessURL)
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[view showHTML:html documentURL:documentURL readAccessURL:readAccessURL];
	});
}

static id Evaluate (MarkdownPreviewHTMLView* view, NSString* script)
{
	__block id result;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_main_queue(), ^{
		[view evaluateJavaScript:script completionHandler:^(id value, NSError* error){
			result = value;
			dispatch_semaphore_signal(done);
		}];
	});
	if(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0)
		return nil;
	return result;
}

// Polls until `script` evaluates to true
static BOOL WaitFor (MarkdownPreviewHTMLView* view, NSString* script)
{
	for(NSUInteger i = 0; i < 200; ++i)
	{
		if([Evaluate(view, script) isEqual:@YES])
			return YES;
		usleep(50000);
	}
	return NO;
}

void test_shows_html ()
{
	MarkdownPreviewHTMLView* view = MakeView();
	ShowHTML(view, @"<h1>Hello</h1>", nil, nil);
	OAK_ASSERT(WaitFor(view, @"document.getElementById('content')?.innerHTML == '<h1 id=\"user-content-hello\">Hello</h1>'"));

	// Same document: only the content changes
	ShowHTML(view, @"<p>Again</p>", nil, nil);
	OAK_ASSERT(WaitFor(view, @"document.getElementById('content')?.innerHTML == '<p>Again</p>'"));
}

void test_content_cannot_run_javascript ()
{
	MarkdownPreviewHTMLView* view = MakeView();
	ShowHTML(view, @"<img src='missing.png' onerror=\"document.title='ran'\"><p id='done'>x</p>", nil, nil);
	OAK_ASSERT(WaitFor(view, @"document.getElementById('done') != null"));
	usleep(300000); // give a failed image load time to run its handler
	OAK_ASSERT([Evaluate(view, @"document.title") isEqualToString:@""]);
}

void test_serves_local_files_below_read_access_url ()
{
	NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_html_view.%@", NSUUID.UUID.UUIDString]];
	NSString* docs = [root stringByAppendingPathComponent:@"docs"];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil]);

	NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:4 pixelsHigh:3 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
	NSData* png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{ }];
	OAK_ASSERT([png writeToFile:[docs stringByAppendingPathComponent:@"inside.png"] atomically:YES]);
	OAK_ASSERT([png writeToFile:[root stringByAppendingPathComponent:@"outside.png"] atomically:YES]);

	MarkdownPreviewHTMLView* view = MakeView();
	NSURL* documentURL = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:@"README.md"]];
	ShowHTML(view, @"<img id='inside' src='inside.png'><img id='outside' src='../outside.png'>", documentURL, [NSURL fileURLWithPath:docs isDirectory:YES]);

	OAK_ASSERT(WaitFor(view, @"document.getElementById('inside')?.complete && document.getElementById('outside')?.complete"));
	OAK_ASSERT_EQ([Evaluate(view, @"document.getElementById('inside').naturalWidth") intValue], 4);
	OAK_ASSERT_EQ([Evaluate(view, @"document.getElementById('outside').naturalWidth") intValue], 0);

	[NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static NSArray<NSValue*>* WaitForAnchors (MarkdownPreviewHTMLView* view, NSUInteger count)
{
	__block NSArray<NSValue*>* anchors;
	for(NSUInteger i = 0; i < 200 && anchors.count != count; ++i)
	{
		dispatch_sync(dispatch_get_main_queue(), ^{
			anchors = view.anchors;
		});
		if(anchors.count != count)
			usleep(50000);
	}
	return anchors;
}

void test_reports_anchors_and_sizes_to_the_page ()
{
	NSMutableString* html = [NSMutableString string];
	for(NSUInteger i = 0; i < 100; ++i)
		[html appendFormat:@"<p data-sourcepos=\"%1$lu:1-%1$lu:10\">Paragraph %1$lu</p>\n", 2*i + 1];

	MarkdownPreviewHTMLView* view = MakeView();
	ShowHTML(view, html, nil, nil);
	OAK_ASSERT(WaitFor(view, @"document.querySelectorAll('#content p').length == 100"));

	// Reported for the editor once the content is shown
	NSArray<NSValue*>* anchors = WaitForAnchors(view, 101);
	OAK_ASSERT_EQ(anchors.count, 101); // line 1 (also paragraph 0), paragraphs 1–99, the end
	OAK_ASSERT_EQ(anchors[1].pointValue.x, 3);
	OAK_ASSERT_EQ(anchors.lastObject.pointValue.x, 200);
	CGFloat paragraph50 = [Evaluate(view, @"tmTop(document.querySelectorAll('#content p')[50])") doubleValue];
	OAK_ASSERT(fabs(anchors[50].pointValue.y - paragraph50) < 0.01);

	// As tall as the page, which doesn’t scroll itself
	__block CGFloat height;
	dispatch_sync(dispatch_get_main_queue(), ^{
		height = NSHeight(view.scrollView.documentView.frame);
	});
	OAK_ASSERT(height > 300);
	OAK_ASSERT(fabs(height - [Evaluate(view, @"tmHeight()") doubleValue]) < 1);
	OAK_ASSERT(fabs(anchors.lastObject.pointValue.y - height) < 40);

	// Without source positions: none
	ShowHTML(view, @"<p>Plain</p>", nil, nil);
	OAK_ASSERT_EQ(WaitForAnchors(view, 0).count, 0);
}

void test_reports_anchors_when_layout_changes ()
{
	MarkdownPreviewHTMLView* view = MakeView();
	ShowHTML(view, @"<div id='box' data-sourcepos='1:1-1:5' style='height: 10px'></div><p data-sourcepos='3:1-3:5'>After</p>", nil, nil);
	NSArray<NSValue*>* anchors = WaitForAnchors(view, 3);
	OAK_ASSERT_EQ(anchors.count, 3);
	CGFloat before = anchors[1].pointValue.y;

	// As when an image loads above it, the paragraph moves down
	Evaluate(view, @"document.getElementById('box').style.height = '200px'");
	for(NSUInteger i = 0; i < 200 && anchors[1].pointValue.y < before + 150; ++i)
	{
		usleep(50000);
		anchors = WaitForAnchors(view, 3);
	}
	OAK_ASSERT(fabs(anchors[1].pointValue.y - (before + 190)) < 1);
}

void test_shorter_page_shrinks_the_web_view ()
{
	NSMutableString* html = [NSMutableString string];
	for(NSUInteger i = 0; i < 100; ++i)
		[html appendFormat:@"<p data-sourcepos=\"%1$lu:1-%1$lu:10\">Paragraph %1$lu</p>\n", 2*i + 1];

	MarkdownPreviewHTMLView* view = MakeView();
	ShowHTML(view, html, nil, nil);
	OAK_ASSERT_EQ(WaitForAnchors(view, 101).count, 101);

	// tmHeight must not take the height of the tall view itself
	ShowHTML(view, @"<p data-sourcepos='1:1-1:5'>Short</p><p data-sourcepos='3:1-3:5'>Page</p>", nil, nil);
	OAK_ASSERT_EQ(WaitForAnchors(view, 3).count, 3);
	__block CGFloat height;
	dispatch_sync(dispatch_get_main_queue(), ^{
		height = NSHeight(view.scrollView.documentView.frame);
	});
	OAK_ASSERT_EQ(height, 300); // the height of the view
}

void test_links_within_the_page_scroll_the_scroll_view ()
{
	MarkdownPreviewHTMLView* view = MakeView();
	ShowHTML(view, @"<p data-sourcepos='1:1-1:5'><a id='link' href='#target'>Link</a></p><div style='height: 2000px'></div><p id='target' data-sourcepos='3:1-3:5'>Target</p><div style='height: 2000px'></div>", nil, nil);
	OAK_ASSERT_EQ(WaitForAnchors(view, 3).count, 3);

	CGFloat target = [Evaluate(view, @"tmTop(document.getElementById('target'))") doubleValue];
	Evaluate(view, @"document.getElementById('link').click()");

	auto scrollY = [&]() -> CGFloat {
		__block CGFloat res;
		dispatch_sync(dispatch_get_main_queue(), ^{
			res = NSMinY(view.scrollView.contentView.bounds);
		});
		return res;
	};
	for(NSUInteger i = 0; i < 100 && scrollY() == 0; ++i)
		usleep(50000);
	OAK_ASSERT(fabs(scrollY() - (target - 8)) < 1);
}

void test_headings_get_github_ids ()
{
	MarkdownPreviewHTMLView* view = MakeView();
	ShowHTML(view, @"<h1>Intro</h1><h2>A — B</h2><h2>Intro</h2><h3 id='own'>Mine</h3>", nil, nil);
	OAK_ASSERT(WaitFor(view, @"document.querySelectorAll('#content h3').length == 1"));
	OAK_ASSERT_EQ(std::string([Evaluate(view, @"[...document.querySelectorAll('#content [id]')].map(el => el.id).join(' ')") UTF8String]), "user-content-intro user-content-a--b user-content-intro-1 own");

	// Links as written for github.com, with the prefix, or percent-encoded
	OAK_ASSERT([Evaluate(view, @"tmElementForFragment('a--b')?.id == 'user-content-a--b'") isEqual:@YES]);
	OAK_ASSERT([Evaluate(view, @"tmElementForFragment('user-content-intro-1')?.id == 'user-content-intro-1'") isEqual:@YES]);
	OAK_ASSERT([Evaluate(view, @"tmElementForFragment('a-%E2%80%94-b') == null && tmElementForFragment('own')?.id == 'own'") isEqual:@YES]);
}

void test_toc_links_scroll_to_headings ()
{
	MarkdownPreviewHTMLView* view = MakeView();
	ShowHTML(view, @"<p data-sourcepos='1:1-1:5'><a id='link' href='#getting-started'>Link</a></p><div style='height: 2000px'></div><h2 data-sourcepos='3:1-3:5'>Getting Started</h2><div style='height: 2000px'></div>", nil, nil);
	OAK_ASSERT_EQ(WaitForAnchors(view, 3).count, 3);

	CGFloat target = [Evaluate(view, @"tmTop(document.querySelector('h2'))") doubleValue];
	Evaluate(view, @"document.getElementById('link').click()");

	auto scrollY = [&]() -> CGFloat {
		__block CGFloat res;
		dispatch_sync(dispatch_get_main_queue(), ^{
			res = NSMinY(view.scrollView.contentView.bounds);
		});
		return res;
	};
	for(NSUInteger i = 0; i < 100 && scrollY() == 0; ++i)
		usleep(50000);
	OAK_ASSERT(target > 1000);
	OAK_ASSERT(fabs(scrollY() - (target - 8)) < 1);
}

void test_web_view_follows_the_width ()
{
	MarkdownPreviewHTMLView* view = MakeView();
	dispatch_sync(dispatch_get_main_queue(), ^{
		[view setFrameSize:NSMakeSize(600, 300)];
		OAK_ASSERT_EQ(NSWidth(view.scrollView.documentView.frame), NSWidth(view.scrollView.contentView.bounds));
	});
}

void test_scrolling_keys_scroll_the_scroll_view ()
{
	MarkdownPreviewHTMLView* view = MakeView();
	ShowHTML(view, @"<p data-sourcepos='1:1-1:5'><input id='field'></p><div style='height: 5000px'></div><p data-sourcepos='3:1-3:5'>End</p>", nil, nil);
	OAK_ASSERT_EQ(WaitForAnchors(view, 3).count, 3);

	auto scrollY = [&]() -> CGFloat {
		__block CGFloat res;
		dispatch_sync(dispatch_get_main_queue(), ^{
			res = NSMinY(view.scrollView.contentView.bounds);
		});
		return res;
	};
	auto press = [&](NSString* target, NSString* options, CGFloat expected){
		Evaluate(view, [NSString stringWithFormat:@"%@.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, cancelable: true, %@ })); true", target, options]);
		for(NSUInteger i = 0; i < 100 && fabs(scrollY() - expected) >= 1; ++i)
			usleep(10000);
		OAK_ASSERT(fabs(scrollY() - expected) < 1);
	};

	CGFloat const page = 300 - view.scrollView.verticalPageScroll;
	press(@"document.body", @"key: 'PageDown'", page);
	press(@"document.body", @"key: ' '", 2*page);
	press(@"document.body", @"key: 'PageUp'", page);
	press(@"document.body", @"key: ' ', shiftKey: true", 0);
	press(@"document.body", @"key: 'ArrowDown'", 40);
	press(@"document.body", @"key: 'ArrowUp'", 0);
	CGFloat bottom = NSHeight(view.scrollView.documentView.frame) - 300;
	press(@"document.body", @"key: 'End'", bottom);
	press(@"document.body", @"key: 'Home'", 0);
	press(@"document.body", @"key: 'ArrowDown', metaKey: true", bottom);
	press(@"document.body", @"key: 'ArrowUp', metaKey: true", 0);

	// In a text field they’re the field’s
	press(@"document.getElementById('field')", @"key: 'PageDown'", 0);
	usleep(100000);
	OAK_ASSERT_EQ(scrollY(), 0);
}
