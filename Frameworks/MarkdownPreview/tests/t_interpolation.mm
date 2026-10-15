#import <MarkdownPreview/MarkdownPreviewInterpolation.h>

static std::vector<std::pair<CGFloat, CGFloat>> const kPoints = {
	{ 0, 0 }, { 10, 40 }, { 12, 42 }, { 30, 42 }, { 40, 100 }, { 41, 160 },
};

void test_passes_through_points ()
{
	for(auto const& [x, y] : kPoints)
		OAK_ASSERT(fabs(MarkdownPreviewInterpolate(kPoints, x) - y) < 1e-9);

	OAK_ASSERT_EQ(MarkdownPreviewInterpolate(kPoints, -5), 0);
	OAK_ASSERT_EQ(MarkdownPreviewInterpolate(kPoints, 50), 160);
	OAK_ASSERT_EQ(MarkdownPreviewInterpolate({ }, 1), 0);
}

void test_monotone ()
{
	CGFloat previous = -1;
	for(CGFloat x = -1; x <= 42; x += 0.01)
	{
		CGFloat y = MarkdownPreviewInterpolate(kPoints, x);
		OAK_ASSERT(y >= previous - 1e-9);
		previous = y;
	}

	// Flat between equal points
	for(CGFloat x = 12; x <= 30; x += 0.5)
		OAK_ASSERT(fabs(MarkdownPreviewInterpolate(kPoints, x) - 42) < 1e-9);
}

void test_linear_for_even_points ()
{
	std::vector<std::pair<CGFloat, CGFloat>> const points = { { 1, 0 }, { 3, 30 }, { 5, 60 }, { 7, 90 } };
	for(CGFloat x = 1; x <= 7; x += 0.25)
		OAK_ASSERT(fabs(MarkdownPreviewInterpolate(points, x) - 15 * (x - 1)) < 1e-9);
}

void test_speed_changes_gradually ()
{
	// At an anchor where straight lines would change speed from 1 to 4, the
	// speed just before and just after it is the same
	std::vector<std::pair<CGFloat, CGFloat>> const points = { { 0, 0 }, { 10, 10 }, { 20, 50 }, { 30, 90 } };
	CGFloat const e = 1e-4;
	CGFloat before = (MarkdownPreviewInterpolate(points, 10) - MarkdownPreviewInterpolate(points, 10 - e)) / e;
	CGFloat after  = (MarkdownPreviewInterpolate(points, 10 + e) - MarkdownPreviewInterpolate(points, 10)) / e;
	OAK_ASSERT(fabs(before - after) < 0.01);
	OAK_ASSERT(before > 1 && before < 4);
}
