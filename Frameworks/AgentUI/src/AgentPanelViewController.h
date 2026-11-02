#import "AgentAttachment.h"
#import <AgentClient/AgentFileSystem.h>

// The agent chat panel for one project window: agent picker, transcript,
// prompt with context attachments, and the agent’s own controls (mode, model,
// effort, …) below the prompt, as in VS Code’s chat view.

@class AgentPanelViewController;
@protocol AgentCodeBlockView;

@protocol AgentPanelDelegate <NSObject>
- (NSString*)projectPathForAgentPanel:(AgentPanelViewController*)agentPanel;
@optional
// The project’s `.tm_properties` agent settings: { agentName, agentCommand }, either may be missing.
- (NSDictionary<NSString*, NSString*>*)agentSettingsForAgentPanel:(AgentPanelViewController*)agentPanel;
- (AgentAttachment*)currentFileAttachmentForAgentPanel:(AgentPanelViewController*)agentPanel;
- (AgentAttachment*)selectionAttachmentForAgentPanel:(AgentPanelViewController*)agentPanel; // nil without a selection
- (NSArray<AgentAttachment*>*)openFileAttachmentsForAgentPanel:(AgentPanelViewController*)agentPanel;
- (void)agentPanel:(AgentPanelViewController*)agentPanel insertText:(NSString*)text;
// Show the panel (e.g. Show in Chat from the inline prompt).
- (void)agentPanelShowChat:(AgentPanelViewController*)agentPanel;
// Replaces the editor’s selection, or adds to the end of the document without
// one, as one undoable edit, and selects the new text. Returns { path (if
// saved), originalText, currentText }, or nil.
- (NSDictionary*)agentPanel:(AgentPanelViewController*)agentPanel applyText:(NSString*)text;
- (void)agentPanel:(AgentPanelViewController*)agentPanel openFile:(NSString*)path line:(NSUInteger)line;
// Shows `diff` (unified diff text) in a new document.
- (void)agentPanel:(AgentPanelViewController*)agentPanel showDiff:(NSString*)diff title:(NSString*)title;
// The agent edited the file at `path` itself; `previousText` is the text
// before this edit (nil if the agent created the file).
- (void)agentPanel:(AgentPanelViewController*)agentPanel didEditFileAtPath:(NSString*)path previousText:(NSString*)previousText;
// Code blocks in replies look like the editor: { backgroundColor, textColor }
// of the window’s theme, and `code` highlighted by the grammar for the
// fence’s `language` (nil if there is none, or no grammar for it).
- (NSDictionary<NSString*, NSColor*>*)codeColorsForAgentPanel:(AgentPanelViewController*)agentPanel;
- (NSAttributedString*)agentPanel:(AgentPanelViewController*)agentPanel highlightCode:(NSString*)code language:(NSString*)language;
// Unfolded code blocks: a read-only editor view of `code` with the grammar
// for the fence’s `language` and the window’s theme and font. The name of
// that grammar (“Objective-C++” for “objc”), nil if there is none.
- (NSView<AgentCodeBlockView>*)agentPanel:(AgentPanelViewController*)agentPanel viewForCode:(NSString*)code language:(NSString*)language;
- (NSString*)agentPanel:(AgentPanelViewController*)agentPanel displayNameForLanguage:(NSString*)language;
// Paths of the window’s open documents (saved ones), to find where code blocks sit.
- (NSArray<NSString*>*)openFilePathsForAgentPanel:(AgentPanelViewController*)agentPanel;
// Open documents, for the agent’s file access (unsaved edits, undoable writes).
- (id<AgentDocumentProvider>)documentProviderForAgentPanel:(AgentPanelViewController*)agentPanel;
@end

extern NSString* const kUserDefaultsAgentPanelAgentKey;           // identifier of the last used agent
extern NSString* const kUserDefaultsAgentPanelUsesCurrentFileKey; // requests go into the open file (default YES)
extern NSString* const kUserDefaultsAgentPanelFoldsCodeBlocksKey; // code blocks start folded to their line (default NO)

@interface AgentPanelViewController : NSViewController
@property (nonatomic, weak) id<AgentPanelDelegate> delegate;

- (void)startSessionIfNeeded;
- (void)focusPrompt;
// The editor switched files (or saved one); updates the prompt’s current-file line.
- (void)currentFileDidChange;
// The window’s theme changed; re-renders code blocks.
- (void)themeDidChange;
// Attaches the editor selection (or the current file) and focuses the prompt.
- (void)askAboutSelection;
// Inline chat: a prompt in a popover at `rect` of `view` (the editor’s caret).
// The request goes into this chat, about the selection or the caret, and
// edits the open file; the popover shows progress and the outcome.
- (void)showInlinePromptRelativeToRect:(NSRect)rect ofView:(NSView*)view;
// Attaches files (e.g. selected in the file browser) and focuses the prompt.
- (void)addFilesAtPaths:(NSArray<NSString*>*)paths;
- (IBAction)newChat:(id)sender;
// Terminates the agent; call when the window closes.
- (void)shutdown;
@end
