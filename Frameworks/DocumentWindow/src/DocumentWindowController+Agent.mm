#import "DocumentWindowController+Agent.h"
#import "DocumentWindowController+EditorPanels.h"
#import <AgentUI/AgentPanelViewController.h>
#import <AgentUI/AgentTranscriptView.h>
#import <AgentClient/AgentFileSystem.h>
#import <FileBrowser/FileBrowserViewController.h>
#import <OakEditorPanels/OakEditorPanelsView.h>
#import <OakTextView/OakDocumentView.h>
#import <OakTextView/OakCodeView.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <settings/settings.h>
#import <io/path.h>
#import <Preferences/Keys.h>
#import <bundles/bundles.h>
#import <theme/OakTheme.h>
#import <text/case.h>
#import <text/types.h>
#import <ns/ns.h>
#import <objc/runtime.h>

// Private properties of DocumentWindowController, defined in its main file
@interface DocumentWindowController (AgentPrivate)
@property (nonatomic) OakTextView* textView;
@property (nonatomic) FileBrowserViewController* fileBrowser;
@end

// Implemented by OakTextView (NSTextInputClient and snippet insertion) but not declared in its public header
@interface OakTextView (AgentEditorAccess)
- (NSRange)selectedRange;
- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange;
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange;
- (void)insertSnippetWithOptions:(NSDictionary*)someOptions;
- (NSMutableAttributedString*)syntaxHighlight:(NSString*)code withGrammar:(NSString*)grammarScope; // OakTextView+Hover, in the view’s theme
@end

// Implemented by OakDocument but not declared in its public header
@interface OakDocument (AgentReload)
- (void)importDocumentChanges:(id)sender;
@end

NSString* const kUserDefaultsAgentPanelPlacementKey = @"agentPanelPlacement";

static void* kAgentPanelKey              = &kAgentPanelKey;
static void* kAgentEditorPanelKey        = &kAgentEditorPanelKey;
static void* kAgentPanelFocusObserverKey = &kAgentPanelFocusObserverKey;
static void* kAgentPanelThemeUUIDKey     = &kAgentPanelThemeUUIDKey;

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

// The byte range of `from` that differs from `to`, and its replacement; kept
// on UTF-8 character boundaries. Replacing only that range keeps the caret,
// folds and marks elsewhere in the document.
static std::pair<std::pair<size_t, size_t>, std::string> ChangedRange (std::string const& from, std::string const& to)
{
	size_t prefix = 0, maxPrefix = std::min(from.size(), to.size());
	while(prefix < maxPrefix && from[prefix] == to[prefix])
		++prefix;
	while(prefix > 0 && (from[prefix] & 0xC0) == 0x80)
		--prefix;

	size_t suffix = 0, maxSuffix = std::min(from.size(), to.size()) - prefix;
	while(suffix < maxSuffix && from[from.size() - suffix - 1] == to[to.size() - suffix - 1])
		++suffix;
	while(suffix > 0 && (from[from.size() - suffix] & 0xC0) == 0x80)
		--suffix;

	return { { prefix, from.size() - suffix }, to.substr(prefix, to.size() - prefix - suffix) };
}

// TextMate’s “line:column” for a byte offset; both are 1-based, the column counts bytes
static NSString* PositionString (std::string const& text, size_t offset)
{
	size_t line = 1 + std::count(text.begin(), text.begin() + offset, '\n');
	size_t eol  = offset ? text.rfind('\n', offset - 1) : std::string::npos;
	size_t bol  = eol == std::string::npos ? 0 : eol + 1;
	return [NSString stringWithFormat:@"%zu:%zu", line, offset - bol + 1];
}

// Selects the inserted text from its first to its last non-blank character,
// so the highlight follows the code rather than the lines and indentation
// around it; all-blank text is selected as is
static NSString* InsertedTextSelectionString (std::string const& text, size_t from, size_t to)
{
	auto isBlank = [](char ch){ return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'; };
	size_t first = from, last = to;
	while(first < last && isBlank(text[first]))
		++first;
	while(first < last && isBlank(text[last - 1]))
		--last;
	if(first == last)
		std::tie(first, last) = std::make_pair(from, to);
	return first == last ? PositionString(text, first) : [NSString stringWithFormat:@"%@-%@", PositionString(text, first), PositionString(text, last)];
}

// The grammar for a code fence’s language (“python”, “py”, “objc”, “sh”, …):
// a common alias, or a grammar whose name or file type is the language, or
// whose scope is source.‹language›. Nil if none is installed.
static NSString* GrammarScopeForLanguage (NSString* language)
{
	static NSDictionary<NSString*, NSString*>* const aliases = @{
		@"objc":  @"source.objc",   @"objective-c":   @"source.objc",
		@"objc++": @"source.objc++", @"objective-c++": @"source.objc++",
		@"c++":   @"source.c++",    @"cpp":           @"source.c++",
		@"sh":    @"source.shell",  @"bash":          @"source.shell", @"zsh": @"source.shell", @"shell": @"source.shell", @"console": @"source.shell",
		@"js":    @"source.js",     @"javascript":    @"source.js",    @"jsx": @"source.js",
		@"html":  @"text.html.basic", @"xml":         @"text.xml",
		@"md":    @"text.html.markdown", @"markdown": @"text.html.markdown",
		@"diff":  @"source.diff",   @"patch":         @"source.diff",
	};
	static NSMutableDictionary<NSString*, id>* const cache = [NSMutableDictionary dictionary];

	NSString* key = language.lowercaseString;
	if(id cached = cache[key])
		return cached == NSNull.null ? nil : cached;

	std::string res;
	if(NSString* alias = aliases[key])
	{
		if(!bundles::query(bundles::kFieldGrammarScope, to_s(alias), scope::wildcard, bundles::kItemTypeGrammar).empty())
			res = to_s(alias);
	}

	std::string const name = to_s(key);
	for(auto const& item : res.empty() ? bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeGrammar) : std::vector<bundles::item_ptr>())
	{
		std::string const scope = item->value_for_field(bundles::kFieldGrammarScope);
		bool matches = text::lowercase(item->name()) == name || scope == "source." + name;
		for(auto const& extension : item->values_for_field(bundles::kFieldGrammarExtension))
			matches = matches || text::lowercase(extension) == name;
		if(matches && !scope.empty())
		{
			res = scope;
			break;
		}
	}

	cache[key] = res.empty() ? (id)NSNull.null : to_ns(res);
	return res.empty() ? nil : to_ns(res);
}

@interface OakCodeView (AgentCodeBlockView) <AgentCodeBlockView>
@end

@implementation OakCodeView (AgentCodeBlockView)
@end

static BOOL IsSameFile (NSString* lhs, NSString* rhs)
{
	return [lhs isEqualToString:rhs] || [lhs.stringByResolvingSymlinksInPath isEqualToString:rhs.stringByResolvingSymlinksInPath];
}

@interface DocumentWindowController (AgentPanelDelegate) <AgentPanelDelegate, AgentDocumentProvider>
@end

// Keeps the editor’s caret blinking while the agent panel has focus, so the
// user sees where “here” is
@interface AgentPanelFocusObserver : NSObject
- (instancetype)initWithWindowController:(DocumentWindowController*)controller;
@end

@interface DocumentWindowController (AgentFocus)
- (AgentPanelViewController*)agentPanel;
@end

static void* kFirstResponderContext = &kFirstResponderContext;

@implementation AgentPanelFocusObserver
{
	__weak DocumentWindowController* _controller;
	NSWindow* _window;
}

- (instancetype)initWithWindowController:(DocumentWindowController*)controller
{
	if(self = [super init])
	{
		_controller = controller;
		_window     = controller.window;
		[_window addObserver:self forKeyPath:@"firstResponder" options:0 context:kFirstResponderContext];
	}
	return self;
}

- (void)dealloc
{
	[_window removeObserver:self forKeyPath:@"firstResponder" context:kFirstResponderContext];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if(context != kFirstResponderContext)
		return [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];

	DocumentWindowController* controller = _controller;
	NSResponder* responder = _window.firstResponder;
	BOOL panelHasFocus = [responder isKindOfClass:[NSView class]] && controller.agentPanel && [(NSView*)responder isDescendantOf:controller.agentPanel.view];
	controller.textView.showsCaretWhenInactive = panelHasFocus;
	if(panelHasFocus)
		[controller.agentPanel currentFileDidChange]; // e.g. an untitled document was saved
}
@end

@implementation DocumentWindowController (Agent)

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
		objc_setAssociatedObject(self, kAgentPanelFocusObserverKey, [[AgentPanelFocusObserver alloc] initWithWindowController:self], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

- (void)updateAgentPanelPlacement
{
	if(OakEditorPanel* editorPanel = objc_getAssociatedObject(self, kAgentEditorPanelKey))
		editorPanel.edge = AgentPanelEdge();
}

- (void)shutdownAgentPanel
{
	[self.agentPanel shutdown];
}

// Switching documents sets the theme again, mostly to the same one; the panel
// only redraws its transcript for a different one
- (void)agentPanelThemeDidChange
{
	NSString* themeUUID = self.textView.themeUUID;
	if([themeUUID isEqualToString:objc_getAssociatedObject(self, kAgentPanelThemeUUIDKey)])
		return;
	objc_setAssociatedObject(self, kAgentPanelThemeUUIDKey, themeUUID, OBJC_ASSOCIATION_COPY_NONATOMIC);
	[self.agentPanel themeDidChange];
}

- (void)agentPanelCurrentFileDidChange
{
	[self.agentPanel currentFileDidChange];
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

- (IBAction)newAgentChat:(id)sender
{
	self.agentPanelVisible = YES;
	[self.agentPanel newChat:self];
	[self.agentPanel focusPrompt];
}

- (IBAction)askAgentAboutSelection:(id)sender
{
	self.agentPanelVisible = YES;
	[self.agentPanel askAboutSelection];
}

// The line at `index` in the text view, for the inline prompt to sit under;
// the top of the visible area if it’s scrolled out of view
static NSRect LineRectAtIndex (OakTextView* textView, NSUInteger index)
{
	NSRect screenRect = [textView firstRectForCharacterRange:NSMakeRange(index, 0) actualRange:nullptr];
	NSRect caretRect  = [textView convertRect:[textView.window convertRectFromScreen:screenRect] fromView:nil];
	if(!NSIntersectsRect(caretRect, textView.visibleRect))
		caretRect = NSMakeRect(NSMidX(textView.visibleRect), NSMinY(textView.visibleRect), 1, 1);
	caretRect.size.width = MAX(caretRect.size.width, 1);
	return caretRect;
}

- (IBAction)askAgentAtCaret:(id)sender
{
	OakTextView* textView = self.textView;
	if(!textView)
		return;
	[self.window makeFirstResponder:textView];
	[[self agentPanelCreatingIfNeeded] showInlinePromptRelativeToRect:LineRectAtIndex(textView, textView.selectedRange.location) ofView:textView];
}

- (NSRect)selectionEndRectForAgentPanel:(AgentPanelViewController*)agentPanel
{
	OakTextView* textView = self.textView;
	return textView ? LineRectAtIndex(textView, NSMaxRange(textView.selectedRange)) : NSZeroRect;
}

// Sent by the file browser’s Add to Agent Chat
- (IBAction)addFilesToAgentChat:(id)sender
{
	NSArray<NSURL*>* urls = [sender isKindOfClass:[FileBrowserViewController class]] ? [(FileBrowserViewController*)sender selectedFileURLs] : @[ ];
	if(!urls.count)
		return;
	self.agentPanelVisible = YES;
	[self.agentPanel addFilesAtPaths:[urls valueForKey:@"path"]];
}

- (BOOL)isAgentPanelMenuItem:(NSMenuItem*)menuItem
{
	SEL action = menuItem.action;
	return action == @selector(toggleAgentPanel:) || action == @selector(toggleAgentPanelPlacement:) || action == @selector(newAgentChat:) || action == @selector(askAgentAboutSelection:) || action == @selector(askAgentAtCaret:);
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
// The agent’s working directory:
// 1. The project folder, when one was chosen: a folder opened as a project, or
//    projectDirectory in .tm_properties. The agent finds .claude there.
// 2. The folder of the document, if it has been saved (an untitled document’s
//    backup location doesn’t count).
// 3. The folder at the top of the File Browser (a preference).
// 4. The home folder.
// The window’s projectPath isn’t used: without a project it falls back to the
// File Browser or the document, in the opposite order.
- (NSString*)projectPathForAgentPanel:(AgentPanelViewController*)agentPanel
{
	if(NSString* projectFolder = [self chosenProjectFolder])
		return projectFolder;
	if(NSString* documentPath = self.selectedDocument.path)
		return documentPath.stringByDeletingLastPathComponent;
	if([NSUserDefaults.standardUserDefaults boolForKey:kUserDefaultsAgentUsesFileBrowserFolderKey])
	{
		if(NSString* fileBrowserFolder = [self searchRootForAgentPanel:agentPanel])
			return fileBrowserFolder;
	}
	return NSHomeDirectory();
}

- (NSString*)chosenProjectFolder
{
	if(self.defaultProjectPath)
		return self.defaultProjectPath;

	// Read from where the document is, or else what the File Browser shows
	NSString* documentPath = self.selectedDocument.path;
	NSString* folder = documentPath.stringByDeletingLastPathComponent ?: (self.fileBrowserVisible ? self.fileBrowser.path : nil);
	if(!folder)
		return nil;
	std::string const projectDirectory = settings_for_path(documentPath ? to_s(documentPath) : NULL_STR, scope::scope_t(), to_s(folder)).get(kSettingsProjectDirectoryKey, NULL_STR);
	return path::is_absolute(projectDirectory) ? to_ns(path::normalize(projectDirectory)) : nil;
}

- (NSDictionary<NSString*, NSColor*>*)codeColorsForAgentPanel:(AgentPanelViewController*)agentPanel
{
	bundles::item_ptr themeItem = self.textView.themeUUID ? bundles::lookup(to_s(self.textView.themeUUID)) : bundles::item_ptr();
	OakTheme* theme = themeItem ? [[OakTheme alloc] initWithBundleItem:themeItem] : nil;
	if(!theme.backgroundColor || !theme.foregroundColor)
		return nil;
	return @{ @"backgroundColor": theme.backgroundColor, @"textColor": theme.foregroundColor };
}

- (NSAttributedString*)agentPanel:(AgentPanelViewController*)agentPanel highlightCode:(NSString*)code language:(NSString*)language
{
	NSString* grammarScope = GrammarScopeForLanguage(language);
	return grammarScope ? [self.textView syntaxHighlight:code withGrammar:grammarScope] : nil;
}

- (NSView<AgentCodeBlockView>*)agentPanel:(AgentPanelViewController*)agentPanel viewForCode:(NSString*)code language:(NSString*)language
{
	OakCodeView* view = [[OakCodeView alloc] initWithCode:code fileType:language ? GrammarScopeForLanguage(language) : nil];
	view.textView.themeUUID = self.textView.themeUUID; // the font is the one set for the grammar
	return view;
}

- (NSString*)agentPanel:(AgentPanelViewController*)agentPanel displayNameForLanguage:(NSString*)language
{
	NSString* grammarScope = GrammarScopeForLanguage(language);
	std::vector<bundles::item_ptr> const items = grammarScope ? bundles::query(bundles::kFieldGrammarScope, to_s(grammarScope), scope::wildcard, bundles::kItemTypeGrammar) : std::vector<bundles::item_ptr>();
	return items.empty() ? nil : to_ns(items.front()->name());
}

- (NSArray<NSString*>*)openFilePathsForAgentPanel:(AgentPanelViewController*)agentPanel
{
	NSMutableArray<NSString*>* res = [NSMutableArray array];
	for(OakDocument* document in self.documents)
	{
		if(document.path)
			[res addObject:document.path];
	}
	return res;
}

- (void)agentPanelShowChat:(AgentPanelViewController*)agentPanel
{
	self.agentPanelVisible = YES;
	[agentPanel focusPrompt];
}

- (NSDictionary<NSString*, NSString*>*)agentSettingsForAgentPanel:(AgentPanelViewController*)agentPanel
{
	settings_t const settings = settings_for_path(NULL_STR, "", to_s([self projectPathForAgentPanel:agentPanel]));
	NSMutableDictionary* res = [NSMutableDictionary dictionary];
	for(NSString* key in @[ @"agentName", @"agentCommand" ])
	{
		std::string const value = settings.get(to_s(key), std::string());
		if(!value.empty())
			res[key] = to_ns(value);
	}
	return res;
}

- (AgentAttachment*)attachmentForDocument:(OakDocument*)document
{
	if(!document.path)
		return nil;
	// Unsaved changes are what the user sees, so send those
	return [AgentAttachment fileAttachmentWithPath:document.path text:(document.isDocumentEdited ? document.content : nil)];
}

// Includes the cursor position so the agent knows where “here” is
- (NSString*)searchRootForAgentPanel:(AgentPanelViewController*)agentPanel
{
	// nil for locations that aren’t folders on disk (e.g. SCM status, Favorites)
	NSString* path = self.fileBrowserVisible ? self.fileBrowser.path : nil;
	BOOL isDirectory = NO;
	if(path && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory)
		return path;
	return nil;
}

- (AgentAttachment*)currentFileAttachmentForAgentPanel:(AgentPanelViewController*)agentPanel
{
	OakDocument* document = self.selectedDocument;
	NSRange selection     = self.textView.selectedRange;
	NSString* content     = document.isLoaded ? document.content : nil;
	if(!document.path || !content || selection.location == NSNotFound || selection.location > content.length)
		return [self attachmentForDocument:document];

	NSUInteger lineStart = [content lineRangeForRange:NSMakeRange(selection.location, 0)].location;
	NSUInteger line      = LineNumberAtIndex(content, selection.location);
	NSUInteger column    = selection.location - lineStart + 1;
	return [AgentAttachment fileAttachmentWithPath:document.path text:(document.isDocumentEdited ? content : nil) cursorLine:line column:column];
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

- (NSDictionary*)agentPanel:(AgentPanelViewController*)agentPanel applyText:(NSString*)text
{
	return [self applyAgentText:text afterSelection:NO];
}

- (NSDictionary*)agentPanel:(AgentPanelViewController*)agentPanel applyTextAfterSelection:(NSString*)text
{
	return [self applyAgentText:text afterSelection:YES];
}

- (NSDictionary*)applyAgentText:(NSString*)text afterSelection:(BOOL)afterSelection
{
	OakDocument* document = self.selectedDocument;
	OakTextView* textView = self.textView;
	if(!document.isLoaded || !textView)
		return nil;

	NSString* originalText = document.content ?: @"";
	NSRange range;
	if(afterSelection)
	{
		// After the selection or caret, on lines of its own
		NSRange const selection = textView.selectedRange;
		range = NSMakeRange(MIN(NSMaxRange(selection), originalText.length), 0);
		if(range.location && [originalText characterAtIndex:range.location - 1] != '\n')
			text = [@"\n" stringByAppendingString:text];
		if(range.location < originalText.length && [originalText characterAtIndex:range.location] != '\n' && ![text hasSuffix:@"\n"])
			text = [text stringByAppendingString:@"\n"];
	}
	else
	{
		// Without a selection the code goes at the end of the document, on a line of its own
		range = textView.hasSelection ? textView.selectedRange : NSMakeRange(originalText.length, 0);
		if(NSMaxRange(range) > originalText.length)
			return nil;
		if(!textView.hasSelection && originalText.length && ![originalText hasSuffix:@"\n"])
			text = [@"\n" stringByAppendingString:text];
	}

	NSString* currentText = [originalText stringByReplacingCharactersInRange:range withString:text];
	std::string const after = to_s(currentText);
	auto const replacement = ChangedRange(to_s(originalText), after);
	if(replacement.first.first != replacement.first.second || !replacement.second.empty())
		[textView performReplacements:{ replacement }];
	[self.window makeFirstResponder:textView];

	size_t from = replacement.first.first, to = from + replacement.second.size();
	if(from != to)
		textView.selectionString = InsertedTextSelectionString(after, from, to);

	return @{ @"path": document.path ?: [NSNull null], @"originalText": originalText, @"currentText": currentText };
}

// Shows the agent’s edit in an open document right away and selects the
// changed text, so the user sees what was added and where
- (void)agentPanel:(AgentPanelViewController*)agentPanel didEditFileAtPath:(NSString*)path previousText:(NSString*)previousText
{
	OakDocument* document = [self openDocumentAtPath:path.stringByStandardizingPath];
	if(!document)
		return;
	[document importDocumentChanges:self];

	std::string const after = to_s(document.content ?: @"");
	auto const changed = ChangedRange(to_s(previousText ?: @""), after);
	size_t from = changed.first.first, to = from + changed.second.size();

	NSString* selection = InsertedTextSelectionString(after, from, to);
	if(document == self.selectedDocument)
			self.textView.selectionString = selection;
	else	document.selection = selection;
}

- (void)agentPanel:(AgentPanelViewController*)agentPanel showDiff:(NSString*)diff title:(NSString*)title
{
	OakDocument* document = [OakDocument documentWithString:diff fileType:@"source.diff" customName:title];
	[OakDocumentController.sharedInstance showDocument:document inProject:self.identifier bringToFront:YES];
}

- (id<AgentDocumentProvider>)documentProviderForAgentPanel:(AgentPanelViewController*)agentPanel
{
	return self;
}

// ==========================
// = AgentDocumentProvider =
// ==========================

// Open documents are shared by all windows, so any window’s are used
- (OakDocument*)openDocumentAtPath:(NSString*)path
{
	for(OakDocument* document in OakDocumentController.sharedInstance.openDocuments)
	{
		if(document.path && document.isLoaded && IsSameFile(document.path.stringByStandardizingPath, path))
			return document;
	}
	return nil;
}

- (NSString*)textOfOpenDocumentAtPath:(NSString*)path
{
	return [self openDocumentAtPath:path].content;
}

- (BOOL)replaceTextOfOpenDocumentAtPath:(NSString*)path withText:(NSString*)text
{
	OakDocument* document = [self openDocumentAtPath:path];
	if(!document)
		return NO;

	auto const range = ChangedRange(to_s(document.content ?: @""), to_s(text));
	if(range.first.first == range.first.second && range.second.empty())
		return YES;

	// Through the view showing it, if any, so the view redraws and resizes
	if(OakTextView* textView = self.textView; textView && textView.document == document)
		[textView performReplacements:{ range }];
	else	[document performReplacements:{ range } checksum:0];
	return YES;
}

- (void)agentPanel:(AgentPanelViewController*)agentPanel openFile:(NSString*)path line:(NSUInteger)line
{
	OakDocument* document = [OakDocumentController.sharedInstance documentWithPath:path];
	text::range_t selection = line ? text::range_t(text::pos_t(line - 1, 0)) : text::range_t::undefined;
	[OakDocumentController.sharedInstance showDocument:document andSelect:selection inProject:self.identifier bringToFront:YES];
}
@end
