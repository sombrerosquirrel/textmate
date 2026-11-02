#import "transcript_view_fakes.h"

// Tests run on background threads, but views must be used on the main thread
static void RunOnMainThread (void(*test)())
{
	__block std::string error;
	dispatch_sync(dispatch_get_main_queue(), ^{
		try {
			test();
		}
		catch(std::exception const& e) {
			error = e.what();
		}
	});
	if(!error.empty())
		throw std::runtime_error(error);
}

struct transcript_host_t
{
	transcript_host_t ()
	{
		delegate      = [[FakeTranscriptDelegate alloc] init];
		scrollView    = [AgentTranscriptView scrollableTranscriptView];
		scrollView.frame = NSMakeRect(0, 0, 400, 600);
		view          = scrollView.documentView;
		view.actionDelegate = delegate;
		view.foldsCodeBlocks = YES; // as most tests expect; the panel's default is NO
		transcript    = [[AgentTranscript alloc] init];
		view.transcript = transcript;
	}

	AgentTranscriptItem* reply (NSString* markdown)
	{
		AgentTranscriptItem* item = [transcript applyUpdate:@{ @"sessionUpdate": @"agent_message_chunk", @"content": @{ @"type": @"text", @"text": markdown } }];
		[view reloadData];
		return item;
	}

	void click (NSString* action, AgentTranscriptItem* item, NSDictionary<NSString*, NSString*>* parameters = @{ })
	{
		NSURLComponents* components = [[NSURLComponents alloc] init];
		components.scheme = @"textmate-agent";
		components.host   = action;
		NSMutableArray* queryItems = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"item" value:item.identifier]];
		for(NSString* key in parameters)
			[queryItems addObject:[NSURLQueryItem queryItemWithName:key value:parameters[key]]];
		components.queryItems = queryItems;
		[(id<NSTextViewDelegate>)view textView:view clickedOnLink:components.URL atIndex:0];
	}

	std::string text () const { return view.textStorage.string.UTF8String; }
	bool contains (NSString* str) const { return [view.textStorage.string containsString:str]; }

	FakeTranscriptDelegate* delegate;
	NSScrollView* scrollView;
	AgentTranscriptView* view;
	AgentTranscript* transcript;
};

static NSString* const kReply = @"In `Sources/A.m`:\n\n```objc\n- (void)two\n{\n\tint x = 1;\n}\n```\n\nAnd a command:\n\n```sh\nls -l\n```\n";

static void code_blocks_start_folded_with_place ()
{
	transcript_host_t host;
	host.delegate.files = @{ @"/project/Sources/A.m": @"@implementation A\n- (void)one\n{\n}\n\n- (void)two\n{\n\tint x = 1;\n}\n@end\n" };
	host.reply(kReply);

	OAK_ASSERT(host.contains(@"▸ Objective-C · 4 lines · A.m:6–9"));
	OAK_ASSERT(host.contains(@"▸ sh · 1 line · ls -l"));
	OAK_ASSERT(!host.contains(@"int x = 1;"));

	// The arrow is larger than the line’s text
	NSTextStorage* storage = host.view.textStorage;
	NSUInteger arrow = [storage.string rangeOfString:@"▸ sh"].location;
	OAK_ASSERT_GT([[storage attribute:NSFontAttributeName atIndex:arrow effectiveRange:nullptr] pointSize], [[storage attribute:NSFontAttributeName atIndex:arrow + 2 effectiveRange:nullptr] pointSize]);
	OAK_ASSERT_EQ(host.delegate.views.count, 0);
}

static void unfolded_code_block_shows_view ()
{
	transcript_host_t host;
	AgentTranscriptItem* item = host.reply(kReply);
	host.click(@"code", item, @{ @"block": @"0" });

	OAK_ASSERT(host.contains(@"▾ Objective-C · 4 lines"));
	OAK_ASSERT(host.contains(@"Insert at Cursor"));
	OAK_ASSERT_EQ(host.delegate.views.count, 1);

	FakeCodeView* codeView = host.delegate.views[0];
	OAK_ASSERT(codeView.superview == host.view);
	OAK_ASSERT_EQ(NSHeight(codeView.frame), 80);
	OAK_ASSERT_LT(300, NSWidth(codeView.frame));
	OAK_ASSERT_LT(NSWidth(codeView.frame), 400);

	// The text after it starts below the view
	NSUInteger index = [host.view.textStorage.string rangeOfString:@"And a command"].location;
	NSRect rect = [host.view.layoutManager boundingRectForGlyphRange:[host.view.layoutManager glyphRangeForCharacterRange:NSMakeRange(index, 1) actualCharacterRange:nullptr] inTextContainer:host.view.textContainer];
	OAK_ASSERT_LE(NSMaxY(codeView.frame), NSMinY(rect) + host.view.textContainerOrigin.y);

	// Grows with its code
	codeView.fittingHeight = 140;
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	OAK_ASSERT_EQ(NSHeight(codeView.frame), 140);

	// Kept while the reply streams in, and gets the new code
	[host.transcript applyUpdate:@{ @"sessionUpdate": @"agent_message_chunk", @"content": @{ @"type": @"text", @"text": @"\nDone." } }];
	[host.view reloadData];
	OAK_ASSERT_EQ(host.delegate.views.count, 1);
	OAK_ASSERT(codeView.superview == host.view);

	// Folding the block removes the view
	host.click(@"code", item, @{ @"block": @"0" });
	OAK_ASSERT(codeView.superview == nil);
	OAK_ASSERT(host.contains(@"▸ Objective-C · 4 lines"));
}

static void toggle_shows_or_folds_all_code_blocks ()
{
	transcript_host_t host;
	host.view.foldsCodeBlocks = NO;
	AgentTranscriptItem* item = host.reply(kReply);
	OAK_ASSERT(host.contains(@"▾ Objective-C · 4 lines"));
	OAK_ASSERT(host.contains(@"▾ sh · 1 line"));
	OAK_ASSERT_EQ(host.delegate.views.count, 2);

	// One folded by hand, then all folded
	host.click(@"code", item, @{ @"block": @"0" });
	OAK_ASSERT(host.contains(@"▸ Objective-C · 4 lines"));
	host.view.foldsCodeBlocks = YES;
	OAK_ASSERT(host.contains(@"▸ Objective-C · 4 lines"));
	OAK_ASSERT(host.contains(@"▸ sh · 1 line"));
	for(FakeCodeView* codeView in host.delegate.views)
		OAK_ASSERT(codeView.superview == nil);

	// One opened by hand, then all shown
	host.click(@"code", item, @{ @"block": @"1" });
	OAK_ASSERT(host.contains(@"▾ sh · 1 line"));
	host.view.foldsCodeBlocks = NO;
	OAK_ASSERT(host.contains(@"▾ Objective-C · 4 lines"));
	OAK_ASSERT(host.contains(@"▾ sh · 1 line"));

	// Later replies follow
	host.view.foldsCodeBlocks = YES;
	[host.transcript addUserMessage:@"Again" attachmentNames:@[ ]];
	host.reply(@"```py\nprint(1)\n```\n");
	OAK_ASSERT(host.contains(@"▸ py · 1 line"));
}

static void toggle_folds_code_block_in_list ()
{
	transcript_host_t host;
	host.view.foldsCodeBlocks = NO;
	host.reply(@"A list:\n\n- One.\n- Two:\n\n  ```sh\n  ls -l\n  ```\n- Three.\n");
	OAK_ASSERT(host.contains(@"▾ sh · 1 line"));
	host.view.foldsCodeBlocks = YES;
	OAK_ASSERT(host.contains(@"▸ sh · 1 line"));
	OAK_ASSERT(host.contains(@"▾ sh · 1 line") == NO);
	for(FakeCodeView* codeView in host.delegate.views)
		OAK_ASSERT(codeView.superview == nil);
}

static void folds_and_opens_everything ()
{
	transcript_host_t host;
	host.view.foldsCodeBlocks = NO;
	AgentTranscriptItem* user  = [host.transcript addUserMessage:@"Show it" attachmentNames:@[ ]];
	AgentTranscriptItem* item  = host.reply(kReply);
	[host.view setAllFolded:YES];
	OAK_ASSERT(!user.folded); // prompts have no ▾ / ▸
	OAK_ASSERT(item.folded);
	OAK_ASSERT(host.contains(@"2 code blocks"));

	// A second click opens it all, also what was folded by hand
	host.click(@"fold", item);
	host.click(@"code", item, @{ @"block": @"0" });
	host.click(@"fold", item);
	[host.view setAllFolded:NO];
	OAK_ASSERT(!item.folded);
	OAK_ASSERT(host.contains(@"▾ Objective-C · 4 lines"));
	OAK_ASSERT(host.contains(@"▾ sh · 1 line"));

	// Folded replies open with their code blocks folded
	[host.view setAllFolded:YES];
	host.click(@"fold", item);
	OAK_ASSERT(host.contains(@"▸ Objective-C · 4 lines"));
}

static void fold_items ()
{
	transcript_host_t host;
	[host.transcript addUserMessage:@"First question\nwith two lines" attachmentNames:@[ @"a.m" ]];
	AgentTranscriptItem* item = host.reply(kReply);
	host.click(@"code", item, @{ @"block": @"1" });
	OAK_ASSERT_EQ(host.delegate.views.count, 1);

	[host.transcript foldItemsBeforeItem:nil];
	[host.view reloadData];
	OAK_ASSERT(host.contains(@"First question\nwith two lines"));
	OAK_ASSERT(host.contains(@"📎 a.m"));
	OAK_ASSERT(!host.contains(@"▸ First question"));
	OAK_ASSERT(!host.contains(@"▾ First question"));
	OAK_ASSERT(host.contains(@"▸ In Sources/A.m:  · 2 code blocks"));
	OAK_ASSERT(host.delegate.views[0].superview == nil);

	host.click(@"fold", item);
	OAK_ASSERT(host.contains(@"▾ In Sources/A.m:"));
	OAK_ASSERT(host.contains(@"▾ sh · 1 line")); // still unfolded
}

static NSDictionary* WriteToolCall (NSString* path, NSString* status)
{
	return @{ @"sessionUpdate": @"tool_call", @"toolCallId": @"w1", @"title": @"Write new.py", @"kind": @"edit", @"status": status,
		@"locations": @[ @{ @"path": path } ],
		@"content": @[ @{ @"type": @"diff", @"path": path, @"oldText": NSNull.null, @"newText": @"print(1)\nprint(2)\n" } ] };
}

static void links_to_files_not_created_yet ()
{
	transcript_host_t host;
	AgentTranscriptItem* item = [host.transcript applyUpdate:WriteToolCall(@"/project/new.py", @"pending")];
	[host.view reloadData];
	OAK_ASSERT(host.contains(@"↳ new.py  not created yet"));
	OAK_ASSERT(host.contains(@"✎ new.py  new, not created yet"));

	// Opening it shows what the agent wants to write instead of an empty document
	host.click(@"open", item, @{ @"path": @"/project/new.py" });
	OAK_ASSERT(host.delegate.openedPath == nil);
	OAK_ASSERT_EQ(std::string(host.delegate.diffPath.UTF8String), "/project/new.py");
	OAK_ASSERT_EQ(std::string(host.delegate.diffNewText.UTF8String), "print(1)\nprint(2)\n");

	// Once written, the links open the file
	host.delegate.files = @{ @"/project/new.py": @"print(1)\nprint(2)\n" };
	[host.transcript applyUpdate:@{ @"sessionUpdate": @"tool_call_update", @"toolCallId": @"w1", @"status": @"completed" }];
	[host.view reloadData];
	OAK_ASSERT(!host.contains(@"not created yet"));
	host.click(@"open", item, @{ @"path": @"/project/new.py" });
	OAK_ASSERT_EQ(std::string(host.delegate.openedPath.UTF8String), "/project/new.py");
}

static NSUInteger Occurrences (NSString* text, NSString* str)
{
	return [text componentsSeparatedByString:str].count - 1;
}

static void new_items_follow_the_folding ()
{
	transcript_host_t host;
	host.transcript.foldsNewItems = YES;
	AgentTranscriptItem* user = [host.transcript addUserMessage:@"Show it" attachmentNames:@[ ]];
	AgentTranscriptItem* first = host.reply(kReply);
	AgentTranscriptItem* tool  = [host.transcript applyUpdate:WriteToolCall(@"/project/new.py", @"pending")];
	[host.view reloadData];
	OAK_ASSERT(!user.folded);
	OAK_ASSERT(!first.folded); // replies stream open
	OAK_ASSERT(tool.folded);
	OAK_ASSERT(!host.contains(@"+ print(1)"));

	// Two newer replies pass it
	AgentTranscriptItem* second = host.reply(@"Second");
	[host.transcript applyUpdate:@{ @"sessionUpdate": @"tool_call", @"toolCallId": @"t2", @"title": @"Read", @"status": @"pending" }];
	AgentTranscriptItem* third = host.reply(@"Third");
	OAK_ASSERT(first.folded);
	OAK_ASSERT(host.contains(@"· 2 code blocks"));
	OAK_ASSERT(!second.folded);
	OAK_ASSERT(!third.folded);

	// Opened by hand it stays open
	host.click(@"fold", first);
	[host.transcript applyUpdate:@{ @"sessionUpdate": @"tool_call", @"toolCallId": @"t3", @"title": @"Read", @"status": @"pending" }];
	host.reply(@"Fourth");
	OAK_ASSERT(!first.folded);
	OAK_ASSERT(second.folded);

	host.transcript.foldsNewItems = NO;
	[host.transcript applyUpdate:@{ @"sessionUpdate": @"tool_call", @"toolCallId": @"t4", @"title": @"Read", @"status": @"pending" }];
	AgentTranscriptItem* next = host.reply(@"More");
	OAK_ASSERT(!next.folded);
}

static void working_item_shows_its_status ()
{
	transcript_host_t host;
	AgentTranscriptItem* first  = [host.transcript applyUpdate:WriteToolCall(@"/project/new.py", @"in_progress")];
	AgentTranscriptItem* second = [host.transcript applyUpdate:@{ @"sessionUpdate": @"tool_call", @"toolCallId": @"t2", @"title": @"Read file", @"status": @"in_progress" }];
	[host.view reloadData];
	OAK_ASSERT_EQ(Occurrences(host.view.textStorage.string, @"0:00"), 0);

	[host.view setWorkingItem:first tokens:1000];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT(host.contains(@"Write new.py  ·  0:00"));
	NSUInteger length = host.view.textStorage.length;

	// Tokens update the line without rendering the item
	[host.view setWorkingItem:first tokens:2500];
	OAK_ASSERT(host.contains(@"Write new.py  ·  0:00 · +1.5k tokens"));
	OAK_ASSERT_GT(host.view.textStorage.length, length);
	[host.view reloadData];
	OAK_ASSERT_EQ(Occurrences(host.view.textStorage.string, @"+1.5k tokens"), 1);

	// Only the line being worked on has it, and it starts over
	[host.view setWorkingItem:second tokens:2500];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT(host.contains(@"Read file  ·  0:00"));
	OAK_ASSERT(!host.contains(@"tokens"));
	OAK_ASSERT_EQ(Occurrences(host.view.textStorage.string, @"0:00"), 1);

	[host.view setWorkingItem:nil tokens:0];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT_EQ(Occurrences(host.view.textStorage.string, @"0:00"), 0);
	(void)second;
}

static void working_status_update_before_flush ()
{
	transcript_host_t host;
	AgentTranscriptItem* first  = [host.transcript applyUpdate:WriteToolCall(@"/project/new.py", @"in_progress")];
	AgentTranscriptItem* second = [host.transcript applyUpdate:@{ @"sessionUpdate": @"tool_call", @"toolCallId": @"t2", @"title": @"Read file", @"status": @"in_progress" }];
	AgentTranscriptItem* card = [host.transcript addPermissionRequest:@{ @"toolCall": @{ @"toolCallId": @"w1" }, @"options": @[ @{ @"kind": @"allow_once", @"name": @"Yes", @"optionId": @"y" } ] }];
	[host.view setWorkingItem:first tokens:0];
	[host.view setWorkingItem:first tokens:5000];
	[host.view reloadData];
	OAK_ASSERT(host.contains(@"+5.0k tokens"));
	OAK_ASSERT(!host.contains(@"Read file")); // waits for the answer

	// The first item’s status is still in the text when the second one’s updates
	[host.view setWorkingItem:second tokens:5000];
	[host.view setWorkingItem:second tokens:5000];
	[host.transcript resolvePermissionItem:card selectedOptionId:@"y"];
	[host.view setNeedsDisplayItem:card];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT(host.contains(@"Read file  ·  0:00"));
	OAK_ASSERT(!host.contains(@"+5.0k tokens"));
}

static void waiting_line_until_the_first_update ()
{
	transcript_host_t host;
	[host.transcript addUserMessage:@"Go" attachmentNames:@[ ]];
	AgentTranscriptItem* line = [host.transcript addWaitingLine:@"Waiting for Claude Code"];
	[host.view reloadData];
	[host.view setWorkingItem:line tokens:0];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT(host.contains(@"◐ Waiting for Claude Code  ·  0:00"));

	AgentTranscriptItem* reply = [host.transcript applyUpdate:@{ @"sessionUpdate": @"agent_message_chunk", @"content": @{ @"type": @"text", @"text": @"Hello" } }];
	[host.transcript endWaitingLine:line];
	[host.view setNeedsDisplayItem:reply];
	[host.view setNeedsDisplayItem:line];
	[host.view setWorkingItem:reply tokens:0];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT(!host.contains(@"Waiting for"));
	OAK_ASSERT(host.contains(@"Hello"));
	OAK_ASSERT_EQ(Occurrences(host.view.textStorage.string, @"0:00"), 1);
}

static void diff_lines_are_rectangles ()
{
	transcript_host_t host;
	[host.transcript applyUpdate:@{ @"sessionUpdate": @"tool_call", @"toolCallId": @"e1", @"title": @"Edit a.py", @"status": @"completed",
		@"content": @[ @{ @"type": @"diff", @"path": @"/project/a.py", @"oldText": @"one\ntwo\n", @"newText": @"one\n    deep\n        deeper\n" } ] }];
	[host.view reloadData];

	NSTextStorage* storage = host.view.textStorage;
	auto blocksAt = [&](NSString* str){
		NSRange range = [storage.string rangeOfString:str];
		OAK_ASSERT(range.location != NSNotFound);
		NSParagraphStyle* style = [storage attribute:NSParagraphStyleAttributeName atIndex:range.location effectiveRange:nullptr];
		OAK_ASSERT([storage attribute:NSBackgroundColorAttributeName atIndex:range.location effectiveRange:nullptr] == nil);
		return style.textBlocks;
	};

	// One rectangle for both added lines, however they’re indented, another for the removed one
	NSArray* added = blocksAt(@"+     deep");
	OAK_ASSERT_EQ(added.count, 1);
	OAK_ASSERT(added.firstObject == blocksAt(@"+         deeper").firstObject);
	OAK_ASSERT(((NSTextBlock*)added.firstObject).backgroundColor != nil);
	NSArray* removed = blocksAt(@"− two");
	OAK_ASSERT_EQ(removed.count, 1);
	OAK_ASSERT(removed.firstObject != added.firstObject);
	OAK_ASSERT_EQ(blocksAt(@"  one").count, 0); // context lines have none
}

static void row_with_open_question_stays_open ()
{
	transcript_host_t host;
	AgentTranscriptItem* item = [host.transcript applyUpdate:WriteToolCall(@"/project/new.py", @"pending")];
	[host.transcript addPermissionRequest:@{ @"toolCall": @{ @"toolCallId": @"w1" }, @"options": @[ @{ @"kind": @"allow_once", @"name": @"Yes", @"optionId": @"y" } ] }];
	[host.view reloadData];
	OAK_ASSERT(host.contains(@"+ print(1)"));

	// Folding everything leaves the diff with its question
	[host.view setAllFolded:YES];
	OAK_ASSERT(item.folded);
	OAK_ASSERT(host.contains(@"▾ "));
	OAK_ASSERT(!host.contains(@"▸ "));
	OAK_ASSERT(host.contains(@"+ print(1)"));
	OAK_ASSERT(host.contains(@"Allow this action?"));
}

static void permission_question_in_its_tool_row ()
{
	transcript_host_t host;
	[host.transcript applyUpdate:WriteToolCall(@"/project/new.py", @"pending")];
	[host.transcript applyUpdate:@{ @"sessionUpdate": @"tool_call", @"toolCallId": @"w2", @"title": @"Write other.py", @"kind": @"edit", @"status": @"pending" }];
	AgentTranscriptItem* card = [host.transcript addPermissionRequest:@{ @"toolCall": @{ @"toolCallId": @"w1" }, @"options": @[ @{ @"kind": @"allow_once", @"name": @"Yes", @"optionId": @"allow" } ] }];
	[host.view reloadData];

	// After the diff it’s about; the diff shows once. The next tool call, announced
	// before the question, waits for the answer.
	NSString* text = host.view.textStorage.string;
	NSUInteger diff     = [text rangeOfString:@"+ print(1)"].location;
	NSUInteger question = [text rangeOfString:@"Allow this action?"].location;
	OAK_ASSERT_EQ(Occurrences(text, @"+ print(1)"), 1);
	OAK_ASSERT_EQ(Occurrences(text, @"Allow this action?"), 1);
	OAK_ASSERT_LT(diff, question);
	OAK_ASSERT(host.contains(@"✓ Yes ↩"));
	OAK_ASSERT(!host.contains(@"Write other.py"));

	// Answered: the answer is on the row’s line, no card left, the next tool call shows
	[host.transcript resolvePermissionItem:card selectedOptionId:@"allow"];
	[host.view setNeedsDisplayItem:card];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT(!host.contains(@"Allow this action?"));
	OAK_ASSERT(host.contains(@"Write new.py  ·  ✓ Yes"));
	OAK_ASSERT_EQ(Occurrences(host.view.textStorage.string, @"+ print(1)"), 1);
	text = host.view.textStorage.string;
	OAK_ASSERT_LT([text rangeOfString:@"Write new.py"].location, [text rangeOfString:@"Write other.py"].location);

	// Rendered before the question came: taken out until it’s answered
	AgentTranscriptItem* card2 = [host.transcript addPermissionRequest:@{ @"toolCall": @{ @"toolCallId": @"w1" }, @"options": @[ @{ @"kind": @"allow_once", @"name": @"Yes", @"optionId": @"allow" } ] }];
	[host.view setNeedsDisplayItem:card2];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT(host.contains(@"Allow this action?"));
	OAK_ASSERT(!host.contains(@"Write other.py"));
	[host.transcript resolvePermissionItem:card2 selectedOptionId:@"allow"];
	[host.view setNeedsDisplayItem:card2];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT_EQ(Occurrences(host.view.textStorage.string, @"Write other.py"), 1);
}

static void permission_without_tool_row_is_a_card ()
{
	transcript_host_t host;
	[host.transcript addPermissionRequest:@{ @"toolCall": @{ @"toolCallId": @"x", @"title": @"Run ls" }, @"options": @[ @{ @"kind": @"allow_once", @"name": @"Yes", @"optionId": @"allow" } ] }];
	[host.view reloadData];
	OAK_ASSERT(host.contains(@"Allow this action?\nRun ls"));
}

static void stays_at_end_when_shorter ()
{
	transcript_host_t host;
	NSMutableString* longText = [NSMutableString string];
	for(NSUInteger i = 0; i < 100; ++i)
		[longText appendFormat:@"Line %lu of a long reply.\n\n", i];
	host.reply(longText);
	NSView* view = host.view;
	[host.view scrollPoint:NSMakePoint(0, NSHeight(view.bounds))];

	// e.g. the working line or the changed files appear under the chat
	[host.scrollView setFrameSize:NSMakeSize(400, 500)];
	OAK_ASSERT_GE(NSMaxY(view.visibleRect), NSHeight(view.bounds) - 1);

	// Scrolled up: stays there
	[host.view scrollPoint:NSZeroPoint];
	[host.scrollView setFrameSize:NSMakeSize(400, 400)];
	OAK_ASSERT_EQ(NSMinY(view.visibleRect), 0);
}

static void reload_keeps_scroll_position ()
{
	transcript_host_t host;
	NSMutableString* longText = [NSMutableString string];
	for(NSUInteger i = 0; i < 100; ++i)
		[longText appendFormat:@"Line %lu of a long reply.\n\n", i];
	host.reply(longText);
	NSView* view = host.view;

	// Scrolled up to read, e.g. to click a link to a file: a new theme keeps the place
	[host.view scrollPoint:NSMakePoint(0, 600)];
	CGFloat top = NSMinY(view.visibleRect);
	[host.view reloadData];
	OAK_ASSERT_LT(fabs(NSMinY(view.visibleRect) - top), 1);
	[host.view reloadData];
	OAK_ASSERT_LT(fabs(NSMinY(view.visibleRect) - top), 1);

	// At the end: stays at the end
	[host.view scrollPoint:NSMakePoint(0, NSHeight(view.bounds))];
	[host.view reloadData];
	OAK_ASSERT_GE(NSMaxY(view.visibleRect), NSHeight(view.bounds) - 1);
}

static void permission_card_scrolls_into_view ()
{
	transcript_host_t host;
	NSMutableString* longText = [NSMutableString string];
	for(NSUInteger i = 0; i < 200; ++i)
		[longText appendFormat:@"Line %lu of a long reply.\n\n", i];
	host.reply(longText);
	[host.view scrollPoint:NSZeroPoint];

	[host.transcript applyUpdate:WriteToolCall(@"/project/new.py", @"pending")];
	[host.transcript addPermissionRequest:@{ @"toolCall": @{ @"toolCallId": @"w1" }, @"options": @[ @{ @"kind": @"allow_once", @"name": @"Yes", @"optionId": @"allow" }, @{ @"kind": @"reject_once", @"name": @"No", @"optionId": @"reject" } ] }];
	[host.transcript applyUpdate:@{ @"sessionUpdate": @"tool_call", @"toolCallId": @"w2", @"title": @"Write other.py", @"kind": @"edit", @"status": @"pending" }];
	for(AgentTranscriptItem* item in host.transcript.items)
		[host.view setNeedsDisplayItem:item];
	[host.view reloadData];

	NSString* text = host.view.textStorage.string;
	NSRange card = [text rangeOfString:@"Allow this action?"];
	NSRange yes  = [text rangeOfString:@"✓ Yes ↩" options:0 range:NSMakeRange(card.location, text.length - card.location)];
	NSRange diff = [text rangeOfString:@"+ print(1)"];
	OAK_ASSERT_NE(yes.location, NSNotFound);
	OAK_ASSERT_LT(diff.location, yes.location); // the question comes after what it’s about

	NSLayoutManager* layoutManager = host.view.layoutManager;
	NSRect rect = [layoutManager boundingRectForGlyphRange:[layoutManager glyphRangeForCharacterRange:yes actualCharacterRange:nullptr] inTextContainer:host.view.textContainer];
	rect = NSOffsetRect(rect, host.view.textContainerOrigin.x, host.view.textContainerOrigin.y);
	OAK_ASSERT(NSContainsRect(host.view.visibleRect, rect));
}

static void new_text_scrolls_up_only_at_the_end ()
{
	transcript_host_t host;
	NSMutableString* longText = [NSMutableString string];
	for(NSUInteger i = 0; i < 100; ++i)
		[longText appendFormat:@"Line %lu of a long reply.\n\n", i];
	AgentTranscriptItem* item = host.reply(longText);
	NSView* view = host.view;
	auto atEnd = [&](){ return NSMaxY(view.visibleRect) >= NSHeight(view.bounds) - 1; };

	[host.view scrollPoint:NSMakePoint(0, NSHeight(view.bounds))];
	OAK_ASSERT(atEnd());
	[host.transcript applyUpdate:@{ @"sessionUpdate": @"agent_message_chunk", @"content": @{ @"type": @"text", @"text": @"\n\nMore text\n\nand more\n\nand more." } }];
	[host.view setNeedsDisplayItem:item];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT(atEnd());

	// Scrolled up to read: stays there
	[host.view scrollPoint:NSZeroPoint];
	[host.transcript applyUpdate:@{ @"sessionUpdate": @"agent_message_chunk", @"content": @{ @"type": @"text", @"text": @"\n\nStill more." } }];
	[host.view setNeedsDisplayItem:item];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT_EQ(NSMinY(view.visibleRect), 0);
}

static void lone_move_shows_at_once_a_run_glides ()
{
	transcript_host_t host;
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	window.releasedWhenClosed = NO;
	[window.contentView addSubview:host.scrollView];

	NSMutableString* longText = [NSMutableString string];
	for(NSUInteger i = 0; i < 100; ++i)
		[longText appendFormat:@"Line %lu of a long reply.\n\n", i];
	AgentTranscriptItem* item = host.reply(longText);
	[host.view scrollPoint:NSMakePoint(0, NSHeight(host.view.bounds))];

	auto add = [&](){
		[host.transcript applyUpdate:@{ @"sessionUpdate": @"agent_message_chunk", @"content": @{ @"type": @"text", @"text": @"\n\nMore." } }];
		[host.view setNeedsDisplayItem:item];
		[host.view performSelector:@selector(flushPendingItems)];
	};
	auto atEnd = [&](){ return NSMaxY(host.view.visibleRect) >= NSHeight(host.view.bounds) - 1; };

	add();
	OAK_ASSERT(atEnd());
	if(!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion)
	{
		add();
		OAK_ASSERT(!atEnd()); // on its way
	}
	[host.scrollView removeFromSuperview];
}

static void room_for_reply_at_the_end ()
{
	transcript_host_t host;
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	window.releasedWhenClosed = NO;
	[window.contentView addSubview:host.scrollView];
	NSClipView* clipView = host.scrollView.contentView;

	NSMutableString* longText = [NSMutableString string];
	for(NSUInteger i = 0; i < 100; ++i)
		[longText appendFormat:@"Line %lu of a long reply.\n\n", i];
	AgentTranscriptItem* item = host.reply(longText);
	[host.view scrollPoint:NSMakePoint(0, NSHeight(host.view.bounds))];

	auto send = [&](){
		AgentTranscriptItem* user = [host.transcript addUserMessage:@"Next" attachmentNames:@[ ]];
		[host.view setNeedsDisplayItem:user];
		[host.view makeRoomForReply];
		[host.view performSelector:@selector(flushPendingItems)];
	};
	auto textEnd = [&](){ return NSMaxY([host.view.layoutManager usedRectForTextContainer:host.view.textContainer]); };

	// The end of the text is halfway up the panel
	send();
	CGFloat origin = NSMinY(clipView.bounds);
	OAK_ASSERT_LT(fabs(textEnd() - origin - NSHeight(clipView.bounds) / 2), 30);

	// A short reply prints into the room, and the text stays
	AgentTranscriptItem* reply = [host.transcript applyUpdate:@{ @"sessionUpdate": @"agent_message_chunk", @"content": @{ @"type": @"text", @"text": @"Short." } }];
	[host.view setNeedsDisplayItem:reply];
	[host.view performSelector:@selector(flushPendingItems)];
	OAK_ASSERT_EQ(NSMinY(clipView.bounds), origin);

	// Scrolled up it goes to the end all the same; near enough here to just show
	[host.view scrollPoint:NSMakePoint(0, NSMinY(clipView.bounds) - 200)];
	[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.45]]; // not one of a run of moves
	send();
	OAK_ASSERT_LT(fabs(textEnd() - NSMinY(clipView.bounds) - NSHeight(clipView.bounds) / 2), 30);
	(void)item;
	[host.scrollView removeFromSuperview];
}

static void reload_at_end_stays_at_end ()
{
	transcript_host_t host;
	NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	window.releasedWhenClosed = NO;
	[window.contentView addSubview:host.scrollView];

	NSMutableString* longText = [NSMutableString string];
	for(NSUInteger i = 0; i < 100; ++i)
		[longText appendFormat:@"Line %lu of a long reply.\n\n", i];
	host.reply(longText);
	[host.view scrollPoint:NSMakePoint(0, NSHeight(host.view.bounds))];

	// No glide up from the top, which the emptied text would start from
	[host.view reloadData];
	OAK_ASSERT(NSMaxY(host.view.visibleRect) >= NSHeight(host.view.bounds) - 1);
	[host.scrollView removeFromSuperview];
}

void test_code_blocks_start_folded_with_place () { RunOnMainThread(code_blocks_start_folded_with_place); }
void test_unfolded_code_block_shows_view () { RunOnMainThread(unfolded_code_block_shows_view); }
void test_fold_items () { RunOnMainThread(fold_items); }
void test_links_to_files_not_created_yet () { RunOnMainThread(links_to_files_not_created_yet); }
void test_permission_card_scrolls_into_view () { RunOnMainThread(permission_card_scrolls_into_view); }
void test_lone_move_shows_at_once_a_run_glides () { RunOnMainThread(lone_move_shows_at_once_a_run_glides); }
void test_room_for_reply_at_the_end () { RunOnMainThread(room_for_reply_at_the_end); }
void test_reload_at_end_stays_at_end () { RunOnMainThread(reload_at_end_stays_at_end); }
void test_new_text_scrolls_up_only_at_the_end () { RunOnMainThread(new_text_scrolls_up_only_at_the_end); }
void test_toggle_shows_or_folds_all_code_blocks () { RunOnMainThread(toggle_shows_or_folds_all_code_blocks); }
void test_toggle_folds_code_block_in_list () { RunOnMainThread(toggle_folds_code_block_in_list); }
void test_folds_and_opens_everything () { RunOnMainThread(folds_and_opens_everything); }
void test_new_items_follow_the_folding () { RunOnMainThread(new_items_follow_the_folding); }
void test_working_item_shows_its_status () { RunOnMainThread(working_item_shows_its_status); }
void test_working_status_update_before_flush () { RunOnMainThread(working_status_update_before_flush); }
void test_waiting_line_until_the_first_update () { RunOnMainThread(waiting_line_until_the_first_update); }
void test_diff_lines_are_rectangles () { RunOnMainThread(diff_lines_are_rectangles); }
void test_row_with_open_question_stays_open () { RunOnMainThread(row_with_open_question_stays_open); }
void test_permission_question_in_its_tool_row () { RunOnMainThread(permission_question_in_its_tool_row); }
void test_permission_without_tool_row_is_a_card () { RunOnMainThread(permission_without_tool_row_is_a_card); }
void test_stays_at_end_when_shorter () { RunOnMainThread(stays_at_end_when_shorter); }
void test_reload_keeps_scroll_position () { RunOnMainThread(reload_keeps_scroll_position); }
