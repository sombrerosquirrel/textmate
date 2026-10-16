// The slash command list shown above the chat input while the first word
// starts with “/”. It never takes focus: the prompt keeps the keyboard and
// moves the selection, so ↩ / ⇥ / ⎋ are all handled by the prompt.

// Commands ({ name, description, input }) whose name starts with `prefix`
// (“/” included, case-insensitive): an exact match first, then by name.
NSArray<NSDictionary*>* AgentSlashCommandsMatchingPrefix (NSArray<NSDictionary*>* commands, NSString* prefix);

@interface AgentCommandList : NSObject
@property (nonatomic, readonly, getter = isVisible) BOOL visible;
@property (nonatomic, readonly) NSDictionary* selectedCommand;
@property (nonatomic, copy) void(^clickHandler)(NSDictionary* command);

// Shows the commands above `view` (or updates the list if already shown),
// selecting the first.
- (void)showCommands:(NSArray<NSDictionary*>*)commands aboveView:(NSView*)view;
- (void)moveSelection:(NSInteger)delta;
- (void)close;
@end
