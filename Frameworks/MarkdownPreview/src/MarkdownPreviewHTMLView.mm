#import "MarkdownPreviewHTMLView.h"
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString* const kScheme = @"x-txmt-preview";
static CGFloat const kLineScroll = 40; // as WebKit’s arrow keys

// Styles after GitHub’s, for light and dark appearance
static NSString* const kStyleSheet = @R"CSS(
:root { color-scheme: light dark; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --border-muted: #d1d9e0b3; --link: #0969da; --code-bg: #818b981f; --pre-bg: #f6f8fa; --row-alt: #f6f8fa; --bg: #ffffff; --mark: #fff8c5; }
@media (prefers-color-scheme: dark) {
	:root { --fg: #f0f6fc; --muted: #9198a1; --border: #3d444d; --border-muted: #3d444db3; --link: #4493f8; --code-bg: #656c7633; --pre-bg: #151b23; --row-alt: #151b23; --bg: #0d1117; --mark: #bb800926; }
}
html { background: var(--bg); overflow: hidden; }
body { margin: 0; padding: 16px 20px; color: var(--fg); background: var(--bg); font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif; word-wrap: break-word; }
.markdown-body > *:first-child { margin-top: 0 !important; }
.markdown-body > *:last-child { margin-bottom: 0 !important; }
p, blockquote, ul, ol, dl, table, pre, details { margin-top: 0; margin-bottom: 16px; }
h1, h2, h3, h4, h5, h6 { margin-top: 24px; margin-bottom: 16px; font-weight: 600; line-height: 1.25; }
h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border-muted); }
h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border-muted); }
h3 { font-size: 1.25em; }
h4 { font-size: 1em; }
h5 { font-size: .875em; }
h6 { font-size: .85em; color: var(--muted); }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
strong { font-weight: 600; }
hr { height: .25em; padding: 0; margin: 24px 0; background-color: var(--border); border: 0; }
blockquote { margin-left: 0; margin-right: 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
ul, ol { padding-left: 2em; }
ul ul, ul ol, ol ol, ol ul { margin-top: 0; margin-bottom: 0; }
li + li { margin-top: .25em; }
li > p { margin-top: 16px; }
li:has(> input[type="checkbox"]) { list-style-type: none; }
li > input[type="checkbox"] { margin: 0 .2em .25em -1.4em; vertical-align: middle; }
code, kbd, samp, pre { font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace; font-size: 85%; }
code { padding: .2em .4em; margin: 0; white-space: break-spaces; background-color: var(--code-bg); border-radius: 6px; }
pre { padding: 16px; overflow: auto; line-height: 1.45; background-color: var(--pre-bg); border-radius: 6px; }
pre code { padding: 0; font-size: 100%; white-space: pre; background: transparent; border: 0; }
kbd { display: inline-block; padding: 3px 5px; line-height: 10px; vertical-align: middle; border: solid 1px var(--border); border-bottom-color: var(--border-muted); border-radius: 6px; box-shadow: inset 0 -1px 0 var(--border-muted); }
table { display: block; width: max-content; max-width: 100%; overflow: auto; border-spacing: 0; border-collapse: collapse; }
table th { font-weight: 600; }
table th, table td { padding: 6px 13px; border: 1px solid var(--border); }
table tr { border-top: 1px solid var(--border-muted); }
table tr:nth-child(2n) { background-color: var(--row-alt); }
img { max-width: 100%; box-sizing: content-box; }
mark { background-color: var(--mark); color: inherit; }
del { color: var(--muted); }
.footnotes { font-size: 12px; color: var(--muted); border-top: 1px solid var(--border); }
.footnotes ol { padding-left: 16px; }
)CSS";

// Runs in its own world: the page’s own scripts are disabled
static NSString* const kScript = @R"JS(
function tmSetContent (html) {
	const content = document.getElementById("content");
	content.innerHTML = html;
	tmAddHeadingIds(content);
	tmAnchors = null;
}

// cmark-gfm leaves headings without ids; github.com gives them “user-content-”
// and its slug of the text, as OakMarkdownHeadingSlug() does for the built-in view
function tmHeadingSlug (text) {
	return text.toLowerCase().replace(/[^\p{L}\p{M}\p{N}_\- ]/gu, "").replace(/ /g, "-");
}

function tmAddHeadingIds (content) {
	const occurrences = new Map();
	for(const heading of content.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
		const slug = tmHeadingSlug(heading.textContent);
		let res = slug;
		while(occurrences.has(res)) {
			occurrences.set(slug, occurrences.get(slug) + 1);
			res = slug + "-" + occurrences.get(slug);
		}
		occurrences.set(res, 0);
		if(!heading.id)
			heading.id = "user-content-" + res;
	}
}

// “#intro” links work as on github.com, whose script adds the prefix; so does
// “#user-content-intro”, and ids and names from raw HTML, which we don’t prefix
function tmElementForFragment (fragment) {
	let id = fragment;
	try { id = decodeURIComponent(fragment); } catch(e) { }
	const bare = id.startsWith("user-content-") ? id.slice(13) : id;
	for(const candidate of [ id, "user-content-" + bare, bare ]) {
		const el = document.getElementById(candidate) ?? document.getElementsByName(candidate)[0];
		if(el)
			return el;
	}
	return null;
}

// The page doesn’t scroll: the web view is as tall as the page, in a scroll view
function tmHeight () {
	return Math.ceil(document.body.getBoundingClientRect().height);
}

function tmTop (el) {
	return el.getBoundingClientRect().top;
}

// Source line → page position, from where elements start. Cached until the
// layout changes (content, width, images loading).
let tmAnchors = null, tmAnchorsKey = null;

function tmComputeAnchors () {
	const anchors = [ { line: 1, y: 0 } ];
	let lastLine = 1, bottom = 0;
	for(const el of document.querySelectorAll("#content [data-sourcepos]")) {
		const m = /^(\d+):\d+-(\d+):\d+$/.exec(el.getAttribute("data-sourcepos"));
		if(!m)
			continue;

		const start = +m[1], top = tmTop(el), previous = anchors[anchors.length - 1];
		lastLine = Math.max(lastLine, +m[2] + 1);
		bottom   = Math.max(bottom, el.getBoundingClientRect().bottom);

		if(start == previous.line)
			continue; // nested elements starting on the same line, e.g. a list, its first item and paragraph
		if(start > previous.line && top > previous.y)
			anchors.push({ line: start, y: top }); // skip elements beside the previous one, e.g. table cells
	}
	anchors.push({ line: lastLine, y: Math.max(bottom, anchors[anchors.length - 1].y) });
	return anchors;
}

function tmCurrentAnchors () {
	const key = tmHeight() + "×" + window.innerWidth;
	if(!tmAnchors || tmAnchorsKey != key) {
		tmAnchors    = tmComputeAnchors();
		tmAnchorsKey = key;
	}
	return tmAnchors;
}

// Sent to the app with the page’s height, as [line, y] pairs, which the editor
// maps its position through; empty without source positions
function tmPostAnchors () {
	const anchors = document.querySelector("#content [data-sourcepos]") ? tmCurrentAnchors().map(anchor => [ anchor.line, anchor.y ]) : [];
	window.webkit.messageHandlers.tmAnchors.postMessage({ height: tmHeight(), anchors: anchors });
}

// The page can’t scroll, so its scrolling keys go to the app, unless they
// belong to something in the page, e.g. a text field or <details> summary
function tmScrollCommand (event) {
	if(event.altKey || event.ctrlKey)
		return null;
	if(event.metaKey)
		return { ArrowUp: "top", ArrowDown: "bottom" }[event.key] ?? null;
	if(event.key == " ")
		return event.shiftKey ? "pageUp" : "pageDown";
	return { ArrowUp: "lineUp", ArrowDown: "lineDown", PageUp: "pageUp", PageDown: "pageDown", Home: "top", End: "bottom" }[event.key] ?? null;
}

document.addEventListener("keydown", event => {
	const command = tmScrollCommand(event);
	if(!command || event.target.closest?.("input, textarea, select, button, summary, [contenteditable]"))
		return;
	event.preventDefault();
	window.webkit.messageHandlers.tmScrollCommand.postMessage(command);
});

// Positions move when the layout does, e.g. as images load or the width changes
document.addEventListener("DOMContentLoaded", () => {
	new ResizeObserver(() => {
		tmAnchors = null;
		tmPostAnchors();
	}).observe(document.getElementById("content"));
});
)JS";

static NSURL* PreviewURLForPath (NSString* path)
{
	NSURLComponents* components = [[NSURLComponents alloc] init];
	components.scheme = kScheme;
	components.host   = @"local";
	components.path   = path ?: @"/";
	return components.URL;
}

static NSString* PathForPreviewURL (NSURL* url)
{
	if(![url.scheme isEqualToString:kScheme])
		return nil;
	return [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES].path;
}

// ===================================
// = Serves local files, e.g. images =
// ===================================

@interface MarkdownPreviewSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic) NSString* readAccessPath;
@end

@implementation MarkdownPreviewSchemeHandler
- (void)webView:(WKWebView*)webView startURLSchemeTask:(id<WKURLSchemeTask>)task
{
	NSString* path = PathForPreviewURL(task.request.URL).stringByStandardizingPath.stringByResolvingSymlinksInPath;
	NSString* root = _readAccessPath.stringByStandardizingPath.stringByResolvingSymlinksInPath;

	NSData* data;
	if(path && root && ([path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]]))
		data = [NSData dataWithContentsOfFile:path];

	if(!data)
		return [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];

	NSString* mimeType = [UTType typeWithFilenameExtension:path.pathExtension].preferredMIMEType ?: @"application/octet-stream";
	[task didReceiveResponse:[[NSURLResponse alloc] initWithURL:task.request.URL MIMEType:mimeType expectedContentLength:data.length textEncodingName:nil]];
	[task didReceiveData:data];
	[task didFinish];
}

- (void)webView:(WKWebView*)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
}
@end

// ============
// = The view =
// ============

// Wheel scrolling goes to the scroll view, as in the built-in view; sideways
// is left for wide code blocks and tables
@interface MarkdownPreviewWebView : WKWebView
@end

@implementation MarkdownPreviewWebView
// Given to the page, which knows if a field has focus
- (BOOL)performKeyEquivalent:(NSEvent*)anEvent
{
	if(self.window.firstResponder == self && MarkdownPreviewIsScrollKeyEquivalent(anEvent))
	{
		[self keyDown:anEvent];
		return YES;
	}
	return [super performKeyEquivalent:anEvent];
}

- (void)scrollWheel:(NSEvent*)anEvent
{
	if(fabs(anEvent.scrollingDeltaX) > fabs(anEvent.scrollingDeltaY))
		return [super scrollWheel:anEvent];
	[self.enclosingScrollView scrollWheel:anEvent];
}
@end

// Passes the page’s messages on without the content controller retaining the view
@interface MarkdownPreviewMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) MarkdownPreviewHTMLView* view;
@end

@interface MarkdownPreviewHTMLView () <WKNavigationDelegate>
- (void)didReceiveLayout:(id)layout;
- (void)didReceiveScrollCommand:(id)command;
@end

@implementation MarkdownPreviewMessageHandler
- (void)userContentController:(WKUserContentController*)userContentController didReceiveScriptMessage:(WKScriptMessage*)message
{
	if([message.name isEqualToString:@"tmScrollCommand"])
		[_view didReceiveScrollCommand:message.body];
	else	[_view didReceiveLayout:message.body];
}
@end

@interface MarkdownPreviewHTMLView ()
{
	NSScrollView* _scrollView;
	MarkdownPreviewWebView* _webView;
	MarkdownPreviewSchemeHandler* _schemeHandler;

	NSURL* _documentURL;
	NSString* _body;
	BOOL _loaded;
}
@end

@implementation MarkdownPreviewHTMLView
- (instancetype)initWithFrame:(NSRect)frame
{
	if(self = [super initWithFrame:frame])
	{
		_schemeHandler = [[MarkdownPreviewSchemeHandler alloc] init];

		WKWebViewConfiguration* configuration = [[WKWebViewConfiguration alloc] init];
		configuration.defaultWebpagePreferences.allowsContentJavaScript = NO;
		configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
		[configuration setURLSchemeHandler:_schemeHandler forURLScheme:kScheme];
		[configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:kScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES inContentWorld:WKContentWorld.defaultClientWorld]];

		MarkdownPreviewMessageHandler* messageHandler = [[MarkdownPreviewMessageHandler alloc] init];
		messageHandler.view = self;
		[configuration.userContentController addScriptMessageHandler:messageHandler contentWorld:WKContentWorld.defaultClientWorld name:@"tmAnchors"];
		[configuration.userContentController addScriptMessageHandler:messageHandler contentWorld:WKContentWorld.defaultClientWorld name:@"tmScrollCommand"];

		_scrollView = [[NSScrollView alloc] initWithFrame:self.bounds];
		_scrollView.hasVerticalScroller = YES;
		_scrollView.borderType          = NSNoBorder;
		_scrollView.autoresizingMask    = NSViewWidthSizable|NSViewHeightSizable;
		[self addSubview:_scrollView];

		_webView = [[MarkdownPreviewWebView alloc] initWithFrame:_scrollView.contentView.bounds configuration:configuration];
		_webView.autoresizingMask   = NSViewWidthSizable;
		_webView.navigationDelegate = self;
		_scrollView.documentView = _webView;
	}
	return self;
}

- (void)showHTML:(NSString*)body documentURL:(NSURL*)documentURL readAccessURL:(NSURL*)readAccessURL
{
	_body = [body copy];
	_schemeHandler.readAccessPath = readAccessURL.path;

	if(_loaded && (_documentURL == documentURL || [_documentURL isEqual:documentURL]))
		return [self pushContent];

	// A new document: load the page; the content follows once it has loaded
	_documentURL = documentURL;
	_loaded      = NO;
	NSString* page = [NSString stringWithFormat:@"<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light dark\"><style>%@</style></head><body><article id=\"content\" class=\"markdown-body\"></article></body></html>", kStyleSheet];
	[_webView loadHTMLString:page baseURL:PreviewURLForPath(documentURL.path)];
}

// The page keeps its scroll position; the delegate re-syncs it once the new anchors arrive
- (void)pushContent
{
	[_webView callAsyncJavaScript:@"tmSetContent(html); tmPostAnchors();" arguments:@{ @"html": _body ?: @"" } inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
}

// { height, anchors } from the page, after content or layout changes
- (void)didReceiveLayout:(id)layout
{
	if(![layout isKindOfClass:[NSDictionary class]])
		return;

	NSMutableArray* res = [NSMutableArray array];
	id anchors = layout[@"anchors"];
	if([anchors isKindOfClass:[NSArray class]])
	{
		for(NSArray* anchor in anchors)
		{
			if([anchor isKindOfClass:[NSArray class]] && anchor.count == 2)
				[res addObject:[NSValue valueWithPoint:NSMakePoint([anchor[0] doubleValue], [anchor[1] doubleValue])]];
		}
	}
	_anchors = res;

	NSRect frame = _webView.frame;
	frame.size.height = MAX([layout[@"height"] doubleValue], NSHeight(_scrollView.contentView.bounds));
	if(NSHeight(frame) != NSHeight(_webView.frame))
	{
		_resizing = YES; // a shorter page may move the clip view
		_webView.frame = frame;
		_resizing = NO;
	}

	if([self.delegate respondsToSelector:@selector(HTMLViewDidUpdateAnchors:)])
		[self.delegate HTMLViewDidUpdateAnchors:self];
}

- (void)scrollToY:(CGFloat)y
{
	CGFloat maxY = MAX(0, NSHeight(_webView.frame) - NSHeight(_scrollView.contentView.bounds));
	[_scrollView.contentView scrollToPoint:NSMakePoint(0, MIN(MAX(y, 0), maxY))];
	[_scrollView reflectScrolledClipView:_scrollView.contentView];
}

- (void)didReceiveScrollCommand:(id)command
{
	CGFloat const y = NSMinY(_scrollView.contentView.bounds), page = NSHeight(_scrollView.contentView.bounds) - _scrollView.verticalPageScroll;
	if([command isEqual:@"lineUp"])        [self scrollToY:y - kLineScroll];
	else if([command isEqual:@"lineDown"]) [self scrollToY:y + kLineScroll];
	else if([command isEqual:@"pageUp"])   [self scrollToY:y - page];
	else if([command isEqual:@"pageDown"]) [self scrollToY:y + page];
	else if([command isEqual:@"top"])      [self scrollToY:0];
	else if([command isEqual:@"bottom"])   [self scrollToY:CGFLOAT_MAX];
}

- (void)evaluateJavaScript:(NSString*)script completionHandler:(void(^)(id result, NSError* error))completion
{
	[_webView evaluateJavaScript:script inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:completion];
}

// ==============
// = Navigation =
// ==============

- (void)scrollToFragment:(NSString*)fragment
{
	__weak MarkdownPreviewHTMLView* weakSelf = self;
	[_webView callAsyncJavaScript:@"const el = tmElementForFragment(id); return el ? tmTop(el) : null;" arguments:@{ @"id": fragment } inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id top, NSError* error){
		if(MarkdownPreviewHTMLView* strongSelf = weakSelf; [top isKindOfClass:[NSNumber class]])
		{
			[strongSelf scrollToY:[top doubleValue] - 8];
		}
	}];
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
	_loaded = YES;
	[self pushContent]; // also after a reload from the context menu
}

- (void)webView:(WKWebView*)webView decidePolicyForNavigationAction:(WKNavigationAction*)action decisionHandler:(void(^)(WKNavigationActionPolicy))decisionHandler
{
	NSURL* url = action.request.URL;
	NSString* path = PathForPreviewURL(url);

	if(action.navigationType == WKNavigationTypeLinkActivated)
	{
		decisionHandler(WKNavigationActionPolicyCancel);

		// Links within the page, e.g. to footnotes
		if(url.fragment && [path isEqualToString:(_documentURL.path ?: @"/")])
			return [self scrollToFragment:url.fragment];

		if(path)
			[self.delegate HTMLView:self openURL:[NSURL fileURLWithPath:path]];
		else if(url)
			[self.delegate HTMLView:self openURL:url];
		return;
	}

	// Only our own page loads; raw HTML can’t navigate elsewhere (e.g. with a refresh)
	BOOL ours = action.targetFrame.isMainFrame && (path || [url.absoluteString isEqualToString:@"about:blank"]);
	decisionHandler(ours ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
@end
