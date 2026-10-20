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

static void ScrollTo (MarkdownPreviewHTMLView* view, CGFloat y)
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		[view scrollToPosition:y animated:NO];
	});
}

void test_reports_anchors_and_scrolls ()
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

	// Paragraph 50 at the top
	ScrollTo(view, paragraph50);
	OAK_ASSERT(WaitFor(view, @"Math.abs(document.querySelectorAll('#content p')[50].getBoundingClientRect().top) < 0.01"));

	// Positions between whole pixels: the page scrolls by whole pixels, and the content moves by the rest
	ScrollTo(view, paragraph50 + 10.3);
	OAK_ASSERT(WaitFor(view, [NSString stringWithFormat:@"Math.abs(window.scrollY + tmOffset - %f) < 0.01 && tmOffset < 1", paragraph50 + 10.3]));

	// Past the end: the bottom
	ScrollTo(view, 1e6);
	OAK_ASSERT(WaitFor(view, @"Math.abs(window.scrollY + window.innerHeight - document.documentElement.scrollHeight) < 2"));

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
