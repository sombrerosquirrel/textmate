// Runs cmark-gfm, GitHub’s Markdown parser, for the GitHub renderer. It’s an
// external binary (e.g. from Homebrew), so TextMate doesn’t bundle a parser.

@interface MarkdownPreviewCmark : NSObject
// Extensions GitHub uses, plus source positions for scroll sync. Raw HTML is
// passed through; unless `allowRawHTML` is set, tagfilter turns <script> and
// the like into text, and the output must go through
// MarkdownPreviewSanitizedHTML() to keep only GitHub’s safe tags.
+ (NSArray<NSString*>*)argumentsAllowingRawHTML:(BOOL)allowRawHTML;

// The binary set with Locate… if it’s still there, else cmark-gfm on the
// login shell’s PATH or in Homebrew’s usual folders. Completion runs on the
// main queue, with the environment to run it in; `path` is nil if not found.
+ (void)locateWithCompletion:(void(^)(NSString* path, NSDictionary<NSString*, NSString*>* environment))completion;

// Searches `environment`’s PATH and Homebrew’s folders.
+ (NSString*)executablePathInEnvironment:(NSDictionary<NSString*, NSString*>*)environment;

// Feeds `markdown` to the command and returns its output (HTML). Blocks, so
// call it off the main thread. Returns nil and sets `error` if the command
// can’t run, exits with an error or takes longer than a few seconds.
+ (NSString*)HTMLFromMarkdown:(NSString*)markdown executable:(NSString*)path arguments:(NSArray<NSString*>*)arguments environment:(NSDictionary<NSString*, NSString*>*)environment error:(NSString**)error;
@end
