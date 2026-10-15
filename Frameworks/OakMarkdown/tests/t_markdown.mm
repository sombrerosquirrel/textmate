#import <OakMarkdown/OakMarkdown.h>

static NSAttributedString* Render (NSString* markdown, NSArray<OakMarkdownCodeBlock*>** codeBlocks = nullptr, NSAttributedString*(^footer)(NSUInteger) = nil)
{
	return [OakMarkdownRenderer attributedStringFromMarkdown:markdown style:[OakMarkdownStyle defaultStyle] codeBlocks:codeBlocks codeBlockFooter:footer];
}

static std::string S (NSString* str)
{
	return str ? std::string(str.UTF8String) : "«nil»";
}

static std::string String (NSAttributedString* str)
{
	return S(str.string);
}

static NSFont* FontAt (NSAttributedString* str, NSString* text)
{
	NSRange range = [str.string rangeOfString:text];
	return range.location == NSNotFound ? nil : [str attribute:NSFontAttributeName atIndex:range.location effectiveRange:nullptr];
}

static NSParagraphStyle* ParagraphStyleAt (NSAttributedString* str, NSString* text)
{
	NSRange range = [str.string rangeOfString:text];
	return range.location == NSNotFound ? nil : [str attribute:NSParagraphStyleAttributeName atIndex:range.location effectiveRange:nullptr];
}

static bool IsBold (NSFont* font)      { return ([NSFontManager.sharedFontManager traitsOfFont:font] & NSBoldFontMask) != 0; }
static bool IsItalic (NSFont* font)    { return ([NSFontManager.sharedFontManager traitsOfFont:font] & NSItalicFontMask) != 0; }
static bool IsMonospace (NSFont* font) { return font.fixedPitch; }

void test_paragraphs ()
{
	OAK_ASSERT_EQ(String(Render(@"One\n\nTwo")), "One\nTwo");
	OAK_ASSERT_EQ(String(Render(@"Plain text")), "Plain text");
	OAK_ASSERT_EQ(String(Render(@"")), "");
}

void test_heading ()
{
	NSAttributedString* str = Render(@"# Title\n\nBody");
	OAK_ASSERT_EQ(String(str), "Title\nBody");
	OAK_ASSERT_GT(FontAt(str, @"Title").pointSize, FontAt(str, @"Body").pointSize);
	OAK_ASSERT(IsBold(FontAt(str, @"Title")));
	OAK_ASSERT(!IsBold(FontAt(str, @"Body")));
}

void test_lists ()
{
	OAK_ASSERT_EQ(String(Render(@"- a\n- b")), "•\ta\n•\tb");
	OAK_ASSERT_EQ(String(Render(@"1. x\n2. y")), "1.\tx\n2.\ty");

	NSAttributedString* nested = Render(@"- a\n  - b");
	OAK_ASSERT_EQ(String(nested), "•\ta\n•\tb");
	OAK_ASSERT_GT(ParagraphStyleAt(nested, @"b").headIndent, ParagraphStyleAt(nested, @"a").headIndent);
}

void test_code_block ()
{
	NSArray<OakMarkdownCodeBlock*>* codeBlocks;
	NSAttributedString* str = Render(@"Text\n\n```swift\nlet x = 1\nprint(x)\n```\n\nAfter", &codeBlocks);

	OAK_ASSERT_EQ(String(str), "Text\nlet x = 1\nprint(x)\nAfter");
	OAK_ASSERT_EQ(codeBlocks.count, 1);
	OAK_ASSERT_EQ(S(codeBlocks[0].code), "let x = 1\nprint(x)");
	OAK_ASSERT_EQ(S(codeBlocks[0].language), "swift");

	NSUInteger index = [str.string rangeOfString:@"print"].location;
	OAK_ASSERT([[str attribute:OakMarkdownCodeBlockAttributeName atIndex:index effectiveRange:nullptr] isEqual:@0]);
	OAK_ASSERT(IsMonospace(FontAt(str, @"print")));
	OAK_ASSERT_EQ(ParagraphStyleAt(str, @"print").textBlocks.count, 1);
	OAK_ASSERT(ParagraphStyleAt(str, @"let").textBlocks.firstObject == ParagraphStyleAt(str, @"print").textBlocks.firstObject);
	OAK_ASSERT([str attribute:OakMarkdownCodeBlockAttributeName atIndex:[str.string rangeOfString:@"After"].location effectiveRange:nullptr] == nil);
}

void test_code_block_footer ()
{
	NSArray<OakMarkdownCodeBlock*>* codeBlocks;
	NSAttributedString* str = Render(@"```\none\n```\n\n```\ntwo\n```\n\nEnd", &codeBlocks, ^NSAttributedString*(NSUInteger index){
		return [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"Copy %lu", index]];
	});
	OAK_ASSERT_EQ(String(str), "one\nCopy 0\ntwo\nCopy 1\nEnd");
	OAK_ASSERT_EQ(codeBlocks.count, 2);
	OAK_ASSERT(codeBlocks[0].language == nil);
	OAK_ASSERT_EQ(ParagraphStyleAt(str, @"Copy 0").textBlocks.count, 0);
}

void test_unterminated_code_fence ()
{
	// While streaming, the closing fence hasn’t arrived yet
	NSArray<OakMarkdownCodeBlock*>* codeBlocks;
	NSAttributedString* str = Render(@"Here:\n\n```py\nprint(1)", &codeBlocks);
	OAK_ASSERT_EQ(String(str), "Here:\nprint(1)");
	OAK_ASSERT_EQ(codeBlocks.count, 1);
	OAK_ASSERT_EQ(S(codeBlocks[0].code), "print(1)");
}

void test_inline_styles ()
{
	NSAttributedString* str = Render(@"a **bold** *italic* `code` ~~gone~~ [link](https://example.com)");
	OAK_ASSERT_EQ(String(str), "a bold italic code gone link");
	OAK_ASSERT(IsBold(FontAt(str, @"bold")));
	OAK_ASSERT(IsItalic(FontAt(str, @"italic")));
	OAK_ASSERT(IsMonospace(FontAt(str, @"code")));
	OAK_ASSERT(!IsMonospace(FontAt(str, @"a ")));

	NSUInteger gone = [str.string rangeOfString:@"gone"].location;
	OAK_ASSERT([[str attribute:NSStrikethroughStyleAttributeName atIndex:gone effectiveRange:nullptr] integerValue] != 0);

	NSUInteger link = [str.string rangeOfString:@"link"].location;
	id url = [str attribute:NSLinkAttributeName atIndex:link effectiveRange:nullptr];
	OAK_ASSERT([[url description] isEqualToString:@"https://example.com"]);
}

void test_table ()
{
	NSAttributedString* str = Render(@"| A | B |\n|---|---|\n| 1 | 2 |");
	OAK_ASSERT_EQ(String(str), "A\nB\n1\n2");

	NSTextTableBlock* header = ParagraphStyleAt(str, @"A").textBlocks.firstObject;
	NSTextTableBlock* cell   = ParagraphStyleAt(str, @"2").textBlocks.firstObject;
	OAK_ASSERT([header isKindOfClass:[NSTextTableBlock class]]);
	OAK_ASSERT([cell isKindOfClass:[NSTextTableBlock class]]);
	OAK_ASSERT(header.table == cell.table);
	OAK_ASSERT_EQ(header.table.numberOfColumns, 2);
	OAK_ASSERT_EQ(header.startingRow, 0);
	OAK_ASSERT_EQ(cell.startingRow, 1);
	OAK_ASSERT_EQ(cell.startingColumn, 1);
	OAK_ASSERT(IsBold(FontAt(str, @"A")));
	OAK_ASSERT(!IsBold(FontAt(str, @"1")));
}

void test_block_quote ()
{
	NSAttributedString* str = Render(@"> quoted\n\nnormal");
	OAK_ASSERT_EQ(String(str), "quoted\nnormal");
	OAK_ASSERT_EQ(ParagraphStyleAt(str, @"quoted").textBlocks.count, 1);
	OAK_ASSERT_EQ(ParagraphStyleAt(str, @"normal").textBlocks.count, 0);
}

// =====================
// = Document Preview =
// =====================

static NSAttributedString* RenderDocument (NSString* markdown, NSURL* baseURL, CGFloat maximumImageWidth = 0)
{
	OakMarkdownStyle* style = [OakMarkdownStyle defaultStyle];
	style.maximumImageWidth = maximumImageWidth;
	return [OakMarkdownRenderer attributedStringFromMarkdown:markdown style:style baseURL:baseURL codeBlocks:nullptr codeBlockFooter:nil];
}

// A folder with a 200 × 100 PNG named pic.png
static NSURL* MakeImageFolder ()
{
	NSURL* folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"oak-markdown-%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
	[NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];

	NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:200 pixelsHigh:100 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
	[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{ }] writeToURL:[folder URLByAppendingPathComponent:@"pic.png"] atomically:YES];
	return folder;
}

static NSTextAttachment* FirstAttachment (NSAttributedString* str)
{
	__block NSTextAttachment* res = nil;
	[str enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, str.length) options:0 usingBlock:^(id value, NSRange, BOOL* stop){
		if((res = value))
			*stop = YES;
	}];
	return res;
}

void test_local_image ()
{
	NSURL* folder = MakeImageFolder();
	NSURL* document = [folder URLByAppendingPathComponent:@"README.md"];

	NSTextAttachment* attachment = FirstAttachment(RenderDocument(@"Look: ![a picture](pic.png)", document));
	OAK_ASSERT(attachment != nil);
	OAK_ASSERT_EQ(NSWidth(attachment.bounds), 200);
	OAK_ASSERT_EQ(NSHeight(attachment.bounds), 100);

	// Scaled down to fit, keeping the aspect ratio
	NSTextAttachment* scaled = FirstAttachment(RenderDocument(@"![a picture](pic.png)", document, 50));
	OAK_ASSERT_EQ(NSWidth(scaled.bounds), 50);
	OAK_ASSERT_EQ(NSHeight(scaled.bounds), 25);

	[NSFileManager.defaultManager removeItemAtURL:folder error:nil];
}

void test_missing_or_remote_image ()
{
	NSURL* document = [NSURL fileURLWithPath:@"/nonexistent/docs/README.md"];

	NSAttributedString* missing = RenderDocument(@"![diagram](img/d.png)", document);
	OAK_ASSERT(FirstAttachment(missing) == nil);
	OAK_ASSERT_EQ(String(missing), "[diagram]");
	OAK_ASSERT_EQ(S([[missing attribute:NSLinkAttributeName atIndex:1 effectiveRange:nullptr] absoluteString]), "file:///nonexistent/docs/img/d.png");

	// Never fetched
	NSAttributedString* remote = RenderDocument(@"![](https://example.com/logo.png)", document);
	OAK_ASSERT(FirstAttachment(remote) == nil);
	OAK_ASSERT_EQ(String(remote), "[logo.png]");
}

void test_relative_links ()
{
	NSAttributedString* str = RenderDocument(@"See [the guide](guide/intro.md#setup) or [the site](https://example.com).", [NSURL fileURLWithPath:@"/tmp/project/README.md"]);
	NSURL* relative = [str attribute:NSLinkAttributeName atIndex:[str.string rangeOfString:@"the guide"].location effectiveRange:nullptr];
	NSURL* remote   = [str attribute:NSLinkAttributeName atIndex:[str.string rangeOfString:@"the site"].location effectiveRange:nullptr];
	OAK_ASSERT_EQ(S(relative.absoluteString), "file:///tmp/project/guide/intro.md#setup");
	OAK_ASSERT_EQ(S(remote.absoluteString), "https://example.com");
}

void test_task_list ()
{
	NSAttributedString* str = Render(@"- [ ] write tests\n- [x] fix bug\n- plain item");
	OAK_ASSERT_EQ(String(str), "☐\twrite tests\n☑\tfix bug\n•\tplain item");

	// Only at the start of an item
	OAK_ASSERT_EQ(String(Render(@"- see [x] here")), "•\tsee [x] here");
}

void test_horizontal_rule ()
{
	NSAttributedString* str = Render(@"Above\n\n---\n\nBelow");
	OAK_ASSERT_EQ(String(str), "Above\n \nBelow");

	NSTextBlock* rule = ParagraphStyleAt(str, @" ").textBlocks.firstObject;
	OAK_ASSERT(rule != nil);
	OAK_ASSERT_EQ([rule widthForLayer:NSTextBlockBorder edge:NSMaxYEdge], 1);
}

void test_block_quote_width ()
{
	// Without a width, the quote collapsed to one character per line in a text view
	NSTextBlock* quote = ParagraphStyleAt(Render(@"> A quote"), @"A quote").textBlocks.firstObject;
	OAK_ASSERT_EQ([quote valueForDimension:NSTextBlockWidth], 100);
	OAK_ASSERT([quote valueTypeForDimension:NSTextBlockWidth] == NSTextBlockPercentageValueType);
}
