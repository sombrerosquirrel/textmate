#import "DocumentWindowController+MarkdownPreview.h"
#import "DocumentWindowController+Agent.h"
#import "DocumentWindowController+EditorPanels.h"
#import <MarkdownPreview/MarkdownPreviewViewController.h>
#import <MarkdownPreview/MarkdownPreviewCmark.h>
#import <MarkdownPreview/MarkdownPreviewSanitizer.h>
#import <MarkdownPreview/MarkdownPreviewDocument.h>
#import <MarkdownPreview/MarkdownPreviewInstallController.h>
#import <MarkdownPreview/MarkdownPreviewInterpolation.h>
#import <OakEditorPanels/OakEditorPanelsView.h>
#import <OakTextView/OakTextView.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <Preferences/Keys.h>
#import <bundles/bundles.h>
#import <settings/settings.h>
#import <io/environment.h>
#import <ns/ns.h>
#import <text/types.h>
#import <objc/runtime.h>

NSString* const kUserDefaultsMarkdownPreviewPlacementKey = @"markdownPreviewPlacement";

static NSTimeInterval const kRenderDelay = 0.15;

static void* kMarkdownPreviewCoordinatorKey = &kMarkdownPreviewCoordinatorKey;
static void* kSelectedDocumentContext       = &kSelectedDocumentContext;
static void* kFileTypeContext               = &kFileTypeContext;
static void* kRendererContext               = &kRendererContext;

static NSArray<NSString*>* const kPlacements = @[ @"auto", @"left", @"right", @"top", @"bottom" ]; // index is the menu item tag

static BOOL UsesGitHubRenderer ()
{
	return [[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsMarkdownPreviewRendererKey] isEqualToString:@"github"];
}

// Private properties of DocumentWindowController, defined in its main file
@interface DocumentWindowController (MarkdownPreviewPrivate)
@property (nonatomic) OakTextView* textView;
@end

static BOOL IsMarkdownDocument (OakDocument* document)
{
	return MarkdownPreviewIsMarkdownDocument(document.fileType, document.path);
}

static OakEditorPanelEdge MarkdownPreviewEdge ()
{
	NSString* placement = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsMarkdownPreviewPlacementKey];
	if([placement isEqualToString:@"left"])   return OakEditorPanelEdgeLeft;
	if([placement isEqualToString:@"right"])  return OakEditorPanelEdgeRight;
	if([placement isEqualToString:@"top"])    return OakEditorPanelEdgeTop;
	if([placement isEqualToString:@"bottom"]) return OakEditorPanelEdgeBottom;

	// Automatic: opposite the agent panel, which is on the right unless moved
	BOOL agentOnLeft = [[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsAgentPanelPlacementKey] isEqualToString:@"left"];
	return agentOnLeft ? OakEditorPanelEdgeRight : OakEditorPanelEdgeLeft;
}

// ================================
// = Keeps the preview up to date =
// ================================

@interface MarkdownPreviewCoordinator : NSObject <MarkdownPreviewDelegate>
- (instancetype)initWithWindowController:(DocumentWindowController*)controller;
@property (nonatomic, readonly) MarkdownPreviewViewController* preview;
@property (nonatomic, readonly) OakEditorPanel* editorPanel;
@property (nonatomic, getter = isActive) BOOL active; // observing while the preview is shown
@end

@implementation MarkdownPreviewCoordinator
{
	__weak DocumentWindowController* _controller;
	OakDocument* _document;
	NSView* _editorClipView;
	NSUInteger _renderGeneration;

	// GitHub renderer
	dispatch_queue_t _cmarkQueue;
	NSDictionary<NSString*, NSString*>* _environment; // nil until cmark-gfm has been looked for
	NSString* _cmarkPath;
	BOOL _locatingCmark;
	BOOL _offerInstallWhenLocated;
	MarkdownPreviewInstallController* _installController;
}

- (instancetype)initWithWindowController:(DocumentWindowController*)controller
{
	if(self = [super init])
	{
		_controller = controller;
		_preview    = [[MarkdownPreviewViewController alloc] init];
		_preview.delegate = self;

		_editorPanel = [[OakEditorPanel alloc] initWithView:_preview.view edge:MarkdownPreviewEdge()];
		_editorPanel.autosaveName = @"markdownPreview"; // markdownPreviewWidth, markdownPreviewHeight

		_cmarkQueue = dispatch_queue_create("org.macromates.TextMate.MarkdownPreview.cmark", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

- (void)dealloc
{
	self.active = NO;
}

- (void)setActive:(BOOL)flag
{
	if(_active == flag)
		return;
	_active = flag;

	if(flag)
	{
		[_controller addObserver:self forKeyPath:@"selectedDocument" options:0 context:kSelectedDocumentContext];
		for(NSString* key in @[ kUserDefaultsMarkdownPreviewRendererKey, kUserDefaultsMarkdownPreviewAllowRawHTMLKey ])
			[NSUserDefaults.standardUserDefaults addObserver:self forKeyPath:key options:0 context:kRendererContext];

		// Scroll with the editor
		_editorClipView = _controller.textView.enclosingScrollView.contentView;
		_editorClipView.postsBoundsChangedNotifications = YES;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editorDidScroll:) name:NSViewBoundsDidChangeNotification object:_editorClipView];

		self.document = _controller.selectedDocument;
	}
	else
	{
		[_controller removeObserver:self forKeyPath:@"selectedDocument" context:kSelectedDocumentContext];
		for(NSString* key in @[ kUserDefaultsMarkdownPreviewRendererKey, kUserDefaultsMarkdownPreviewAllowRawHTMLKey ])
			[NSUserDefaults.standardUserDefaults removeObserver:self forKeyPath:key context:kRendererContext];
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewBoundsDidChangeNotification object:_editorClipView];
		_editorClipView = nil;
		self.document = nil;
	}
}

- (void)setDocument:(OakDocument*)document
{
	if(_document != document)
	{
		if(_document)
		{
			[NSNotificationCenter.defaultCenter removeObserver:self name:OakDocumentContentDidChangeNotification object:_document];
			[_document removeObserver:self forKeyPath:@"fileType" context:kFileTypeContext];
		}

		if(_document = document)
		{
			[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(documentContentDidChange:) name:OakDocumentContentDidChangeNotification object:_document];
			[_document addObserver:self forKeyPath:@"fileType" options:0 context:kFileTypeContext];
		}
	}

	if(_active)
		[self render];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if(context == kSelectedDocumentContext)
		self.document = _controller.selectedDocument;
	else if(context == kFileTypeContext)
		[self render];
	else if(context == kRendererContext)
		[self rendererDidChange:[keyPath isEqualToString:kUserDefaultsMarkdownPreviewRendererKey]];
	else
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

// Re-render once typing pauses, rather than on every key stroke
- (void)documentContentDidChange:(NSNotification*)aNotification
{
	NSUInteger generation = ++_renderGeneration;
	__weak MarkdownPreviewCoordinator* weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRenderDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MarkdownPreviewCoordinator* strongSelf = weakSelf;
		if(strongSelf && strongSelf->_renderGeneration == generation)
			[strongSelf render];
	});
}

- (void)render
{
	++_renderGeneration; // cancels a pending delayed render

	OakDocument* document = _document;
	if(!document || !IsMarkdownDocument(document))
		[_preview showNotice:nil actionTitle:nil];

	if(!document)
		return [_preview showPlaceholder:@"No document"];
	if(!IsMarkdownDocument(document))
		return [_preview showPlaceholder:[NSString stringWithFormat:@"“%@” isn’t a Markdown document.", document.displayName]];

	if(UsesGitHubRenderer())
		return [self renderWithGitHubRenderer];

	[_preview showNotice:nil actionTitle:nil];
	[self renderWithBuiltinRenderer];
}

// The unsaved text: what the user sees in the editor
- (void)renderWithBuiltinRenderer
{
	OakDocument* document = _document;
	[_preview showMarkdown:(document.content ?: @"") baseURL:(document.path ? [NSURL fileURLWithPath:document.path] : nil)];
	[self editorDidScroll:nil];
}

// ==============================================
// = GitHub renderer: cmark-gfm, or TM_MARKDOWN =
// ==============================================

- (void)rendererDidChange:(BOOL)rendererChanged
{
	// Chosen by the user: offer to install cmark-gfm if it’s missing
	if(rendererChanged && UsesGitHubRenderer() && !_cmarkPath)
	{
		_offerInstallWhenLocated = YES;
		if(_environment)
			[self locateCmark]; // it may have been installed since we looked
	}
	[self render];
}

- (void)locateCmark
{
	if(_locatingCmark)
		return;
	_locatingCmark = YES;

	__weak MarkdownPreviewCoordinator* weakSelf = self;
	[MarkdownPreviewCmark locateWithCompletion:^(NSString* path, NSDictionary<NSString*, NSString*>* environment){
		if(MarkdownPreviewCoordinator* strongSelf = weakSelf)
			[strongSelf cmarkLocated:path environment:environment];
	}];
}

- (void)cmarkLocated:(NSString*)path environment:(NSDictionary<NSString*, NSString*>*)environment
{
	_locatingCmark = NO;
	_environment   = environment;
	_cmarkPath     = path;

	if(!path && _offerInstallWhenLocated && UsesGitHubRenderer())
		[self offerInstall];
	_offerInstallWhenLocated = NO;

	if(_active)
		[self render];
}

- (void)offerInstall
{
	// Only in the window the user is working in, and only once at a time
	NSWindow* window = _controller.window;
	if(_installController || window.attachedSheet || (NSApp.mainWindow && NSApp.mainWindow != window))
		return;

	__weak MarkdownPreviewCoordinator* weakSelf = self;
	_installController = [[MarkdownPreviewInstallController alloc] init];
	[_installController beginSheetModalForWindow:window environment:_environment completionHandler:^(NSString* path){
		if(MarkdownPreviewCoordinator* strongSelf = weakSelf)
			[strongSelf installFinishedWithPath:path];
	}];
}

- (void)installFinishedWithPath:(NSString*)path
{
	_installController = nil;
	if(path)
	{
		_cmarkPath = path;
		if(_active)
			[self render];
	}
	else if(!_cmarkPath)
	{
		// Cancelled: back to the renderer that works
		[NSUserDefaults.standardUserDefaults setObject:@"builtin" forKey:kUserDefaultsMarkdownPreviewRendererKey];
	}
}

- (void)markdownPreviewPerformNoticeAction:(MarkdownPreviewViewController*)preview
{
	// It may have been installed since we looked, e.g. from another window
	_offerInstallWhenLocated = YES;
	[self locateCmark];
}

// TM_MARKDOWN from .tm_properties or Preferences ▸ Variables, as for the Markdown bundle
- (NSString*)customMarkdownCommandForDocument:(OakDocument*)document environment:(std::map<std::string, std::string>&)res
{
	res = oak::basic_environment();
	res << document.variables;
	res = bundles::scope_variables(res);
	res = variables_for_path(res, to_s(document.path), to_s(document.fileType), to_s([document.path stringByDeletingLastPathComponent] ?: document.directory));

	auto it = res.find("TM_MARKDOWN");
	return it != res.end() && !it->second.empty() ? to_ns(it->second) : nil;
}

- (void)renderWithGitHubRenderer
{
	if(!_environment)
	{
		// Look for cmark-gfm once, showing the built-in rendering meanwhile
		[self locateCmark];
		return [self renderWithBuiltinRenderer];
	}

	OakDocument* document = _document;
	std::map<std::string, std::string> variables;
	NSString* customCommand = [self customMarkdownCommandForDocument:document environment:variables];

	NSString* executable;
	NSArray<NSString*>* arguments;
	BOOL sanitize = NO;
	NSMutableDictionary<NSString*, NSString*>* environment = [_environment mutableCopy];
	if(customCommand)
	{
		for(auto const& pair : variables)
		{
			if(pair.first != "PATH")
				environment[to_ns(pair.first)] = to_ns(pair.second);
		}
		executable = @"/bin/sh";
		arguments  = @[ @"-c", customCommand ];
	}
	else if(_cmarkPath)
	{
		sanitize   = ![NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsMarkdownPreviewAllowRawHTMLKey];
		executable = _cmarkPath;
		arguments  = [MarkdownPreviewCmark argumentsAllowingRawHTML:!sanitize];
	}
	else
	{
		[_preview showNotice:@"cmark-gfm isn’t installed. Showing the built-in renderer." actionTitle:@"Install…"];
		return [self renderWithBuiltinRenderer];
	}

	NSString* markdown       = document.content ?: @"";
	NSURL* documentURL       = document.path ? [NSURL fileURLWithPath:document.path] : nil;
	NSURL* readAccessURL     = MarkdownPreviewReadAccessURL(document.path, _controller.projectPath);
	NSString* name           = customCommand ? @"TM_MARKDOWN" : @"cmark-gfm";
	NSUInteger generation    = _renderGeneration;

	__weak MarkdownPreviewCoordinator* weakSelf = self;
	dispatch_async(_cmarkQueue, ^{
		NSString* error;
		NSString* html = [MarkdownPreviewCmark HTMLFromMarkdown:markdown executable:executable arguments:arguments environment:environment error:&error];
		if(html && sanitize)
			html = MarkdownPreviewSanitizedHTML(html);
		dispatch_async(dispatch_get_main_queue(), ^{
			MarkdownPreviewCoordinator* strongSelf = weakSelf;
			if(!strongSelf || strongSelf->_renderGeneration != generation || strongSelf->_document != document)
				return; // a newer render is on its way

			if(html)
			{
				[strongSelf->_preview showNotice:nil actionTitle:nil];
				[strongSelf->_preview showHTML:html documentURL:documentURL readAccessURL:readAccessURL];
			}
			else
			{
				[strongSelf->_preview showNotice:[NSString stringWithFormat:@"%@ failed: %@ Showing the built-in renderer.", name, error] actionTitle:nil];
				[strongSelf renderWithBuiltinRenderer];
			}
			[strongSelf editorDidScroll:nil];
		});
	});
}

// =============
// = Scrolling =
// =============

// The editor’s first visible line goes to the top of the preview. Both
// renderers know the source lines of their blocks; `fraction` (of the
// document scrolled past) is the fallback when they don’t, e.g. for a
// TM_MARKDOWN command without source positions.
- (void)editorDidScroll:(NSNotification*)aNotification
{
	OakTextView* textView = _controller.textView;
	NSScrollView* scrollView = textView.enclosingScrollView;
	CGFloat top = NSMinY(scrollView.contentView.bounds);
	CGFloat scrollable = NSHeight(scrollView.documentView.frame) - NSHeight(scrollView.contentView.bounds);
	CGFloat fraction = scrollable > 0 ? top / scrollable : 0;

	CGFloat y = [textView convertPoint:NSMakePoint(0, top) fromView:scrollView.documentView].y;
	[_preview scrollToSourceLine:[self sourceLineAtEditorY:y] fraction:fraction];
}

// The editor’s y where a 1-based source line starts; past the last line, the end of the text
- (CGFloat)editorYForSourceLine:(NSUInteger)line
{
	OakTextView* textView = _controller.textView;
	GVLineRecord record = [textView lineFragmentForLine:line - 1 column:0];
	if(record.lineNumber == line - 1)
		return record.firstY;
	return [textView lineFragmentForLine:line - 1 column:NSUIntegerMax].lastY; // clamped to the last line
}

// A fractional source line for the editor’s y. Between the preview’s anchor
// lines, it moves in proportion to the editor’s pixels rather than its lines:
// a wrapped paragraph is one line but many rows, and the preview should
// scroll through it as evenly as through short lines.
- (CGFloat)sourceLineAtEditorY:(CGFloat)y
{
	OakTextView* textView = _controller.textView;
	GVLineRecord record = [textView lineRecordForPosition:y];
	if(record.lineNumber == NSNotFound)
		return 1;

	// The record is for one soft-wrapped row; measure the whole line, so the fraction doesn’t restart on each row
	CGFloat firstY = [self editorYForSourceLine:record.lineNumber + 1];
	CGFloat lastY  = [self editorYForSourceLine:record.lineNumber + 2];
	CGFloat height = lastY - firstY;
	CGFloat line   = record.lineNumber + 1 + (height > 0 ? MIN(MAX((y - firstY) / height, 0), 1) : 0);

	NSArray<NSNumber*>* anchorLines = _preview.anchorLines;
	NSUInteger next = [anchorLines indexOfObject:@(line) inSortedRange:NSMakeRange(0, anchorLines.count) options:NSBinarySearchingInsertionIndex|NSBinarySearchingLastEqual usingComparator:^NSComparisonResult(NSNumber* lhs, NSNumber* rhs){
		return [lhs compare:rhs];
	}];
	if(next == 0 || next >= anchorLines.count)
		return line;

	// The anchors around y, two on each side, so the curve’s slopes match its neighbours’
	std::vector<std::pair<CGFloat, CGFloat>> points; // editor y → line
	for(NSUInteger i = next >= 2 ? next - 2 : 0; i < MIN(next + 2, anchorLines.count); ++i)
	{
		CGFloat anchorLine = anchorLines[i].doubleValue;
		CGFloat anchorY    = [self editorYForSourceLine:(NSUInteger)anchorLine];
		if(points.empty() || (anchorY > points.back().first && anchorLine > points.back().second))
			points.emplace_back(anchorY, anchorLine);
	}
	return points.size() >= 2 ? MarkdownPreviewInterpolate(points, y) : line;
}

- (void)markdownPreviewDidUpdateAnchorLines:(MarkdownPreviewViewController*)preview
{
	[self editorDidScroll:nil];
}

// Web and mail links open in their apps; links to files open in TextMate
- (void)markdownPreview:(MarkdownPreviewViewController*)preview openURL:(NSURL*)url
{
	if(!url.isFileURL)
		return (void)[NSWorkspace.sharedWorkspace openURL:url];

	BOOL isDirectory = NO;
	if(![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDirectory])
		return NSBeep();
	if(isDirectory)
		return (void)[NSWorkspace.sharedWorkspace openURL:url];

	OakDocument* document = [OakDocumentController.sharedInstance documentWithPath:url.path];
	[OakDocumentController.sharedInstance showDocument:document andSelect:text::range_t::undefined inProject:_controller.identifier bringToFront:YES];
}
@end

// =====================
// = Window Controller =
// =====================

@implementation DocumentWindowController (MarkdownPreview)
- (MarkdownPreviewCoordinator*)markdownPreviewCoordinator
{
	return objc_getAssociatedObject(self, kMarkdownPreviewCoordinatorKey);
}

- (MarkdownPreviewCoordinator*)markdownPreviewCoordinatorCreatingIfNeeded
{
	MarkdownPreviewCoordinator* coordinator = self.markdownPreviewCoordinator;
	if(!coordinator)
	{
		coordinator = [[MarkdownPreviewCoordinator alloc] initWithWindowController:self];
		objc_setAssociatedObject(self, kMarkdownPreviewCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return coordinator;
}

- (BOOL)markdownPreviewVisible
{
	MarkdownPreviewCoordinator* coordinator = self.markdownPreviewCoordinator;
	return coordinator && [self.editorPanelsView.panels containsObject:coordinator.editorPanel];
}

- (void)setMarkdownPreviewVisible:(BOOL)flag
{
	if(self.markdownPreviewVisible == flag)
		return;

	MarkdownPreviewCoordinator* coordinator = [self markdownPreviewCoordinatorCreatingIfNeeded];
	if(flag)
	{
		coordinator.editorPanel.edge = MarkdownPreviewEdge();
		[self.editorPanelsView addPanel:coordinator.editorPanel];
		coordinator.active = YES;
	}
	else
	{
		if([self.window.firstResponder isKindOfClass:[NSView class]] && [(NSView*)self.window.firstResponder isDescendantOf:coordinator.preview.view])
			[self.window makeFirstResponder:self.textView];
		coordinator.active = NO;
		[self.editorPanelsView removePanel:coordinator.editorPanel];
	}
}

- (void)updateMarkdownPreviewPlacement
{
	self.markdownPreviewCoordinator.editorPanel.edge = MarkdownPreviewEdge();
}

- (void)shutdownMarkdownPreview
{
	self.markdownPreviewCoordinator.active = NO;
}

- (IBAction)toggleMarkdownPreview:(id)sender
{
	self.markdownPreviewVisible = !self.markdownPreviewVisible;
}

- (IBAction)takeMarkdownPreviewPlacementFrom:(id)sender
{
	NSInteger tag = [sender tag];
	if(tag < 0 || tag >= kPlacements.count)
		return;
	[NSUserDefaults.standardUserDefaults setObject:kPlacements[tag] forKey:kUserDefaultsMarkdownPreviewPlacementKey];
	[self updateMarkdownPreviewPlacement];
}

- (BOOL)isMarkdownPreviewMenuItem:(NSMenuItem*)menuItem
{
	SEL action = menuItem.action;
	return action == @selector(toggleMarkdownPreview:) || action == @selector(takeMarkdownPreviewPlacementFrom:);
}

- (BOOL)validateMarkdownPreviewMenuItem:(NSMenuItem*)menuItem
{
	if(menuItem.action == @selector(toggleMarkdownPreview:))
	{
		menuItem.title = self.markdownPreviewVisible ? @"Hide Markdown Preview" : @"Show Markdown Preview";
	}
	else if(menuItem.action == @selector(takeMarkdownPreviewPlacementFrom:))
	{
		NSString* placement = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsMarkdownPreviewPlacementKey] ?: @"auto";
		NSUInteger index = [kPlacements indexOfObject:placement];
		menuItem.state = (index == NSNotFound ? 0 : index) == menuItem.tag ? NSControlStateValueOn : NSControlStateValueOff;
	}
	return YES;
}
@end
