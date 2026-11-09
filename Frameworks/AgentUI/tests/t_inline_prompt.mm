#import <AgentUI/AgentInlinePromptController.h>
#import "inline_prompt_fakes.h"

template <typename T> static T* FindView (NSView* view)
{
	if([view isKindOfClass:[T class]])
		return (T*)view;
	for(NSView* subview in view.subviews)
	{
		if(T* res = FindView<T>(subview))
			return res;
	}
	return nil;
}

static NSArray<NSString*>* ButtonTitles (NSView* view)
{
	NSMutableArray* res = [NSMutableArray array];
	if([view isKindOfClass:[NSButton class]] && [(NSButton*)view action] != NSSelectorFromString(@"toggleCodeBlock:"))
		[res addObject:[(NSButton*)view title]]; // not the code blocks’ checkboxes
	for(NSView* subview in view.subviews)
		[res addObjectsFromArray:ButtonTitles(subview)];
	return res;
}

void test_finished_shows_the_diffs ()
{
	__block std::string text, buttons;
	dispatch_sync(dispatch_get_main_queue(), ^{
		AgentInlinePromptController* prompt = [[AgentInlinePromptController alloc] initWithAgentName:@"Claude" context:nil];
		(void)prompt.view;
		[prompt showFinishedWithChanges:@[
			@{ @"path": @"main.cc", @"oldText": @"a\nold\nc\n", @"newText": @"a\nnew\nc\n" },
			@{ @"path": @"notes.txt", @"newText": @"hello\n" },
		] reply:@"Renamed it."];
		text    = std::string(FindView<NSTextView>(prompt.view).string.UTF8String);
		buttons = std::string([ButtonTitles(prompt.view) componentsJoinedByString:@","].UTF8String);
	});
	OAK_ASSERT_EQ(text, "main.cc  +1 −1\n  a\n− old\n+ new\n  c\nnotes.txt  new  +1 −0\n+ hello");
	OAK_ASSERT_EQ(buttons, "Show in Chat,Undo,Keep");
}

void test_long_diffs_scroll ()
{
	__block CGFloat shortHeight = 0, longHeight = 0;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSMutableString* longText = [NSMutableString string];
		for(size_t i = 0; i < 200; ++i)
			[longText appendFormat:@"line %zu\n", i];

		AgentInlinePromptController* prompt = [[AgentInlinePromptController alloc] initWithAgentName:@"Claude" context:nil];
		(void)prompt.view;
		[prompt showFinishedWithChanges:@[ @{ @"path": @"a.txt", @"oldText": @"x\n", @"newText": @"y\n" } ] reply:nil];
		[prompt.view layoutSubtreeIfNeeded];
		shortHeight = NSHeight(FindView<NSScrollView>(prompt.view).frame);

		[prompt showFinishedWithChanges:@[ @{ @"path": @"b.txt", @"newText": longText } ] reply:nil];
		[prompt.view layoutSubtreeIfNeeded];
		longHeight = NSHeight(FindView<NSScrollView>(prompt.view).frame);
	});
	OAK_ASSERT_LT(shortHeight, 100);
	OAK_ASSERT_EQ(longHeight, 280);
}

void test_permission_request_shows_the_diff ()
{
	__block std::string text, buttons;
	dispatch_sync(dispatch_get_main_queue(), ^{
		AgentInlinePromptController* prompt = [[AgentInlinePromptController alloc] initWithAgentName:@"Claude" context:nil];
		(void)prompt.view;
		[prompt showPermissionRequest:@"Edit main.cc" changes:@[ @{ @"path": @"main.cc", @"oldText": @"old\n", @"newText": @"new\n" } ]];
		text    = std::string(FindView<NSTextView>(prompt.view).string.UTF8String);
		buttons = std::string([ButtonTitles(prompt.view) componentsJoinedByString:@","].UTF8String);
	});
	OAK_ASSERT_EQ(text, "main.cc  +1 −1\n− old\n+ new");
	OAK_ASSERT_EQ(buttons, "Show in Chat,Reject,Allow");
}

static NSButton* ButtonTitled (NSView* view, NSString* title)
{
	if([view isKindOfClass:[NSButton class]] && [[(NSButton*)view title] isEqualToString:title])
		return (NSButton*)view;
	for(NSView* subview in view.subviews)
	{
		if(NSButton* res = ButtonTitled(subview, title))
			return res;
	}
	return nil;
}

void test_code_reply_can_replace_the_selection ()
{
	__block std::string text, buttons, inserted;
	__block BOOL replaced = NO;
	dispatch_sync(dispatch_get_main_queue(), ^{
		InlinePromptRecorder* recorder = [[InlinePromptRecorder alloc] init];
		AgentInlinePromptController* prompt = [[AgentInlinePromptController alloc] initWithAgentName:@"Claude" context:@"data.csv:1–3"];
		prompt.delegate = recorder;
		prompt.replacesSelection = YES;
		(void)prompt.view;
		[prompt showFinishedWithChanges:@[ ] reply:@"Here:\n\n```\n1,a\n2,b\n```\n\n```\nother\n```"];
		text    = std::string(FindView<NSTextView>(prompt.view).string.UTF8String);
		buttons = std::string([ButtonTitles(prompt.view) componentsJoinedByString:@","].UTF8String);

		[ButtonTitled(prompt.view, @"Replace Selection") performClick:nil];
		inserted = std::string(recorder.insertedText.UTF8String ?: "«nil»");
		replaced = recorder.replaced;
	});
	OAK_ASSERT(text.find("```") == std::string::npos); // rendered, not raw Markdown
	OAK_ASSERT(text.find("1,a") != std::string::npos);
	OAK_ASSERT_EQ(buttons, "Show in Chat,Copy,Replace Selection,Close");
	OAK_ASSERT_EQ(inserted, "1,a\n2,b"); // the first block, the only one checked to start with
	OAK_ASSERT(replaced);
}

static NSButton* CheckboxTitled (NSView* view, NSString* prefix)
{
	if([view isKindOfClass:[NSButton class]] && [[(NSButton*)view title] hasPrefix:prefix] && [(NSButton*)view action] == NSSelectorFromString(@"toggleCodeBlock:"))
		return (NSButton*)view;
	for(NSView* subview in view.subviews)
	{
		if(NSButton* res = CheckboxTitled(subview, prefix))
			return res;
	}
	return nil;
}

static NSArray<NSString*>* Labels (NSView* view)
{
	NSMutableArray* res = [NSMutableArray array];
	if([view isKindOfClass:[NSTextField class]] && !view.hidden && ![(NSTextField*)view isEditable])
		[res addObject:[(NSTextField*)view stringValue]];
	for(NSView* subview in view.subviews)
		[res addObjectsFromArray:Labels(subview)];
	return res;
}

void test_several_code_blocks_can_be_checked ()
{
	__block std::string first, both, selected, status;
	__block BOOL singleHasCheckboxes = YES, hintShown = NO, stillShown = NO, disabledWithNone = NO;
	__block NSArray* modes;
	dispatch_sync(dispatch_get_main_queue(), ^{
		InlinePromptRecorder* recorder = [[InlinePromptRecorder alloc] init];
		AgentInlinePromptController* prompt = [[AgentInlinePromptController alloc] initWithAgentName:@"Claude" context:nil];
		prompt.delegate = recorder;
		(void)prompt.view;

		[prompt showFinishedWithChanges:@[ ] reply:@"```\nonly\n```"];
		singleHasCheckboxes = CheckboxTitled(prompt.view, @"1.") != nil;

		[prompt showFinishedWithChanges:@[ ] reply:@"First:\n\n```csv\n\n  1,a\n2,b\n```\n\nThen:\n\n```\nsecond\n```"];
		NSButton* one = CheckboxTitled(prompt.view, @"1. csv — 1,a");
		NSButton* two = CheckboxTitled(prompt.view, @"2. second");
		hintShown = [[Labels(prompt.view) componentsJoinedByString:@"|"] containsString:@"Check the blocks to use"];

		// The first is checked to start with; the popover stays open for more
		[ButtonTitled(prompt.view, @"Insert at Cursor") performClick:nil];
		first = std::string(recorder.insertedText.UTF8String ?: "«nil»");

		[two performClick:nil];
		[ButtonTitled(prompt.view, @"Insert After") performClick:nil];
		both = std::string(recorder.insertedText.UTF8String ?: "«nil»");
		stillShown = ButtonTitled(prompt.view, @"Insert After") != nil;
		status = std::string([[Labels(prompt.view) componentsJoinedByString:@"|"] UTF8String]);

		// Text selected in the reply wins over the checkboxes
		NSTextView* reply = FindView<NSTextView>(prompt.view);
		NSRange range = [reply.string rangeOfString:@"2,b"];
		[reply setSelectedRange:range];
		[ButtonTitled(prompt.view, @"Insert After") performClick:nil];
		selected = std::string(recorder.insertedText.UTF8String ?: "«nil»");

		[reply setSelectedRange:NSMakeRange(0, 0)];
		[one performClick:nil];
		[two performClick:nil];
		disabledWithNone = !ButtonTitled(prompt.view, @"Insert After").enabled && !ButtonTitled(prompt.view, @"Copy").enabled;
		modes = recorder.modes;
	});
	OAK_ASSERT(!singleHasCheckboxes);
	OAK_ASSERT(hintShown);
	OAK_ASSERT_EQ(first, "\n  1,a\n2,b"); // verbatim; the checkbox names its first non-blank line
	OAK_ASSERT_EQ(both, "\n  1,a\n2,b\nsecond");
	OAK_ASSERT(stillShown);
	OAK_ASSERT(status.find("Inserted.") != std::string::npos);
	OAK_ASSERT_EQ(selected, "2,b");
	OAK_ASSERT(disabledWithNone);
	OAK_ASSERT([modes isEqual:(@[ @(AgentInlineInsertAtCursor), @(AgentInlineInsertAfterLastInsertion), @(AgentInlineInsertAfterLastInsertion) ])]);
}

void test_code_reply_without_selection_inserts_at_cursor ()
{
	__block std::string buttons, withChanges, prose;
	dispatch_sync(dispatch_get_main_queue(), ^{
		AgentInlinePromptController* prompt = [[AgentInlinePromptController alloc] initWithAgentName:@"Claude" context:nil];
		(void)prompt.view;
		[prompt showFinishedWithChanges:@[ ] reply:@"```\nx\n```"];
		buttons = std::string([ButtonTitles(prompt.view) componentsJoinedByString:@","].UTF8String);

		// The agent already edited: copy only, beside Undo / Keep
		[prompt showFinishedWithChanges:@[ @{ @"path": @"a.txt", @"oldText": @"x\n", @"newText": @"y\n" } ] reply:@"```\nx\n```"];
		withChanges = std::string([ButtonTitles(prompt.view) componentsJoinedByString:@","].UTF8String);

		// No code, nothing to insert
		[prompt showFinishedWithChanges:@[ ] reply:@"It’s fine as is."];
		prose = std::string([ButtonTitles(prompt.view) componentsJoinedByString:@","].UTF8String);
	});
	OAK_ASSERT_EQ(buttons, "Show in Chat,Copy,Insert at Cursor,Close");
	OAK_ASSERT_EQ(withChanges, "Show in Chat,Copy,Undo,Keep");
	OAK_ASSERT_EQ(prose, "Show in Chat,Close");
}
