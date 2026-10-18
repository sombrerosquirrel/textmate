// Context attached to a prompt (VS Code’s “Add Context”): files, a selection,
// or an image, converted to ACP content blocks according to what the agent
// supports (its promptCapabilities).

typedef NS_ENUM(NSInteger, AgentAttachmentKind) {
	AgentAttachmentKindFile = 0,
	AgentAttachmentKindSelection,
	AgentAttachmentKindImage,
};

@interface AgentAttachment : NSObject
// `text` is the file’s current contents when it’s open in TextMate (possibly
// unsaved); pass nil to read it from disk when the prompt is sent.
+ (instancetype)fileAttachmentWithPath:(NSString*)path text:(NSString*)text;
// Also tells the agent where the cursor is, so “here” has a meaning. Line and
// column are 1-based; the column counts characters.
+ (instancetype)fileAttachmentWithPath:(NSString*)path text:(NSString*)text cursorLine:(NSUInteger)line column:(NSUInteger)column;
// Lines are 1-based and inclusive. `path` may be nil for untitled documents.
+ (instancetype)selectionAttachmentWithPath:(NSString*)path displayName:(NSString*)displayName text:(NSString*)text firstLine:(NSUInteger)firstLine lastLine:(NSUInteger)lastLine;
+ (instancetype)imageAttachmentWithPNGData:(NSData*)data name:(NSString*)name;

@property (nonatomic, readonly) AgentAttachmentKind kind;
@property (nonatomic, readonly) NSString* name;  // shown on the chip
@property (nonatomic, readonly) NSString* path;
@property (nonatomic, readonly) NSUInteger cursorLine;   // 0 when unknown
@property (nonatomic, readonly) NSUInteger cursorColumn;

// nil if the agent can’t accept this attachment (e.g. an image without the image capability).
- (NSDictionary*)contentBlockWithPromptCapabilities:(NSDictionary*)promptCapabilities;
// The content block followed by a note of the cursor position, if any.
- (NSArray<NSDictionary*>*)contentBlocksWithPromptCapabilities:(NSDictionary*)promptCapabilities;

// The prompt text followed by the attachments’ content blocks.
+ (NSArray<NSDictionary*>*)promptWithText:(NSString*)text attachments:(NSArray<AgentAttachment*>*)attachments promptCapabilities:(NSDictionary*)promptCapabilities;
// Also names `currentFile`, the file open in the editor, and the cursor in it,
// as the file the user means unless they say otherwise. Its contents aren’t
// sent; the agent reads the file if it needs to.
+ (NSArray<NSDictionary*>*)promptWithText:(NSString*)text attachments:(NSArray<AgentAttachment*>*)attachments currentFile:(AgentAttachment*)currentFile promptCapabilities:(NSDictionary*)promptCapabilities;
@end
