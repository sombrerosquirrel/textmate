#import "DocumentWindowController+Agent.h"
#import "ProjectLayoutView.h"
#import <AgentUI/AgentPanelViewController.h>
#import <OakEditorPanels/OakEditorPanelsView.h>
#import <OakTextView/OakDocumentView.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <text/types.h>
#import <objc/runtime.h>

// Private properties of DocumentWindowController, defined in its main file
@interface DocumentWindowController (AgentPrivate)
@property (nonatomic) ProjectLayoutView* layoutView;
@property (nonatomic) OakDocumentView* documentView;
@property (nonatomic) OakTextView* textView;
@end

// Implemented by OakTextView (NSTextInputClient and snippet insertion) but not declared in its public header
@interface OakTextView (AgentEditorAccess)
- (NSRange)selectedRange;
- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange;
- (void)insertSnippetWithOptions:(NSDictionary*)someOptions;
@end

static NSString* const kUserDefaultsAgentPanelPlacementKey = @"agentPanelPlacement"; // @"left" or @"right" (default)

static void* kAgentPanelKey       = &kAgentPanelKey;
static void* kAgentEditorPanelKey = &kAgentEditorPanelKey;

static OakEditorPanelEdge AgentPanelEdge ()
{
	return [[NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsAgentPanelPlacementKey] isEqualToString:@"left"] ? OakEditorPanelEdgeLeft : OakEditorPanelEdgeRight;
}

// Snippet syntax treats \, $ and ` specially; escape them to insert text literally
static NSString* EscapeSnippetText (NSString* text)
{
	NSMutableString* res = [NSMutableString stringWithCapacity:text.length];
	for(NSUInteger i = 0; i < text.length; ++i)
	{
		unichar ch = [text characterAtIndex:i];
		if(ch == '\\' || ch == '$' || ch == '`')
			[res appendString:@"\\"];
		[res appendFormat:@"%C", ch];
	}
	return res;
}

static NSUInteger LineNumberAtIndex (NSString* text, NSUInteger index)
{
	NSUInteger line = 1;
	index = MIN(index, text.length);
	for(NSUInteger i = 0; i < index; ++i)
	{
		if([text characterAtIndex:i] == '\n')
			++line;
	}
	return line;
}

@interface DocumentWindowController (AgentPanelDelegate) <AgentPanelDelegate>
@end

@implementation DocumentWindowController (Agent)

- (OakEditorPanelsView*)editorPanelsView
{
	return [self.layoutView.documentView isKindOfClass:[OakEditorPanelsView class]] ? (OakEditorPanelsView*)self.layoutView.documentView : nil;
}

- (AgentPanelViewController*)agentPanel
{
	return objc_getAssociatedObject(self, kAgentPanelKey);
}

- (AgentPanelViewController*)agentPanelCreatingIfNeeded
{
	AgentPanelViewController* panel = self.agentPanel;
	if(!panel)
	{
		panel = [[AgentPanelViewController alloc] init];
		panel.delegate = self;
		objc_setAssociatedObject(self, kAgentPanelKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return panel;
}

// The agent panel as docked beside the editor
- (OakEditorPanel*)agentEditorPanel
{
	OakEditorPanel* editorPanel = objc_getAssociatedObject(self, kAgentEditorPanelKey);
	if(!editorPanel)
	{
		editorPanel = [[OakEditorPanel alloc] initWithView:[self agentPanelCreatingIfNeeded].view edge:AgentPanelEdge()];
		editorPanel.autosaveName = @"agentPanel"; // agentPanelWidth
		objc_setAssociatedObject(self, kAgentEditorPanelKey, editorPanel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return editorPanel;
}

- (void)setupAgentPanelSupport
{
	// The editor goes inside a panels container so the panel can sit beside it
	if(!self.editorPanelsView)
		self.layoutView.documentView = [[OakEditorPanelsView alloc] initWithEditorView:self.documentView];
}

- (void)updateAgentPanelPlacement
{
	if(OakEditorPanel* editorPanel = objc_getAssociatedObject(self, kAgentEditorPanelKey))
		editorPanel.edge = AgentPanelEdge();
}

- (void)shutdownAgentPanel
{
	[self.agentPanel shutdown];
}

- (BOOL)agentPanelVisible
{
	OakEditorPanel* editorPanel = objc_getAssociatedObject(self, kAgentEditorPanelKey);
	return editorPanel && [self.editorPanelsView.panels containsObject:editorPanel];
}

- (void)setAgentPanelVisible:(BOOL)flag
{
	if(self.agentPanelVisible == flag)
		return;

	if(flag)
	{
		AgentPanelViewController* panel = [self agentPanelCreatingIfNeeded];
		[self.editorPanelsView addPanel:self.agentEditorPanel];
		[panel startSessionIfNeeded];
		[panel focusPrompt];
	}
	else
	{
		if([self.window.firstResponder isKindOfClass:[NSView class]] && [(NSView*)self.window.firstResponder isDescendantOf:self.agentPanel.view])
			[self.window makeFirstResponder:self.textView];
		[self.editorPanelsView removePanel:self.agentEditorPanel];
	}
}

- (IBAction)toggleAgentPanel:(id)sender
{
	// Like VS Code: the shortcut focuses the chat if it’s open but not focused
	BOOL panelHasFocus = [self.window.firstResponder isKindOfClass:[NSView class]] && [(NSView*)self.window.firstResponder isDescendantOf:self.agentPanel.view];
	if(self.agentPanelVisible && !panelHasFocus && [sender isKindOfClass:[NSMenuItem class]] && [[sender keyEquivalent] length] && NSApp.currentEvent.type == NSEventTypeKeyDown)
		return [self.agentPanel focusPrompt];
	self.agentPanelVisible = !self.agentPanelVisible;
}

- (IBAction)toggleAgentPanelPlacement:(id)sender
{
	BOOL onRight = AgentPanelEdge() == OakEditorPanelEdgeRight;
	[NSUserDefaults.standardUserDefaults setObject:(onRight ? @"left" : @"right") forKey:kUserDefaultsAgentPanelPlacementKey];
	[self updateAgentPanelPlacement];
}

- (IBAction)askAgentAboutSelection:(id)sender
{
	self.agentPanelVisible = YES;
	[self.agentPanel askAboutSelection];
}

- (BOOL)isAgentPanelMenuItem:(NSMenuItem*)menuItem
{
	SEL action = menuItem.action;
	return action == @selector(toggleAgentPanel:) || action == @selector(toggleAgentPanelPlacement:) || action == @selector(askAgentAboutSelection:);
}

- (BOOL)validateAgentPanelMenuItem:(NSMenuItem*)menuItem
{
	if(menuItem.action == @selector(toggleAgentPanel:))
		menuItem.title = self.agentPanelVisible ? @"Hide Agent Panel" : @"Show Agent Panel";
	else if(menuItem.action == @selector(toggleAgentPanelPlacement:))
		menuItem.title = AgentPanelEdge() == OakEditorPanelEdgeRight ? @"Move Agent Panel to Left Side" : @"Move Agent Panel to Right Side";
	return YES;
}
@end

@implementation DocumentWindowController (AgentPanelDelegate)
- (NSString*)projectPathForAgentPanel:(AgentPanelViewController*)agentPanel
{
	return self.projectPath ?: self.selectedDocument.directory ?: NSHomeDirectory();
}

- (AgentAttachment*)attachmentForDocument:(OakDocument*)document
{
	if(!document.path)
		return nil;
	// Unsaved changes are what the user sees, so send those
	return [AgentAttachment fileAttachmentWithPath:document.path text:(document.isDocumentEdited ? document.content : nil)];
}

- (AgentAttachment*)currentFileAttachmentForAgentPanel:(AgentPanelViewController*)agentPanel
{
	return [self attachmentForDocument:self.selectedDocument];
}

- (AgentAttachment*)selectionAttachmentForAgentPanel:(AgentPanelViewController*)agentPanel
{
	OakTextView* textView = self.textView;
	if(!textView.hasSelection)
		return nil;

	NSRange range  = textView.selectedRange;
	NSString* text = [textView attributedSubstringForProposedRange:range actualRange:nullptr].string;
	if(!text.length)
		return nil;

	NSString* content    = self.selectedDocument.content ?: @"";
	NSUInteger firstLine = LineNumberAtIndex(content, range.location);
	NSUInteger lastLine  = LineNumberAtIndex(content, NSMaxRange(range) - ([text hasSuffix:@"\n"] ? 1 : 0));
	return [AgentAttachment selectionAttachmentWithPath:self.selectedDocument.path displayName:self.selectedDocument.displayName text:text firstLine:firstLine lastLine:lastLine];
}

- (NSArray<AgentAttachment*>*)openFileAttachmentsForAgentPanel:(AgentPanelViewController*)agentPanel
{
	NSMutableArray* res = [NSMutableArray array];
	for(OakDocument* document in self.documents)
	{
		if(AgentAttachment* attachment = [self attachmentForDocument:document])
			[res addObject:attachment];
	}
	return res;
}

- (void)agentPanel:(AgentPanelViewController*)agentPanel insertText:(NSString*)text
{
	[self.window makeFirstResponder:self.textView];
	[self.textView insertSnippetWithOptions:@{ @"content": EscapeSnippetText(text) }];
}

- (void)agentPanel:(AgentPanelViewController*)agentPanel openFile:(NSString*)path line:(NSUInteger)line
{
	OakDocument* document = [OakDocumentController.sharedInstance documentWithPath:path];
	text::range_t selection = line ? text::range_t(text::pos_t(line - 1, 0)) : text::range_t::undefined;
	[OakDocumentController.sharedInstance showDocument:document andSelect:selection inProject:self.identifier bringToFront:YES];
}
@end
