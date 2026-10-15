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
mark { background-color: var(--mark); color: inherit; }
del { color: var(--muted); }
.footnotes { font-size: 12px; color: var(--muted); border-top: 1px solid var(--border); }
.footnotes ol { padding-left: 16px; }
)CSS";

// Runs in its own world: the page’s own scripts are disabled
static NSString* const kScript = @R"JS(
function tmSetContent (html) {
	document.getElementById("content").innerHTML = html;
}

function tmTop (el) {
	return el.getBoundingClientRect().top + window.scrollY;
}

function tmBottom (el) {
	return el.getBoundingClientRect().bottom + window.scrollY;
}

// Scrolls so `line` of the source is at the top; elements carry their source
// lines as data-sourcepos="startLine:startColumn-endLine:endColumn".
function tmScrollTo (line, fraction) {
	const maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);

	const blocks = [];
	for(const el of document.querySelectorAll("#content [data-sourcepos]")) {
		const m = /^(\d+):\d+-(\d+):\d+$/.exec(el.getAttribute("data-sourcepos"));
		if(m)
			blocks.push({ el: el, start: +m[1], end: +m[2] + 1 }); // end is exclusive
	}

	if(blocks.length == 0)
		return window.scrollTo(0, fraction * maxY);

	// Document order: starts never decrease, so later blocks are the innermost
	let containing = null, previous = null, next = null;
	for(const block of blocks) {
		if(block.start > line) {
			next = block;
			break;
		}
		if(line < block.end)
			containing = block;
		else
			previous = block;
	}

	let y = 0;
	if(containing && !(previous && containing.el.contains(previous.el))) {
		const top = tmTop(containing.el), height = tmBottom(containing.el) - top;
		y = top + height * (line - containing.start) / (containing.end - containing.start);
	} else if(previous) {
		// Between blocks, e.g. on a blank line
		const from = tmBottom(previous.el);
		const to = next ? tmTop(next.el) : document.documentElement.scrollHeight;
		const lines = next ? next.start - previous.end : 1;
		y = from + (to - from) * Math.min(1, (line - previous.end) / Math.max(1, lines));
	}
	window.scrollTo(0, Math.min(Math.max(0, y), maxY));
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
	[_webView callAsyncJavaScript:@"tmSetContent(html)" arguments:@{ @"html": _body ?: @"" } inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
	if(_hasScrollPosition)
		[self scrollToSourceLine:_line fraction:_fraction];
}

- (void)scrollToSourceLine:(CGFloat)line fraction:(CGFloat)fraction
{
	_hasScrollPosition = YES;
	_line              = line;
	_fraction          = fraction;
	if(_loaded)
		[_webView callAsyncJavaScript:@"tmScrollTo(line, fraction)" arguments:@{ @"line": @(line), @"fraction": @(fraction) } inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
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
