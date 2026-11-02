#import <AgentUI/AgentInlinePromptController.h>

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
	if([view isKindOfClass:[NSButton class]])
		[res addObject:[(NSButton*)view title]];
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
