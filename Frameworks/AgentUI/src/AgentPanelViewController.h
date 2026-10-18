#import "AgentAttachment.h"
#import <AgentClient/AgentFileSystem.h>

// The agent chat panel for one project window: agent picker, transcript,
// prompt with context attachments, and the agent’s own controls (mode, model,
// effort, …) below the prompt, as in VS Code’s chat view.

@class AgentPanelViewController;

@protocol AgentPanelDelegate <NSObject>
- (NSString*)projectPathForAgentPanel:(AgentPanelViewController*)agentPanel;
@optional
- (AgentAttachment*)currentFileAttachmentForAgentPanel:(AgentPanelViewController*)agentPanel;
- (AgentAttachment*)selectionAttachmentForAgentPanel:(AgentPanelViewController*)agentPanel; // nil without a selection
- (NSArray<AgentAttachment*>*)openFileAttachmentsForAgentPanel:(AgentPanelViewController*)agentPanel;
- (void)agentPanel:(AgentPanelViewController*)agentPanel insertText:(NSString*)text;
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
// Open documents, for the agent’s file access (unsaved edits, undoable writes).
- (id<AgentDocumentProvider>)documentProviderForAgentPanel:(AgentPanelViewController*)agentPanel;
@end

extern NSString* const kUserDefaultsAgentPanelAgentKey;           // identifier of the last used agent
extern NSString* const kUserDefaultsAgentPanelUsesCurrentFileKey; // requests go into the open file (default YES)

@interface AgentPanelViewController : NSViewController
@property (nonatomic, weak) id<AgentPanelDelegate> delegate;

- (void)startSessionIfNeeded;
- (void)focusPrompt;
// The editor switched files (or saved one); updates the prompt’s current-file line.
- (void)currentFileDidChange;
// Attaches the editor selection (or the current file) and focuses the prompt.
- (void)askAboutSelection;
- (IBAction)newChat:(id)sender;
// Terminates the agent; call when the window closes.
- (void)shutdown;
@end
