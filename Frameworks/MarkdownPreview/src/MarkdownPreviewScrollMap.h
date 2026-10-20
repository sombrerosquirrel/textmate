// Maps the editor’s scroll position to the preview’s, through anchor points
// known on both sides: (editor y, preview y) where a source line starts.
//
// Straight lines between anchors keep the two aligned at every anchor, but a
// line that is much taller in the preview than in the editor (an image, or a
// paragraph that wraps more) makes the preview race through it. Averaging the
// straight lines over a window around the editor’s position spreads that
// over the window instead: the preview’s speed changes gradually and never
// goes backwards, and where the editor and preview have the same proportions
// the result is unchanged.

#ifndef MARKDOWNPREVIEW_SCROLL_MAP_H_7B1E4D
#define MARKDOWNPREVIEW_SCROLL_MAP_H_7B1E4D

#include <vector>
#include <utility>
#include <algorithm>
#include <cmath>

// `points` are (x, y) with x strictly increasing and y non-decreasing. Between
// points, y is linear in x; outside them, clamped to the first or last.
inline CGFloat MarkdownPreviewLinearMap (std::vector<std::pair<CGFloat, CGFloat>> const& points, CGFloat x)
{
	if(points.empty())
		return 0;
	if(x <= points.front().first)
		return points.front().second;
	if(x >= points.back().first)
		return points.back().second;

	auto next = std::upper_bound(points.begin(), points.end(), x, [](CGFloat x, std::pair<CGFloat, CGFloat> const& point){ return x < point.first; });
	auto const& [x0, y0] = *(next - 1);
	auto const& [x1, y1] = *next;
	return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
}

// The integral of the linear map from `a` to `b` (a <= b)
inline CGFloat MarkdownPreviewLinearMapIntegral (std::vector<std::pair<CGFloat, CGFloat>> const& points, CGFloat a, CGFloat b)
{
	if(points.empty() || b <= a)
		return 0;

	CGFloat res = 0;
	CGFloat const first = points.front().first, last = points.back().first;
	if(a < first)
		res += (std::min(b, first) - a) * points.front().second;
	if(b > last)
		res += (b - std::max(a, last)) * points.back().second;

	CGFloat const from = std::max(a, first), to = std::min(b, last);
	if(from < to)
	{
		auto it = std::upper_bound(points.begin(), points.end(), from, [](CGFloat x, std::pair<CGFloat, CGFloat> const& point){ return x < point.first; });
		CGFloat x = from, y = MarkdownPreviewLinearMap(points, from);
		for(; it != points.end() && it->first < to; ++it)
		{
			res += (it->first - x) * (y + it->second) / 2;
			x = it->first;
			y = it->second;
		}
		res += (to - x) * (y + MarkdownPreviewLinearMap(points, to)) / 2;
	}
	return res;
}

// The linear map averaged over [x - radius, x + radius]. The window shrinks
// near `lo` and `hi`, the ends of the scroll range, so they still map exactly.
inline CGFloat MarkdownPreviewSmoothMap (std::vector<std::pair<CGFloat, CGFloat>> const& points, CGFloat x, CGFloat radius, CGFloat lo, CGFloat hi)
{
	CGFloat const r = std::max<CGFloat>(0, std::min({ radius, x - lo, hi - x }));
	if(r < 0.5)
		return MarkdownPreviewLinearMap(points, x);
	return MarkdownPreviewLinearMapIntegral(points, x - r, x + r) / (2 * r);
}

// Jumps (e.g. Page Down in the editor) move towards the target by a part of
// the distance that depends on the time since the last frame, so they take
// the same time at any frame rate and slow down as they arrive. The same in
// the page script. Not used for scrolling: easing every step measured less
// even than following the editor exactly.
static CGFloat const kMarkdownPreviewEasingTime = 0.04; // seconds; the gap shrinks to 1/e in this time

inline CGFloat MarkdownPreviewEase (CGFloat current, CGFloat target, CGFloat elapsed)
{
	return target + (current - target) * std::exp(-std::max<CGFloat>(elapsed, 0) / kMarkdownPreviewEasingTime);
}

#endif /* end of include guard: MARKDOWNPREVIEW_SCROLL_MAP_H_7B1E4D */
