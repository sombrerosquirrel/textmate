#import "MarkdownPreviewHTMLView.h"
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString* const kScheme = @"x-txmt-preview";

// Styles after GitHub’s, for light and dark appearance
static NSString* const kStyleSheet = @R"CSS(
:root { color-scheme: light dark; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --border-muted: #d1d9e0b3; --link: #0969da; --code-bg: #818b981f; --pre-bg: #f6f8fa; --row-alt: #f6f8fa; --bg: #ffffff; --mark: #fff8c5; }
@media (prefers-color-scheme: dark) {
	:root { --fg: #f0f6fc; --muted: #9198a1; --border: #3d444d; --border-muted: #3d444db3; --link: #4493f8; --code-bg: #656c7633; --pre-bg: #151b23; --row-alt: #151b23; --bg: #0d1117; --mark: #bb800926; }
}
html { background: var(--bg); }
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
#content { will-change: transform; } /* moved by fractions of a pixel while scrolling */
mark { background-color: var(--mark); color: inherit; }
del { color: var(--muted); }
.footnotes { font-size: 12px; color: var(--muted); border-top: 1px solid var(--border); }
.footnotes ol { padding-left: 16px; }
)CSS";

// Runs in its own world: the page’s own scripts are disabled
static NSString* const kScript = @R"JS(
function tmSetContent (html) {
	document.getElementById("content").innerHTML = html;
	tmAnchors = null;
}

// Page scrolling is in whole pixels; the rest is a transform on the content
let tmOffset = 0;

function tmScrollToY (y) {
	const maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
	y = Math.min(Math.max(0, y), maxY);
	window.scrollTo(0, Math.floor(y));
	const offset = Math.min(Math.max(0, y - window.scrollY), 1);
	if(offset != tmOffset) {
		tmOffset = offset;
		document.getElementById("content").style.transform = offset ? `translateY(${-offset}px)` : "";
	}
}

function tmTop (el) {
	return el.getBoundingClientRect().top + window.scrollY + tmOffset;
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
		bottom   = Math.max(bottom, el.getBoundingClientRect().bottom + window.scrollY + tmOffset);

		if(start == previous.line)
			continue; // nested elements starting on the same line, e.g. a list, its first item and paragraph
		if(start > previous.line && top > previous.y)
			anchors.push({ line: start, y: top }); // skip elements beside the previous one, e.g. table cells
	}
	anchors.push({ line: lastLine, y: Math.max(bottom, anchors[anchors.length - 1].y) });
	return anchors;
}

function tmCurrentAnchors () {
	const key = document.documentElement.scrollHeight + "×" + window.innerWidth;
	if(!tmAnchors || tmAnchorsKey != key) {
		tmAnchors    = tmComputeAnchors();
		tmAnchorsKey = key;
	}
	return tmAnchors;
}

// For the editor, which maps its scroll position to a line between two of these
function tmAnchorLines () {
	if(!document.querySelector("#content [data-sourcepos]"))
		return [];
	return tmCurrentAnchors().map(anchor => anchor.line);
}

// Scrolls so `line` of the source is at the top. Elements carry their source
// lines as data-sourcepos="startLine:startColumn-endLine:endColumn"; between
// the starts of two elements, the position is interpolated, so scrolling
// through the editor scrolls the page continuously.
function tmScrollTo (line, fraction) {
	const maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
	if(!document.querySelector("#content [data-sourcepos]"))
		return tmScrollToY(fraction * maxY);

	const anchors = tmCurrentAnchors();
	let lo = 0, hi = anchors.length - 1;
	if(line >= anchors[hi].line)
		return tmScrollToY(anchors[hi].y);
	while(hi - lo > 1) { // anchors[lo].line <= line < anchors[hi].line
		const mid = (lo + hi) >> 1;
		if(anchors[mid].line <= line)
			lo = mid;
		else
			hi = mid;
	}

	// A monotone cubic between anchors, so the speed changes gradually (as in MarkdownPreviewInterpolation.h)
	const secant = i => (anchors[i+1].y - anchors[i].y) / (anchors[i+1].line - anchors[i].line);
	const slope = i => {
		if(i == 0)
			return secant(0);
		if(i == anchors.length - 1)
			return secant(i - 1);
		const before = secant(i - 1), after = secant(i);
		return before > 0 && after > 0 ? 2 * before * after / (before + after) : 0;
	};

	const a = anchors[lo], b = anchors[hi];
	const h = b.line - a.line, t = (line - a.line) / h, t2 = t * t, t3 = t2 * t;
	const y = (2*t3 - 3*t2 + 1) * a.y + (t3 - 2*t2 + t) * h * slope(lo) + (-2*t3 + 3*t2) * b.y + (t3 - t2) * h * slope(hi);
	tmScrollToY(y);
}
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

@interface MarkdownPreviewHTMLView () <WKNavigationDelegate>
{
	WKWebView* _webView;
	MarkdownPreviewSchemeHandler* _schemeHandler;

	NSURL* _documentURL;
	NSString* _body;
	BOOL _loaded;

	BOOL _hasScrollPosition;
	CGFloat _line;
	CGFloat _fraction;
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

		_webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:configuration];
		_webView.autoresizingMask   = NSViewWidthSizable|NSViewHeightSizable;
		_webView.navigationDelegate = self;
		[self addSubview:_webView];
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
	_documentURL       = documentURL;
	_loaded            = NO;
	_hasScrollPosition = NO;
	NSString* page = [NSString stringWithFormat:@"<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light dark\"><style>%@</style></head><body><article id=\"content\" class=\"markdown-body\"></article></body></html>", kStyleSheet];
	[_webView loadHTMLString:page baseURL:PreviewURLForPath(documentURL.path)];
}

- (void)pushContent
{
	__weak MarkdownPreviewHTMLView* weakSelf = self;
	[_webView callAsyncJavaScript:@"tmSetContent(html); return tmAnchorLines();" arguments:@{ @"html": _body ?: @"" } inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id result, NSError* error){
		MarkdownPreviewHTMLView* strongSelf = weakSelf;
		if(!strongSelf)
			return;
		strongSelf->_anchorLines = [result isKindOfClass:[NSArray class]] ? result : @[ ];
		if([strongSelf.delegate respondsToSelector:@selector(HTMLViewDidUpdateAnchorLines:)])
			[strongSelf.delegate HTMLViewDidUpdateAnchorLines:strongSelf];
	}];
	if(_hasScrollPosition)
		[self scrollToSourceLine:_line fraction:_fraction];
}

- (void)scrollToSourceLine:(CGFloat)line fraction:(CGFloat)fraction
{
	_hasScrollPosition = YES;
	_line              = line;
	_fraction          = fraction;
	[self sendScrollPosition];
}

// Every position is sent: the page’s anchors are cached, so each is cheap,
// and skipping some would make slow scrolling uneven
- (void)sendScrollPosition
{
	if(_loaded)
		[_webView callAsyncJavaScript:@"tmScrollTo(line, fraction)" arguments:@{ @"line": @(_line), @"fraction": @(_fraction) } inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
}

- (void)evaluateJavaScript:(NSString*)script completionHandler:(void(^)(id result, NSError* error))completion
{
	[_webView evaluateJavaScript:script inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:completion];
}

// ==============
// = Navigation =
// ==============

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
		// Links within the page, e.g. to footnotes
		if(url.fragment && [path isEqualToString:(_documentURL.path ?: @"/")])
			return decisionHandler(WKNavigationActionPolicyAllow);

		decisionHandler(WKNavigationActionPolicyCancel);
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
