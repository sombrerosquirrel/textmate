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
// Lines are 1-based and inclusive. `path` may be nil for untitled documents.
+ (instancetype)selectionAttachmentWithPath:(NSString*)path displayName:(NSString*)displayName text:(NSString*)text firstLine:(NSUInteger)firstLine lastLine:(NSUInteger)lastLine;
+ (instancetype)imageAttachmentWithPNGData:(NSData*)data name:(NSString*)name;

@property (nonatomic, readonly) AgentAttachmentKind kind;
@property (nonatomic, readonly) NSString* name;  // shown on the chip
@property (nonatomic, readonly) NSString* path;

// nil if the agent can’t accept this attachment (e.g. an image without the image capability).
- (NSDictionary*)contentBlockWithPromptCapabilities:(NSDictionary*)promptCapabilities;

// The prompt text followed by the attachments’ content blocks.
+ (NSArray<NSDictionary*>*)promptWithText:(NSString*)text attachments:(NSArray<AgentAttachment*>*)attachments promptCapabilities:(NSDictionary*)promptCapabilities;
@end
