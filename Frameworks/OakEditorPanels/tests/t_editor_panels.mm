#import <OakEditorPanels/OakEditorPanelsView.h>

// The container adopts the editor once it has a superview, so each test hosts
// it in a plain 1000 × 600 view (non-flipped: y grows upwards)
struct host_t
{
	host_t (CGFloat editorMinWidth = 0)
	{
		editor = [[NSView alloc] initWithFrame:NSZeroRect];
		if(editorMinWidth)
		{
			NSLayoutConstraint* minWidth = [editor.widthAnchor constraintGreaterThanOrEqualToConstant:editorMinWidth];
			minWidth.active = YES;
		}

		container = [[OakEditorPanelsView alloc] initWithEditorView:editor];
		container.frame = NSMakeRect(0, 0, 1000, 600);
		host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 600)];
		[host addSubview:container];
	}

	OakEditorPanel* add (OakEditorPanelEdge edge, CGFloat size)
	{
		OakEditorPanel* panel = [[OakEditorPanel alloc] initWithView:[[NSView alloc] initWithFrame:NSZeroRect] edge:edge];
		panel.width  = size;
		panel.height = size;
		[container addPanel:panel];
		return panel;
	}

	void layout () { [container layoutSubtreeIfNeeded]; }

	NSView* host;
	NSView* editor;
	OakEditorPanelsView* container;
};

// Tests run on background threads, but AppKit layout must happen on the main thread
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

static bool Equal (NSRect lhs, NSRect rhs)
{
	if(NSEqualRects(lhs, rhs))
		return true;
	fprintf(stderr, "%s ≠ %s\n", NSStringFromRect(lhs).UTF8String, NSStringFromRect(rhs).UTF8String);
	return false;
}

static void editor_alone ()
{
	host_t h;
	h.layout();
	OAK_ASSERT(h.editor.superview == h.container);
	OAK_ASSERT(Equal(h.editor.frame, NSMakeRect(0, 0, 1000, 600)));
}

static void right_panel ()
{
	host_t h;
	OakEditorPanel* panel = h.add(OakEditorPanelEdgeRight, 300);
	h.layout();
	OAK_ASSERT(Equal(panel.view.frame, NSMakeRect(700, 0, 300, 600)));
	OAK_ASSERT(Equal(h.editor.frame,   NSMakeRect(0, 0, 699, 600)));

	panel.edge = OakEditorPanelEdgeLeft;
	h.layout();
	OAK_ASSERT(Equal(panel.view.frame, NSMakeRect(0, 0, 300, 600)));
	OAK_ASSERT(Equal(h.editor.frame,   NSMakeRect(301, 0, 699, 600)));

	[h.container removePanel:panel];
	h.layout();
	OAK_ASSERT(panel.view.superview == nil);
	OAK_ASSERT(Equal(h.editor.frame, NSMakeRect(0, 0, 1000, 600)));
}

static void top_and_bottom_panels ()
{
	host_t h;
	OakEditorPanel* top    = h.add(OakEditorPanelEdgeTop, 150);
	OakEditorPanel* bottom = h.add(OakEditorPanelEdgeBottom, 200);
	h.layout();
	OAK_ASSERT(Equal(top.view.frame,    NSMakeRect(0, 450, 1000, 150)));
	OAK_ASSERT(Equal(bottom.view.frame, NSMakeRect(0, 0, 1000, 200)));
	OAK_ASSERT(Equal(h.editor.frame,    NSMakeRect(0, 201, 1000, 248)));
}

static void bottom_panel_spans_editor_column ()
{
	host_t h;
	OakEditorPanel* chat    = h.add(OakEditorPanelEdgeRight, 300);
	OakEditorPanel* preview = h.add(OakEditorPanelEdgeBottom, 200);
	h.layout();
	OAK_ASSERT(Equal(chat.view.frame,    NSMakeRect(700, 0, 300, 600)));
	OAK_ASSERT(Equal(preview.view.frame, NSMakeRect(0, 0, 699, 200)));
	OAK_ASSERT(Equal(h.editor.frame,     NSMakeRect(0, 201, 699, 399)));
}

static void panels_on_both_sides ()
{
	host_t h;
	OakEditorPanel* preview = h.add(OakEditorPanelEdgeLeft, 250);
	OakEditorPanel* chat    = h.add(OakEditorPanelEdgeRight, 300);
	h.layout();
	OAK_ASSERT(Equal(preview.view.frame, NSMakeRect(0, 0, 250, 600)));
	OAK_ASSERT(Equal(chat.view.frame,    NSMakeRect(700, 0, 300, 600)));
	OAK_ASSERT(Equal(h.editor.frame,     NSMakeRect(251, 0, 448, 600)));
}

static void same_edge_outermost_first ()
{
	host_t h;
	OakEditorPanel* outer = h.add(OakEditorPanelEdgeRight, 300);
	OakEditorPanel* inner = h.add(OakEditorPanelEdgeRight, 200);
	h.layout();
	OAK_ASSERT(Equal(outer.view.frame, NSMakeRect(700, 0, 300, 600)));
	OAK_ASSERT(Equal(inner.view.frame, NSMakeRect(499, 0, 200, 600)));
	OAK_ASSERT(Equal(h.editor.frame,   NSMakeRect(0, 0, 498, 600)));
}

static void editor_minimum_wins ()
{
	host_t h(800);
	OakEditorPanel* panel = h.add(OakEditorPanelEdgeRight, 500);
	h.layout();
	OAK_ASSERT(Equal(h.editor.frame,   NSMakeRect(0, 0, 800, 600)));
	OAK_ASSERT(Equal(panel.view.frame, NSMakeRect(801, 0, 199, 600)));
}

static void minimum_size ()
{
	host_t h;
	OakEditorPanel* panel = h.add(OakEditorPanelEdgeRight, 50);
	h.layout();
	OAK_ASSERT_EQ(NSWidth(panel.view.frame), 200);

	panel.edge = OakEditorPanelEdgeBottom;
	h.layout();
	OAK_ASSERT_EQ(NSHeight(panel.view.frame), 100);
}

static void autosave_name ()
{
	NSString* name = [NSString stringWithFormat:@"editorPanelsTest%@", NSUUID.UUID.UUIDString];
	NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
	[defaults setDouble:420 forKey:[name stringByAppendingString:@"Width"]];

	OakEditorPanel* panel = [[OakEditorPanel alloc] initWithView:[[NSView alloc] initWithFrame:NSZeroRect] edge:OakEditorPanelEdgeLeft];
	panel.autosaveName = name;
	OAK_ASSERT_EQ(panel.width, 420);
	OAK_ASSERT_EQ(panel.height, 250); // nothing saved: the default

	[defaults removeObjectForKey:[name stringByAppendingString:@"Width"]];
}

void test_editor_alone () { RunOnMainThread(editor_alone); }
void test_right_panel () { RunOnMainThread(right_panel); }
void test_top_and_bottom_panels () { RunOnMainThread(top_and_bottom_panels); }
void test_bottom_panel_spans_editor_column () { RunOnMainThread(bottom_panel_spans_editor_column); }
void test_panels_on_both_sides () { RunOnMainThread(panels_on_both_sides); }
void test_same_edge_outermost_first () { RunOnMainThread(same_edge_outermost_first); }
void test_editor_minimum_wins () { RunOnMainThread(editor_minimum_wins); }
void test_minimum_size () { RunOnMainThread(minimum_size); }
void test_autosave_name () { RunOnMainThread(autosave_name); }
