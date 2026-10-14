id TMMakeAttributedStringWithBackgroundStyle (id objectValue, NSBackgroundStyle backgroundStyle);

@interface NSColor (TMColorAdditions)
+ (NSColor*)tmMatchedTextBackgroundColor;
+ (NSColor*)tmMatchedTextUnderlineColor;
+ (NSColor*)tmMatchedTextSelectedBackgroundColor;
+ (NSColor*)tmMatchedTextSelectedUnderlineColor;
+ (NSColor*)tmSidebarBackgroundColor; // file browser and editor side panels
@end
