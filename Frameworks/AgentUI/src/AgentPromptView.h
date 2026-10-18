#import "AgentAttachment.h"

// The chat input: multi-line text, attachment chips, an Add Context button,
// and Send / Stop. ↩ sends, ⇧↩ or ⌥↩ inserts a newline, ⎋ stops, ↑ / ↓ recall
// previous prompts, and typing “/” lists the agent’s slash commands: ↩ sends
// the selected one, ⇥ completes it, ⎋ closes the list.
//
// A switch beside Add Context chooses whether text and code the user asks for
// go into the file open in the editor; while it’s on, a line above the input
// names the file.

@class AgentPromptView;

@protocol AgentPromptViewDelegate <NSObject>
- (void)promptViewDidSubmit:(AgentPromptView*)promptView;
- (void)promptViewDidRequestStop:(AgentPromptView*)promptView;
@optional
- (NSMenu*)addContextMenuForPromptView:(AgentPromptView*)promptView;
- (NSArray<NSDictionary*>*)slashCommandsForPromptView:(AgentPromptView*)promptView; // ACP availableCommands
- (BOOL)promptViewAcceptsImages:(AgentPromptView*)promptView;
- (void)promptViewDidToggleUsesCurrentFile:(AgentPromptView*)promptView;
@end

@interface AgentPromptView : NSView
@property (nonatomic, weak) id<AgentPromptViewDelegate> delegate;
@property (nonatomic) NSString* text;
@property (nonatomic, readonly) NSArray<AgentAttachment*>* attachments;
@property (nonatomic) NSString* placeholderString;
@property (nonatomic, getter = isWorking) BOOL working; // shows Stop instead of Send
@property (nonatomic, getter = isEnabled) BOOL enabled;
@property (nonatomic, readonly) NSView* initialFirstResponder;
@property (nonatomic) BOOL usesCurrentFile;          // the switch
@property (nonatomic) NSString* currentFileName;     // nil when no saved file is open

- (void)addAttachment:(AgentAttachment*)attachment;
- (void)removeAllAttachments;
- (void)rememberPrompt:(NSString*)text; // for ↑ / ↓ history
@end
