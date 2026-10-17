#import <AgentClient/AgentDiff.h>

void test_diff_counts_and_hunks ()
{
	AgentDiff* diff = [AgentDiff diffWithOldText:@"one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n" newText:@"one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n" contextLines:1];
	OAK_ASSERT_EQ(diff.addedLineCount, 2);
	OAK_ASSERT_EQ(diff.removedLineCount, 1);
	OAK_ASSERT_EQ(diff.hunks.count, 2);

	AgentDiffHunk* first = diff.hunks[0];
	OAK_ASSERT_EQ(first.oldStart, 1);
	OAK_ASSERT_EQ(first.lines.count, 4); // one, -two, +TWO, three
	OAK_ASSERT_EQ((NSInteger)first.lines[1].kind, (NSInteger)AgentDiffLineKindRemoved);
	OAK_ASSERT([first.lines[1].text isEqualToString:@"two"]);
	OAK_ASSERT_EQ(first.lines[1].oldLine, 2);
	OAK_ASSERT_EQ((NSInteger)first.lines[2].kind, (NSInteger)AgentDiffLineKindAdded);
	OAK_ASSERT_EQ(first.lines[2].newLine, 2);
	OAK_ASSERT_EQ(first.lines[3].oldLine, 3);
	OAK_ASSERT_EQ(first.lines[3].newLine, 3);

	AgentDiffHunk* second = diff.hunks[1];
	OAK_ASSERT([second.lines.lastObject.text isEqualToString:@"eleven"]);
	OAK_ASSERT_EQ(second.lines.lastObject.newLine, 11);
}

void test_diff_new_file_and_no_change ()
{
	AgentDiff* created = [AgentDiff diffWithOldText:nil newText:@"a\nb" contextLines:3];
	OAK_ASSERT_EQ(created.addedLineCount, 2);
	OAK_ASSERT_EQ(created.removedLineCount, 0);
	OAK_ASSERT_EQ(created.hunks.firstObject.lines.firstObject.newLine, 1);

	AgentDiff* same = [AgentDiff diffWithOldText:@"a\nb" newText:@"a\nb\n" contextLines:3];
	OAK_ASSERT(same.isEmpty);

	AgentDiff* deleted = [AgentDiff diffWithOldText:@"a\nb\n" newText:@"" contextLines:3];
	OAK_ASSERT_EQ(deleted.removedLineCount, 2);
}

void test_unified_diff_text ()
{
	AgentDiff* diff = [AgentDiff diffWithOldText:@"a\nb\n" newText:@"a\nc\n" contextLines:3];
	NSString* text = [diff unifiedDiffWithOldName:@"a/x.txt" newName:@"b/x.txt"];
	OAK_ASSERT([text hasPrefix:@"--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n a\n-b\n+c\n"]);
}
