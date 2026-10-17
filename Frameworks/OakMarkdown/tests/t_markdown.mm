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

static std::string SourceLines (NSAttributedString* str)
{
	__block std::string res;
	[str enumerateAttribute:OakMarkdownSourceLineAttributeName inRange:NSMakeRange(0, str.length) options:0 usingBlock:^(NSNumber* line, NSRange range, BOOL* stop){
		if(line)
			res += std::to_string(line.intValue) + ":" + S([str.string substringWithRange:NSMakeRange(range.location, 1)]) + " ";
	}];
	return res;
}

void test_source_lines ()
{
	NSString* markdown = @"# Title\n\nSome *text* and a [link](x) on\nthree lines\nhere.\n\n- [ ] task\n- [x] done\n\n```\ncode\n```\n\n> quote\n";

	OakMarkdownStyle* style = [OakMarkdownStyle defaultStyle];
	style.marksSourceLines = YES;
	NSAttributedString* marked = [OakMarkdownRenderer attributedStringFromMarkdown:markdown style:style baseURL:nil codeBlocks:nullptr codeBlockFooter:nil];

	// The same text as without source lines, e.g. task markers still recognized
	OAK_ASSERT_EQ(String(marked), String(Render(markdown)));
	OAK_ASSERT_EQ(SourceLines(marked), "1:T 3:S 4:t 5:h 7:t 8:d 10:c 14:q ");

	// Off by default
	OAK_ASSERT_EQ(SourceLines(Render(markdown)), "");
}

static NSString* AnchorAt (NSAttributedString* str, NSUInteger index)
{
	return index < str.length ? [str attribute:OakMarkdownAnchorAttributeName atIndex:index effectiveRange:nullptr] : nil;
}

void test_footnotes ()
{
	NSURL* document = [NSURL fileURLWithPath:@"/tmp/project/README.md"];
	NSAttributedString* str = RenderDocument(@"A note[^n] and another[^2] and again[^N].\n\n[^2]: Second.\n[^n]: First\n    with more.\n", document);
	OAK_ASSERT_EQ(String(str), "A note1 and another2 and again1.\n \n1.\tFirst with more. ↩\n2.\tSecond. ↩");

	// References: superscript links to the note; the first one is the target of the note’s ↩
	NSUInteger first = [str.string rangeOfString:@"note1"].location + 4;
	NSUInteger again = [str.string rangeOfString:@"again1"].location + 5;
	OAK_ASSERT_EQ(S([[str attribute:NSLinkAttributeName atIndex:first effectiveRange:nullptr] absoluteString]), "file:///tmp/project/README.md#fn-1");
	OAK_ASSERT([[str attribute:NSBaselineOffsetAttributeName atIndex:first effectiveRange:nullptr] doubleValue] > 0);
	OAK_ASSERT_EQ(S(AnchorAt(str, first)), "fnref-1");
	OAK_ASSERT(AnchorAt(str, again) == nil);

	// Notes: anchored at their start, ↩ links back
	OAK_ASSERT_EQ(S(AnchorAt(str, [str.string rangeOfString:@"First"].location)), "fn-1");
	OAK_ASSERT_EQ(S(AnchorAt(str, [str.string rangeOfString:@"Second"].location)), "fn-2");
	NSUInteger back = [str.string rangeOfString:@"↩"].location;
	OAK_ASSERT_EQ(S([[str attribute:NSLinkAttributeName atIndex:back effectiveRange:nullptr] absoluteString]), "file:///tmp/project/README.md#fnref-1");
}

void test_footnotes_left_alone ()
{
	// Undefined, in code, or escaped
	OAK_ASSERT_EQ(String(Render(@"No note[^x] here.")), "No note[^x] here.");
	OAK_ASSERT_EQ(String(Render(@"Code `[^1]` and \\[^1].\n\n```\n[^1]: not a note\n```\n\n[^1]: Note.")), "Code [^1] and [^1].\n[^1]: not a note");

	// Unreferenced notes are left out
	OAK_ASSERT_EQ(String(Render(@"Text.\n\n[^1]: Unused.")), "Text.");
}

void test_footnote_source_lines ()
{
	// Definitions are taken out without changing the lines of what follows
	OakMarkdownStyle* style = [OakMarkdownStyle defaultStyle];
	style.marksSourceLines = YES;
	NSAttributedString* str = [OakMarkdownRenderer attributedStringFromMarkdown:@"One[^1]\n\n[^1]: Note\n    more\n\nTwo\n" style:style baseURL:nil codeBlocks:nullptr codeBlockFooter:nil];
	OAK_ASSERT_EQ(SourceLines(str), "1:O 6:T ");
}

// ========
// = HTML =
// ========

static id AttributeAt (NSAttributedString* str, NSString* text, NSAttributedStringKey key)
{
	NSRange range = [str.string rangeOfString:text];
	return range.location == NSNotFound ? nil : [str attribute:key atIndex:range.location effectiveRange:nullptr];
}

static NSAttributedString* RenderDetails (NSString* markdown, NSSet<NSNumber*>* toggledDetails)
{
	OakMarkdownStyle* style = [OakMarkdownStyle defaultStyle];
	style.toggledDetails = toggledDetails;
	return [OakMarkdownRenderer attributedStringFromMarkdown:markdown style:style baseURL:nil codeBlocks:nullptr codeBlockFooter:nil];
}

void test_html_inline_tags ()
{
	NSAttributedString* str = Render(@"a <b>bold</b> <i>it</i> <kbd>K</kbd> H<sub>2</sub>O x<sup>3</sup> <mark>m</mark> <u>u</u> <s>s</s> <b><i>both</i></b>");
	OAK_ASSERT_EQ(String(str), "a bold it K H2O x3 m u s both");
	OAK_ASSERT(IsBold(FontAt(str, @"bold")));
	OAK_ASSERT(IsItalic(FontAt(str, @"it")));
	OAK_ASSERT(IsMonospace(FontAt(str, @"K")));
	OAK_ASSERT([AttributeAt(str, @"K", NSBackgroundColorAttributeName) isEqual:[OakMarkdownStyle defaultStyle].codeBackgroundColor]);
	OAK_ASSERT([AttributeAt(str, @"2", NSBaselineOffsetAttributeName) doubleValue] < 0);
	OAK_ASSERT([AttributeAt(str, @"3", NSBaselineOffsetAttributeName) doubleValue] > 0);
	OAK_ASSERT(FontAt(str, @"3").pointSize < FontAt(str, @"x").pointSize);
	OAK_ASSERT(AttributeAt(str, @"m", NSBackgroundColorAttributeName) != nil);
	OAK_ASSERT([AttributeAt(str, @"u ", NSUnderlineStyleAttributeName) integerValue] != 0);
	OAK_ASSERT([AttributeAt(str, @"s ", NSStrikethroughStyleAttributeName) integerValue] != 0);
	OAK_ASSERT(IsBold(FontAt(str, @"both")) && IsItalic(FontAt(str, @"both")));

	// Styles end with the tag, or at the end of the paragraph
	OAK_ASSERT(!IsBold(FontAt(str, @"a ")));
	NSAttributedString* unclosed = Render(@"<b>open\n\nnext");
	OAK_ASSERT(IsBold(FontAt(unclosed, @"open")));
	OAK_ASSERT(!IsBold(FontAt(unclosed, @"next")));
}

void test_html_line_break ()
{
	OAK_ASSERT_EQ(String(Render(@"one<br>two<br/>three")), "one two three");
}

void test_html_unknown_and_literal_tags ()
{
	OAK_ASSERT_EQ(String(Render(@"<span>a</span> <foo bar=\"1\">b</foo> <!-- note -->c")), "a b c");
	OAK_ASSERT_EQ(String(Render(@"x <script>alert(1)</script> y")), "x <script>alert(1)</script> y");
	OAK_ASSERT_EQ(String(Render(@"a < b > c")), "a < b > c");

	// In code, tags are text
	NSAttributedString* code = Render(@"`<b>x</b>`");
	OAK_ASSERT_EQ(String(code), "<b>x</b>");
	OAK_ASSERT(IsMonospace(FontAt(code, @"x")));
}

void test_html_links ()
{
	NSAttributedString* str = RenderDocument(@"<a href=\"https://example.com\">web</a> <a href=\"javascript:alert(1)\">js</a> <a href=\"other.md\">rel</a>", [NSURL fileURLWithPath:@"/docs/README.md"]);
	OAK_ASSERT_EQ(String(str), "web js rel");
	OAK_ASSERT_EQ(S([AttributeAt(str, @"web", NSLinkAttributeName) absoluteString]), "https://example.com");
	OAK_ASSERT(AttributeAt(str, @"js", NSLinkAttributeName) == nil);
	OAK_ASSERT_EQ(S([AttributeAt(str, @"rel", NSLinkAttributeName) absoluteString]), "file:///docs/other.md");
}

void test_html_blocks ()
{
	NSAttributedString* str = Render(@"<div align=\"center\">\n<b>Title</b> &amp; <i>more</i>\n</div>\n\nAfter");
	OAK_ASSERT_EQ(String(str), "Title & more\nAfter");
	OAK_ASSERT(IsBold(FontAt(str, @"Title")));
	OAK_ASSERT(ParagraphStyleAt(str, @"Title").alignment == NSTextAlignmentCenter);
	OAK_ASSERT(ParagraphStyleAt(str, @"After").alignment == NSTextAlignmentNatural);

	// Markdown inside an HTML block
	NSAttributedString* wrapped = Render(@"<p align=\"right\">\n\n**x**\n\n</p>\n\ny");
	OAK_ASSERT_EQ(String(wrapped), "x\ny");
	OAK_ASSERT(ParagraphStyleAt(wrapped, @"x").alignment == NSTextAlignmentRight);
	OAK_ASSERT(ParagraphStyleAt(wrapped, @"y").alignment == NSTextAlignmentNatural);

	NSAttributedString* heading = Render(@"<h1 align=\"center\">Name</h1>\n<p>Text &lt;tag&gt; &#x263A;</p>");
	OAK_ASSERT_EQ(String(heading), "Name\nText <tag> ☺");
	OAK_ASSERT(FontAt(heading, @"Name").pointSize > FontAt(heading, @"Text").pointSize);

	OAK_ASSERT_EQ(String(Render(@"<ul>\n<li>One</li>\n<li>Two</li>\n</ul>\n\n<ol start=\"3\">\n<li>Three</li>\n</ol>")), "•\tOne\n•\tTwo\n3.\tThree");
	OAK_ASSERT_EQ(String(Render(@"<pre>\nline 1\n  line 2</pre>")), "line 1   line 2");
}

void test_html_image ()
{
	NSURL* folder = MakeImageFolder();
	NSURL* document = [folder URLByAppendingPathComponent:@"README.md"];

	NSTextAttachment* attachment = FirstAttachment(RenderDocument(@"<p align=\"center\">\n  <img src=\"pic.png\" width=\"100\" alt=\"Logo\">\n</p>", document));
	OAK_ASSERT(attachment != nil);
	OAK_ASSERT_EQ(NSWidth(attachment.bounds), 100);
	OAK_ASSERT_EQ(NSHeight(attachment.bounds), 50);

	OAK_ASSERT(FirstAttachment(RenderDocument(@"Inline <img src=\"pic.png\"> image", document)) != nil);
	OAK_ASSERT(FirstAttachment(RenderDocument(@"<img src=\"javascript:x\">", document)) == nil);

	[NSFileManager.defaultManager removeItemAtURL:folder error:nil];
}

void test_html_details ()
{
	NSString* markdown = @"<details>\n<summary>More</summary>\n\nHidden *text*\n\n</details>\n\nEnd";

	// Without toggling (agent chat): open, summary isn’t a link
	NSAttributedString* open = RenderDetails(markdown, nil);
	OAK_ASSERT_EQ(String(open), "▾ More\nHidden text\nEnd");
	OAK_ASSERT(AttributeAt(open, @"More", NSLinkAttributeName) == nil);

	// Closed by default, the summary toggles it
	NSAttributedString* closed = RenderDetails(markdown, [NSSet set]);
	OAK_ASSERT_EQ(String(closed), "▸ More\nEnd");
	OAK_ASSERT([AttributeAt(closed, @"More", NSLinkAttributeName) isEqual:OakMarkdownDetailsURL(0)]);
	OAK_ASSERT([AttributeAt(closed, @"▸", NSLinkAttributeName) isEqual:OakMarkdownDetailsURL(0)]);

	OAK_ASSERT_EQ(String(RenderDetails(markdown, [NSSet setWithObject:@0])), "▾ More\nHidden text\nEnd");

	// `open`, and the second one toggled
	NSString* two = @"<details open><summary>A</summary>\n\na\n\n</details>\n\n<details><summary>B</summary>\n\nb\n\n</details>";
	OAK_ASSERT_EQ(String(RenderDetails(two, [NSSet set])), "▾ A\na\n▸ B");
	OAK_ASSERT_EQ(String(RenderDetails(two, [NSSet setWithObjects:@0, @1, nil])), "▸ A\n▾ B\nb");

	// Without a summary, and nested in a closed one
	OAK_ASSERT_EQ(String(RenderDetails(@"<details>\n\nx\n\n</details>", [NSSet set])), "▸ Details");
	OAK_ASSERT_EQ(String(RenderDetails(@"<details><summary>Outer</summary>\n<details><summary>Inner</summary>\n\nx\n\n</details>\n</details>\n\nEnd", [NSSet set])), "▸ Outer\nEnd");

	OAK_ASSERT_EQ(OakMarkdownDetailsIndexForURL(OakMarkdownDetailsURL(12)), 12);
	OAK_ASSERT_EQ(OakMarkdownDetailsIndexForURL([NSURL URLWithString:@"https://example.com"]), -1);
}
