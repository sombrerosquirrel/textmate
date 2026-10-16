#import <MarkdownPreview/MarkdownPreviewSanitizer.h>

static BOOL Sanitizes (NSString* html, NSString* expected)
{
	NSString* res = MarkdownPreviewSanitizedHTML(html);
	if(![res isEqualToString:expected])
		NSLog(@"%@ → %@, expected %@", html, res, expected);
	return [res isEqualToString:expected];
}

void test_keeps_allowed_tags ()
{
	OAK_ASSERT(Sanitizes(@"<p data-sourcepos=\"1:1-1:15\">a <b>bold</b> <kbd>⌘K</kbd></p>", @"<p data-sourcepos=\"1:1-1:15\">a <b>bold</b> <kbd>⌘K</kbd></p>"));
	OAK_ASSERT(Sanitizes(@"<details open><summary>More</summary>text</details>", @"<details open><summary>More</summary>text</details>"));
	OAK_ASSERT(Sanitizes(@"a<br />b<hr>", @"a<br />b<hr>"));
	OAK_ASSERT(Sanitizes(@"<B CLASS='x'>y</B>", @"<b class=\"x\">y</b>"));
}

void test_removes_other_tags ()
{
	OAK_ASSERT(Sanitizes(@"<form action=\"x\"><button>Go</button></form>", @"Go"));
	OAK_ASSERT(Sanitizes(@"<svg><circle/></svg>text", @"text"));
	OAK_ASSERT(Sanitizes(@"a <!-- note --> b", @"a  b"));
	OAK_ASSERT(Sanitizes(@"<br></br>", @"<br>"));
}

void test_removes_unsafe_attributes ()
{
	OAK_ASSERT(Sanitizes(@"<b onclick=\"alert(1)\" style=\"color: red\">x</b>", @"<b>x</b>"));
	OAK_ASSERT(Sanitizes(@"<img src=\"a.png\" onerror=alert(1) alt=\"A\">", @"<img src=\"a.png\" alt=\"A\">"));
	OAK_ASSERT(Sanitizes(@"<a href='say \"hi\"'>x</a>", @"<a href=\"say &quot;hi&quot;\">x</a>"));
}

void test_checks_urls ()
{
	OAK_ASSERT(Sanitizes(@"<a href=\"https://example.com/a:b\">x</a>", @"<a href=\"https://example.com/a:b\">x</a>"));
	OAK_ASSERT(Sanitizes(@"<a href=\"docs/a:b.md\">x</a>", @"<a href=\"docs/a:b.md\">x</a>"));
	OAK_ASSERT(Sanitizes(@"<a href=\"#fn-1\">x</a>", @"<a href=\"#fn-1\">x</a>"));
	OAK_ASSERT(Sanitizes(@"<a href=\"mailto:me@example.com\">x</a>", @"<a href=\"mailto:me@example.com\">x</a>"));
	OAK_ASSERT(Sanitizes(@"<a href=\"javascript:alert(1)\">x</a>", @"<a>x</a>"));
	OAK_ASSERT(Sanitizes(@"<a href=\" JavaScript:alert(1)\">x</a>", @"<a>x</a>"));
	OAK_ASSERT(Sanitizes(@"<a href=\"java&#x09;script&#58;alert(1)\">x</a>", @"<a>x</a>"));
	OAK_ASSERT(Sanitizes(@"<a href=\"javascript&colon;alert(1)\">x</a>", @"<a>x</a>"));
	OAK_ASSERT(Sanitizes(@"<a href=\"file:///etc/passwd\">x</a>", @"<a>x</a>"));
	OAK_ASSERT(Sanitizes(@"<img src=\"data:image/png;base64,AA==\">", @"<img src=\"data:image/png;base64,AA==\">"));
	OAK_ASSERT(Sanitizes(@"<a href=\"data:text/html,x\">x</a>", @"<a>x</a>"));
}

void test_checkboxes ()
{
	OAK_ASSERT(Sanitizes(@"<input type=\"checkbox\" checked=\"\" disabled=\"\" />", @"<input type=\"checkbox\" checked=\"\" disabled=\"\" />"));
	OAK_ASSERT(Sanitizes(@"<input type=\"checkbox\">", @"<input type=\"checkbox\" disabled=\"\">"));
	OAK_ASSERT(Sanitizes(@"<input type=\"text\" value=\"x\">", @""));
	OAK_ASSERT(Sanitizes(@"<input>", @""));
}

void test_text_that_isnt_a_tag ()
{
	OAK_ASSERT(Sanitizes(@"a < b", @"a &lt; b"));
	OAK_ASSERT(Sanitizes(@"&lt;script>x", @"&lt;script>x"));
	OAK_ASSERT(Sanitizes(@"<b title=\"unclosed>x", @"&lt;b title=\"unclosed>x"));
	OAK_ASSERT(Sanitizes(@"<b", @"&lt;b"));
	OAK_ASSERT(Sanitizes(@"", @""));
}
