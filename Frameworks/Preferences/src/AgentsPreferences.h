#import "Preferences.h"

// Preferences ▸ Agents: the agents the agent panel can start (command,
// environment, API key in the Keychain) and the MCP servers passed to them.

@interface AgentsPreferences : NSViewController <PreferencesPaneProtocol>
@property (nonatomic, readonly) NSImage* toolbarItemImage;
@end
