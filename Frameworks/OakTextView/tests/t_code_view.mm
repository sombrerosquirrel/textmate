#import <OakTextView/OakCodeView.h>
#import <document/OakDocument.h>
#import <ns/ns.h>

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

static OakCodeView* CodeView (NSString* code)
{
	OakCodeView* view = [[OakCodeView alloc] initWithCode:code fileType:nil];
	view.frame = NSMakeRect(0, 0, 300, view.fittingHeight);
	[view layoutSubtreeIfNeeded];
	return view;
}

static void fitting_height_follows_lines ()
{
	OakCodeView* view = CodeView(@"one\ntwo\nthree");
	CGFloat const three = view.fittingHeight;
	OAK_ASSERT_LT(0, three);

	view.code = @"one\ntwo\nthree\nfour\nfive\nsix";
	OAK_ASSERT_LT(three, view.fittingHeight);
	OAK_ASSERT([view.textView.document.content isEqualToString:@"one\ntwo\nthree\nfour\nfive\nsix"]);

	view.code = @"one";
	OAK_ASSERT_LT(view.fittingHeight, three);
}

static void code_replaces_changed_part ()
{
	OakCodeView* view = CodeView(@"let a = “x”\n");
	view.code = @"let a = “x”\nlet b = “y”\n";
	OAK_ASSERT([view.textView.document.content isEqualToString:@"let a = “x”\nlet b = “y”\n"]);
	view.code = @"let a = “z”\nlet b = “y”\n";
	OAK_ASSERT([view.textView.document.content isEqualToString:@"let a = “z”\nlet b = “y”\n"]);
}

static void read_only_text_view ()
{
	OakCodeView* view = CodeView(@"abc\ndef");
	OakTextView* textView = view.textView;
	OAK_ASSERT(textView.isReadOnly);
	OAK_ASSERT(!textView.scrollPastEnd);

	[textView insertText:@"x"];
	[textView deleteBackward:nil];
	[textView insertNewline:nil];
	[textView performSelector:@selector(undo:) withObject:nil];
	OAK_ASSERT([textView.document.content isEqualToString:@"abc\ndef"]);

	[textView selectAll:nil];
	OAK_ASSERT(textView.hasSelection);
	OAK_ASSERT_EQ(to_s(textView.selectionString), "1-2:4");

	NSMenuItem* paste = [[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];
	NSMenuItem* copy  = [[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
	OAK_ASSERT(![(id<NSMenuItemValidation>)textView validateMenuItem:paste]);
	OAK_ASSERT([(id<NSMenuItemValidation>)textView validateMenuItem:copy]);
}

void test_fitting_height_follows_lines () { RunOnMainThread(fitting_height_follows_lines); }
void test_code_replaces_changed_part () { RunOnMainThread(code_replaces_changed_part); }
void test_read_only_text_view () { RunOnMainThread(read_only_text_view); }
