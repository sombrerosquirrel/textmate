#import <AgentUI/AgentCodeLocation.h>

static std::string Join (NSArray<NSString*>* paths)
{
	return [paths componentsJoinedByString:@" | "].UTF8String;
}

static NSString* const kFile = @"#import \"A.h\"\n\n@implementation A\n- (void)one\n{\n\tNSLog(@\"one\");\n}\n\n- (void)two\n{\n\tint x = 1;\n\tint y = 2;\n\tNSLog(@\"%d\", x + y);\n}\n@end\n";

void test_paths_in_info ()
{
	OAK_ASSERT_EQ(Join([AgentCodeLocation pathsInInfo:@"swift Sources/App/File.swift"]), "Sources/App/File.swift");
	OAK_ASSERT_EQ(Join([AgentCodeLocation pathsInInfo:@"objc:Frameworks/A.mm"]), "Frameworks/A.mm");
	OAK_ASSERT_EQ(Join([AgentCodeLocation pathsInInfo:@"python title=\"a/b.py\""]), "a/b.py");
	OAK_ASSERT_EQ(Join([AgentCodeLocation pathsInInfo:@"src/main.cc:12-20"]), "src/main.cc");
	OAK_ASSERT_EQ(Join([AgentCodeLocation pathsInInfo:@"swift"]), "");
	OAK_ASSERT_EQ(Join([AgentCodeLocation pathsInInfo:@"c++"]), "");
	OAK_ASSERT_EQ(Join([AgentCodeLocation pathsInInfo:nil]), "");
}

void test_paths_in_text ()
{
	OAK_ASSERT_EQ(Join([AgentCodeLocation pathsInText:@"In `Frameworks/A.mm`, change two (see also A.h:3):"]), "A.h | Frameworks/A.mm");
	OAK_ASSERT_EQ(Join([AgentCodeLocation pathsInText:@"Version 1.2.3, e.g. this, see https://example.com/a.html."]), "");
	OAK_ASSERT_EQ(Join([AgentCodeLocation pathsInText:@"Update the src/ directory and main.cc."]), "main.cc");
}

void test_text_before_code ()
{
	NSString* markdown = @"First:\n\n```sh\nls\n```\n\nThen in `b.py`:\n\n- item\n\n  ```py\n  print(1)\n  ```\n";
	OAK_ASSERT_EQ(std::string([AgentCodeLocation textBeforeCode:@"ls" inMarkdown:markdown].UTF8String), "First:");
	OAK_ASSERT_EQ(std::string([AgentCodeLocation textBeforeCode:@"print(1)" inMarkdown:markdown].UTF8String), "Then in `b.py`:\n- item");
	OAK_ASSERT([AgentCodeLocation textBeforeCode:@"nope" inMarkdown:markdown] == nil);

	// While streaming, the closing fence hasn’t arrived yet
	OAK_ASSERT_EQ(std::string([AgentCodeLocation textBeforeCode:@"x = 1" inMarkdown:@"In a.py:\n\n```py\nx = 1"].UTF8String), "In a.py:");
}

void test_line_range_of_code ()
{
	NSRange range = [AgentCodeLocation lineRangeOfCode:@"- (void)two\n{\n    int x = 1;\n    int y = 2;" inText:kFile];
	OAK_ASSERT_EQ(range.location, 9);
	OAK_ASSERT_EQ(range.length, 4);

	// Left-out lines
	range = [AgentCodeLocation lineRangeOfCode:@"@implementation A\n// ...\n- (void)two\n{\n\t// …\n\tNSLog(@\"%d\", x + y);\n}" inText:kFile];
	OAK_ASSERT_EQ(range.location, 3);
	OAK_ASSERT_EQ(range.length, 12);

	// After left-out lines, the closing brace with the code’s indentation
	range = [AgentCodeLocation lineRangeOfCode:@"void f ()\n{\n\tfor(;;)\n\t{\n\t\t// …\n\t}\n}" inText:@"void f ()\n{\n\tfor(;;)\n\t{\n\t\tif(x)\n\t\t{\n\t\t}\n\t}\n}\n"];
	OAK_ASSERT_EQ(range.location, 1);
	OAK_ASSERT_EQ(range.length, 9);

	// A changed line is fine if most are found
	range = [AgentCodeLocation lineRangeOfCode:@"- (void)two\n{\n\tint x = 10;\n\tint y = 2;\n\tNSLog(@\"%d\", x + y);\n}" inText:kFile];
	OAK_ASSERT_EQ(range.location, 9);
	OAK_ASSERT_EQ(range.length, 6);
}

void test_line_range_not_found ()
{
	OAK_ASSERT_EQ([AgentCodeLocation lineRangeOfCode:@"func other() {\n\treturn 1\n}" inText:kFile].location, NSNotFound);
	OAK_ASSERT_EQ([AgentCodeLocation lineRangeOfCode:@"{" inText:kFile].location, NSNotFound); // occurs twice
	OAK_ASSERT_EQ([AgentCodeLocation lineRangeOfCode:@"int y = 2;" inText:kFile].location, 12);
	OAK_ASSERT_EQ([AgentCodeLocation lineRangeOfCode:@"- (void)two\nsomething\nelse\nentirely" inText:kFile].location, NSNotFound);
	OAK_ASSERT_EQ([AgentCodeLocation lineRangeOfCode:@"..." inText:kFile].location, NSNotFound);
}
