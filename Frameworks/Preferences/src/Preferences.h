@protocol PreferencesPaneProtocol <NSObject>
@optional
@property (nonatomic, readonly) NSImage* toolbarItemImage;
@end

NSImage* PreferencesToolbarImage (NSString* symbolName, NSString* description, NSImage* fallbackImage);

@interface Preferences : NSWindowController
@property (class, readonly) Preferences* sharedInstance;
// Shows the window with the pane whose identifier (e.g. “Agents”) is given.
- (void)showWindowWithPaneIdentifier:(NSString*)identifier;
@end
