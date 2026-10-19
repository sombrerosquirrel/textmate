// Window ▸ Agent Log: shows AgentLog.sharedLog, filtered by agent, kind and
// search text.

@interface AgentLogWindowController : NSWindowController
@property (class, readonly) AgentLogWindowController* sharedInstance;
// Shows the window with only `source`’s entries (nil for all).
- (void)showWindowForSource:(NSString*)source;
@end
