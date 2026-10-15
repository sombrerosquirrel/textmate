// Renders Markdown into an attributed string for a TextKit 1 text view (agent
// chat, Markdown preview): headings, paragraphs, (nested) lists, code blocks,
// block quotes, tables, task lists, horizontal rules, local images, and inline
// emphasis, code, strikethrough and links.
//
// Foundation’s parser only labels block structure (NSPresentationIntent); this
// turns those labels into separators, indentation, fonts and text blocks.

@interface OakMarkdownStyle : NSObject
@property (nonatomic) NSFont* font;
@property (nonatomic) NSFont* codeFont;
@property (nonatomic) NSColor* textColor;
@property (nonatomic) NSColor* secondaryTextColor;
@property (nonatomic) NSColor* codeBackgroundColor;
@property (nonatomic) NSColor* borderColor;
@property (nonatomic) CGFloat maximumImageWidth; // local images are scaled down to fit; 0 for no limit
+ (instancetype)defaultStyle;
@end

@interface OakMarkdownCodeBlock : NSObject
@property (nonatomic, readonly) NSString* code;
@property (nonatomic, readonly) NSString* language; // nil if the fence has no language
@end

// Marks every character of a rendered code block; value is the block’s index (NSNumber).
extern NSAttributedStringKey const OakMarkdownCodeBlockAttributeName;

@interface OakMarkdownRenderer : NSObject
// `codeBlockFooter`, if given, is called after each code block and its result
// appended on the following line (e.g. Copy / Insert action links).
+ (NSAttributedString*)attributedStringFromMarkdown:(NSString*)markdown style:(OakMarkdownStyle*)style codeBlocks:(NSArray<OakMarkdownCodeBlock*>**)codeBlocks codeBlockFooter:(NSAttributedString*(^)(NSUInteger index))codeBlockFooter;

// `baseURL` (e.g. the document’s file URL) resolves relative links and images.
// Images are only loaded from local files; others show their alt text as a link.
+ (NSAttributedString*)attributedStringFromMarkdown:(NSString*)markdown style:(OakMarkdownStyle*)style baseURL:(NSURL*)baseURL codeBlocks:(NSArray<OakMarkdownCodeBlock*>**)codeBlocks codeBlockFooter:(NSAttributedString*(^)(NSUInteger index))codeBlockFooter;
@end
