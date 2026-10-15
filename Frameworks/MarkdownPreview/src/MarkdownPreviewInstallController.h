// A sheet offering to install cmark-gfm, which the GitHub renderer needs:
// with Homebrew if it’s there (showing its output), or by locating a binary.

@interface MarkdownPreviewInstallController : NSWindowController
// `environment` is used to find and run Homebrew. The completion handler gets
// cmark-gfm’s path, or nil if the user cancelled. A located binary is also
// saved in the user defaults.
- (void)beginSheetModalForWindow:(NSWindow*)window environment:(NSDictionary<NSString*, NSString*>*)environment completionHandler:(void(^)(NSString* cmarkPath))completion;
@end
