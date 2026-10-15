#import "DocumentWindowController+MarkdownPreview.h"
#import "DocumentWindowController+Agent.h"
#import "DocumentWindowController+EditorPanels.h"
#import <MarkdownPreview/MarkdownPreviewViewController.h>
#import <OakEditorPanels/OakEditorPanelsView.h>
#import <OakTextView/OakTextView.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <text/types.h>
#import <objc/runtime.h>

NSString* const kUserDefaultsMarkdownPreviewPlacementKey = @"markdownPreviewPlacement";

static NSTimeInterval const kRenderDelay = 0.15;

static void* kMarkdownPreviewCoordinatorKey = &kMarkdownPreviewCoordinatorKey;
static void* kSelectedDocumentContext       = &kSelectedDocumentContext;
static void* kFileTypeContext               = &kFileTypeContext;

static NSArray<NSString*>* const kPlacements = @[ @"auto", @"left", @"right", @"top", @"bottom" ]; // index is the menu item tag

// Private properties of DocumentWindowController, defined in its main file
@interface DocumentWindowController (MarkdownPreviewPrivate)
@property (nonatomic) OakTextView* textView;
@end

static BOOL IsMarkdownDocument (OakDocument* document)
{
	if([document.fileType hasPrefix:@"text.html.markdown"])
		return YES;
	static NSSet<NSString*>* const extensions = [NSSet setWithArray:@[ @"md", @"markdown", @"mdown", @"mkd", @"mkdn" ]];
	return [extensions containsObject:document.path.pathExtension.lowercaseString];
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

// ==================================
// = Keeps the preview up to date =
// ==================================

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

		// Scroll with the editor
		_editorClipView = _controller.textView.enclosingScrollView.contentView;
		_editorClipView.postsBoundsChangedNotifications = YES;
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editorDidScroll:) name:NSViewBoundsDidChangeNotification object:_editorClipView];

		self.document = _controller.selectedDocument;
	}
	else
	{
		[_controller removeObserver:self forKeyPath:@"selectedDocument" context:kSelectedDocumentContext];
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
	if(!document)
		return [_preview showPlaceholder:@"No document"];
	if(!IsMarkdownDocument(document))
		return [_preview showPlaceholder:[NSString stringWithFormat:@"“%@” isn’t a Markdown document.", document.displayName]];

	// The unsaved text: what the user sees in the editor
	[_preview showMarkdown:(document.content ?: @"") baseURL:(document.path ? [NSURL fileURLWithPath:document.path] : nil)];
	[self editorDidScroll:nil];
}

// Proportional: the same fraction of the document is scrolled past in both
- (void)editorDidScroll:(NSNotification*)aNotification
{
	NSScrollView* scrollView = _controller.textView.enclosingScrollView;
	CGFloat scrollable = NSHeight(scrollView.documentView.frame) - NSHeight(scrollView.contentView.bounds);
	_preview.scrollFraction = scrollable > 0 ? NSMinY(scrollView.contentView.bounds) / scrollable : 0;
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

// ======================
// = Window Controller =
// ======================

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
