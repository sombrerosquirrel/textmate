// Smooth mapping between scroll positions, e.g. editor y → source line and
// source line → preview y, through anchor points known on both sides.
//
// Straight lines between anchors make the preview change speed abruptly at
// each anchor, which shows as stutter when scrolling slowly. A monotone cubic
// (Fritsch–Butland slopes) changes speed gradually and never moves backwards.

#ifndef MARKDOWNPREVIEW_INTERPOLATION_H_3F9A2C
#define MARKDOWNPREVIEW_INTERPOLATION_H_3F9A2C

#include <vector>
#include <utility>
#include <algorithm>

// `points` are (x, y) with x strictly increasing and y non-decreasing.
// Outside the points, y is clamped to the first or last.
inline CGFloat MarkdownPreviewInterpolate (std::vector<std::pair<CGFloat, CGFloat>> const& points, CGFloat x)
{
	if(points.empty())
		return 0;
	if(x <= points.front().first)
		return points.front().second;
	if(x >= points.back().first)
		return points.back().second;

	// points[k].x <= x < points[k+1].x
	auto next = std::upper_bound(points.begin(), points.end(), x, [](CGFloat x, std::pair<CGFloat, CGFloat> const& point){ return x < point.first; });
	size_t const k = std::distance(points.begin(), next) - 1;

	auto secant = [&](size_t i) -> CGFloat {
		return (points[i+1].second - points[i].second) / (points[i+1].first - points[i].first);
	};

	// The slope at a point: the harmonic mean of the secants on either side,
	// zero where either is flat, so the curve can’t overshoot
	auto slope = [&](size_t i) -> CGFloat {
		if(i == 0)
			return secant(0);
		if(i == points.size() - 1)
			return secant(i - 1);
		CGFloat before = secant(i - 1), after = secant(i);
		return before > 0 && after > 0 ? 2 * before * after / (before + after) : 0;
	};

	CGFloat const h  = points[k+1].first - points[k].first;
	CGFloat const t  = (x - points[k].first) / h;
	CGFloat const t2 = t * t, t3 = t2 * t;
	return (2*t3 - 3*t2 + 1) * points[k].second + (t3 - 2*t2 + t) * h * slope(k) + (-2*t3 + 3*t2) * points[k+1].second + (t3 - t2) * h * slope(k+1);
}

#endif /* end of include guard: MARKDOWNPREVIEW_INTERPOLATION_H_3F9A2C */
