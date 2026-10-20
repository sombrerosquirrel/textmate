#import <MarkdownPreview/MarkdownPreviewScrollMap.h>

static std::vector<std::pair<CGFloat, CGFloat>> const kPoints = {
	{ 0, 0 }, { 10, 40 }, { 12, 42 }, { 30, 42 }, { 40, 100 }, { 41, 160 },
};

void test_linear_map_passes_through_points ()
{
	for(auto const& [x, y] : kPoints)
		OAK_ASSERT(fabs(MarkdownPreviewLinearMap(kPoints, x) - y) < 1e-9);

	OAK_ASSERT(fabs(MarkdownPreviewLinearMap(kPoints, 5) - 20) < 1e-9);
	OAK_ASSERT_EQ(MarkdownPreviewLinearMap(kPoints, -5), 0);
	OAK_ASSERT_EQ(MarkdownPreviewLinearMap(kPoints, 50), 160);
	OAK_ASSERT_EQ(MarkdownPreviewLinearMap({ }, 1), 0);
}

void test_integral ()
{
	// Triangle from 0 to 10, then a trapezoid from 10 to 12
	OAK_ASSERT(fabs(MarkdownPreviewLinearMapIntegral(kPoints, 0, 12) - (200 + 82)) < 1e-9);
	// Within one segment
	OAK_ASSERT(fabs(MarkdownPreviewLinearMapIntegral(kPoints, 2, 4) - 2 * 12) < 1e-9);
	// Outside the points, the ends are constant
	OAK_ASSERT(fabs(MarkdownPreviewLinearMapIntegral(kPoints, -10, 0)) < 1e-9);
	OAK_ASSERT(fabs(MarkdownPreviewLinearMapIntegral(kPoints, 41, 51) - 1600) < 1e-9);
	OAK_ASSERT_EQ(MarkdownPreviewLinearMapIntegral(kPoints, 5, 5), 0);
}

void test_smooth_map_unchanged_where_proportional ()
{
	std::vector<std::pair<CGFloat, CGFloat>> const points = { { 0, 0 }, { 100, 150 }, { 200, 300 }, { 300, 450 }, { 400, 600 } };
	for(CGFloat x = 0; x <= 400; x += 7)
		OAK_ASSERT(fabs(MarkdownPreviewSmoothMap(points, x, 50, 0, 400) - 1.5 * x) < 1e-9);
}

void test_smooth_map_ends_map_exactly ()
{
	OAK_ASSERT(fabs(MarkdownPreviewSmoothMap(kPoints, 0, 20, 0, 41)) < 1e-9);
	OAK_ASSERT(fabs(MarkdownPreviewSmoothMap(kPoints, 41, 20, 0, 41) - 160) < 1e-9);
}

void test_smooth_map_monotone ()
{
	CGFloat previous = -1;
	for(CGFloat x = 0; x <= 41; x += 0.01)
	{
		CGFloat y = MarkdownPreviewSmoothMap(kPoints, x, 8, 0, 41);
		OAK_ASSERT(y >= previous - 1e-9);
		previous = y;
	}
}

void test_smooth_map_spreads_tall_lines ()
{
	// One editor line of 20 pt is 400 pt in the preview (an image); elsewhere
	// both are the same. Straight lines would move the preview 20× faster
	// through it; averaged over a 200 pt window, at most about 3×.
	std::vector<std::pair<CGFloat, CGFloat>> const points = { { 0, 0 }, { 500, 500 }, { 520, 900 }, { 1500, 1880 } };
	CGFloat maxSpeed = 0;
	for(CGFloat x = 300; x < 700; x += 1)
		maxSpeed = std::max(maxSpeed, MarkdownPreviewSmoothMap(points, x + 1, 100, 0, 1500) - MarkdownPreviewSmoothMap(points, x, 100, 0, 1500));
	OAK_ASSERT(maxSpeed > 1 && maxSpeed < 3.5);

	// Away from it, aligned again
	OAK_ASSERT(fabs(MarkdownPreviewSmoothMap(points, 300, 100, 0, 1500) - 300) < 1e-9);
	OAK_ASSERT(fabs(MarkdownPreviewSmoothMap(points, 800, 100, 0, 1500) - 1180) < 1e-9);
}

void test_smooth_map_speed_changes_gradually ()
{
	// Where straight lines change speed from 1 to 4, the speed changes over the window
	std::vector<std::pair<CGFloat, CGFloat>> const points = { { 0, 0 }, { 100, 100 }, { 200, 500 }, { 300, 900 } };
	auto speed = [&](CGFloat x) { return MarkdownPreviewSmoothMap(points, x + 0.5, 20, 0, 300) - MarkdownPreviewSmoothMap(points, x - 0.5, 20, 0, 300); };
	for(CGFloat x = 60; x < 140; x += 1)
		OAK_ASSERT(fabs(speed(x + 1) - speed(x)) < 0.1);
}
