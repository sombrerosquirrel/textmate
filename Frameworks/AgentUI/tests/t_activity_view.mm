#import <AgentUI/AgentActivityView.h>

void test_time_interval_strings ()
{
	OAK_ASSERT_EQ(std::string([AgentActivityView stringFromTimeInterval:0].UTF8String), "0:00");
	OAK_ASSERT_EQ(std::string([AgentActivityView stringFromTimeInterval:42.7].UTF8String), "0:42");
	OAK_ASSERT_EQ(std::string([AgentActivityView stringFromTimeInterval:605].UTF8String), "10:05");
	OAK_ASSERT_EQ(std::string([AgentActivityView stringFromTimeInterval:3903].UTF8String), "1:05:03");
}

void test_status_text ()
{
	__block std::string blank, idle, working, waiting, done, stopped, cleared;
	__block BOOL hiddenWhenIdle = YES;
	dispatch_sync(dispatch_get_main_queue(), ^{
		AgentActivityView* view = [[AgentActivityView alloc] initWithFrame:NSZeroRect];
		hiddenWhenIdle = view.hidden;
		blank = std::string(view.statusText.UTF8String);

		view.active = YES;
		idle = std::string(view.statusText.UTF8String);

		view.activity  = @"Write geometry.py";
		view.toolCalls = 2;
		view.tokens    = 3200;
		working = std::string(view.statusText.UTF8String);

		view.waiting = YES;
		waiting = std::string(view.statusText.UTF8String);

		view.waiting = NO;
		view.active = NO;
		hiddenWhenIdle = hiddenWhenIdle || view.hidden;
		done = std::string(view.statusText.UTF8String);

		view.outcome = @"Stopped";
		stopped = std::string(view.statusText.UTF8String);

		[view clear];
		cleared = std::string(view.statusText.UTF8String);
	});
	OAK_ASSERT(!hiddenWhenIdle); // always there, so the chat doesn’t move
	OAK_ASSERT_EQ(blank, "");
	OAK_ASSERT_EQ(idle, "Working · 0:00");
	OAK_ASSERT_EQ(working, "Write geometry.py · 0:00 · 2 tool calls · +3.2k tokens");
	OAK_ASSERT_EQ(waiting, "Waiting for your approval · 0:00 · 2 tool calls · +3.2k tokens");
	OAK_ASSERT_EQ(done, "Done · 0:00 · 2 tool calls · +3.2k tokens");
	OAK_ASSERT_EQ(stopped, "Stopped · 0:00 · 2 tool calls · +3.2k tokens");
	OAK_ASSERT_EQ(cleared, "");
}
