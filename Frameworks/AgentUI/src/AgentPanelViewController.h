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
- (void)agentPanel:(AgentPanelViewController*)agentPanel openFile:(NSString*)path line:(NSUInteger)line;
// Open documents, for the agent’s file access (unsaved edits, undoable writes).
- (id<AgentDocumentProvider>)documentProviderForAgentPanel:(AgentPanelViewController*)agentPanel;
@end

extern NSString* const kUserDefaultsAgentPanelAgentKey; // identifier of the last used agent

@interface AgentPanelViewController : NSViewController
@property (nonatomic, weak) id<AgentPanelDelegate> delegate;

- (void)startSessionIfNeeded;
- (void)focusPrompt;
// Attaches the editor selection (or the current file) and focuses the prompt.
- (void)askAboutSelection;
- (IBAction)newChat:(id)sender;
// Terminates the agent; call when the window closes.
- (void)shutdown;
@end
