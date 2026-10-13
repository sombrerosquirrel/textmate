// Renders Markdown from agents into an attributed string for a TextKit 1 text
// view: headings, paragraphs, (nested) lists, code blocks, block quotes,
// tables, and inline emphasis, code, strikethrough and links.
//
// Foundation’s parser only labels block structure (NSPresentationIntent); this
// turns those labels into separators, indentation, fonts and text blocks.

@interface AgentMarkdownStyle : NSObject
@property (nonatomic) NSFont* font;
@property (nonatomic) NSFont* codeFont;
@property (nonatomic) NSColor* textColor;
@property (nonatomic) NSColor* secondaryTextColor;
@property (nonatomic) NSColor* codeBackgroundColor;
@property (nonatomic) NSColor* borderColor;
+ (instancetype)defaultStyle;
@end

@interface AgentMarkdownCodeBlock : NSObject
@property (nonatomic, readonly) NSString* code;
@property (nonatomic, readonly) NSString* language; // nil if the fence has no language
@end

// Marks every character of a rendered code block; value is the block’s index (NSNumber).
extern NSAttributedStringKey const AgentCodeBlockAttributeName;

@interface AgentMarkdownRenderer : NSObject
// `codeBlockFooter`, if given, is called after each code block and its result
// appended on the following line (e.g. Copy / Insert action links).
+ (NSAttributedString*)attributedStringFromMarkdown:(NSString*)markdown style:(AgentMarkdownStyle*)style codeBlocks:(NSArray<AgentMarkdownCodeBlock*>**)codeBlocks codeBlockFooter:(NSAttributedString*(^)(NSUInteger index))codeBlockFooter;
@end
