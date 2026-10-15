#import "DocumentWindowController.h"

// The agent chat panel in a project window: shown beside the editor (left or
// right), with the editor’s context (current file, selection, open files)
// available to attach to prompts.

extern NSString* const kUserDefaultsAgentPanelPlacementKey; // @"left" or @"right" (default)

@interface DocumentWindowController (Agent)
@property (nonatomic) BOOL agentPanelVisible;

- (void)updateAgentPanelPlacement;   // after user defaults change
- (void)shutdownAgentPanel;          // when the window closes
- (BOOL)isAgentPanelMenuItem:(NSMenuItem*)menuItem;
- (BOOL)validateAgentPanelMenuItem:(NSMenuItem*)menuItem;

- (IBAction)toggleAgentPanel:(id)sender;
- (IBAction)toggleAgentPanelPlacement:(id)sender;
- (IBAction)askAgentAboutSelection:(id)sender;
@end
