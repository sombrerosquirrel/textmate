#import <MarkdownPreview/MarkdownPreviewHTMLView.h>

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
	OAK_ASSERT(WaitFor(view, @"document.getElementById('content')?.innerHTML == '<h1>Hello</h1>'"));

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

void test_scrolls_to_source_line ()
{
	NSMutableString* html = [NSMutableString string];
	for(NSUInteger i = 0; i < 100; ++i)
		[html appendFormat:@"<p data-sourcepos=\"%1$lu:1-%1$lu:10\">Paragraph %1$lu</p>\n", 2*i + 1];

	MarkdownPreviewHTMLView* view = MakeView();
	ShowHTML(view, html, nil, nil);
	OAK_ASSERT(WaitFor(view, @"document.querySelectorAll('#content p').length == 100"));

	// Line 101 is paragraph 50: it should be at the top
	dispatch_sync(dispatch_get_main_queue(), ^{
		[view scrollToSourceLine:101 fraction:0];
	});
	OAK_ASSERT(WaitFor(view, @"Math.abs(document.querySelectorAll('#content p')[50].getBoundingClientRect().top) < 2"));

	// Line 102 is the blank line after it: halfway to the next paragraph
	dispatch_sync(dispatch_get_main_queue(), ^{
		[view scrollToSourceLine:102 fraction:0];
	});
	OAK_ASSERT(WaitFor(view, @"(() => { const p = document.querySelectorAll('#content p'); const a = p[50].getBoundingClientRect().top, b = p[51].getBoundingClientRect().top; return a < -1 && b > 1 && Math.abs(a + b) < 2; })()"));

	// The end of the document scrolls to the bottom
	dispatch_sync(dispatch_get_main_queue(), ^{
		[view scrollToSourceLine:500 fraction:0];
	});
	OAK_ASSERT(WaitFor(view, @"Math.abs(window.scrollY + window.innerHeight - document.documentElement.scrollHeight) < 2"));
}
