#import "AgentDiffText.h"
#import <AgentClient/AgentDiff.h>

// NSTextBlock paints its background under its margin as well; this one starts
// at the text.
@interface AgentDiffTextBlock : NSTextBlock
@end

@implementation AgentDiffTextBlock
- (void)drawBackgroundWithFrame:(NSRect)frame inView:(NSView*)view characterRange:(NSRange)charRange layoutManager:(NSLayoutManager*)layoutManager
{
	CGFloat margin = [self widthForLayer:NSTextBlockMargin edge:NSMinXEdge];
	frame.origin.x   += margin;
	frame.size.width -= margin;
	[self.backgroundColor set];
	NSRectFillUsingOperation(frame, NSCompositingOperationSourceOver);
}
@end

NSUInteger AgentAppendDiffLines (NSMutableAttributedString* res, AgentDiff* diff, NSFont* font, CGFloat indent, NSUInteger maxLines)
{
	NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.firstLineHeadIndent = paragraph.headIndent = indent;

	NSUInteger shown = 0, total = 0;
	for(AgentDiffHunk* hunk in diff.hunks)
		total += hunk.lines.count;

	NSParagraphStyle* blockParagraph = nil;
	AgentDiffLineKind blockKind = AgentDiffLineKindContext;

	for(AgentDiffHunk* hunk in diff.hunks)
	{
		if(maxLines && shown >= maxLines)
			break;
		if(hunk != diff.hunks.firstObject)
			[res appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n⋯" attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.tertiaryLabelColor, NSParagraphStyleAttributeName: paragraph }]];

		for(AgentDiffLine* line in hunk.lines)
		{
			if(maxLines && shown >= maxLines)
				break;
			++shown;

			NSString* prefix = line.kind == AgentDiffLineKindAdded ? @"+ " : (line.kind == AgentDiffLineKindRemoved ? @"− " : @"  ");
			NSColor* background = line.kind == AgentDiffLineKindAdded ? [NSColor.systemGreenColor colorWithAlphaComponent:0.15] : (line.kind == AgentDiffLineKindRemoved ? [NSColor.systemRedColor colorWithAlphaComponent:0.15] : nil);
			if(background && line.kind != blockKind)
			{
				NSTextBlock* block = [[AgentDiffTextBlock alloc] init];
				block.backgroundColor = background;
				[block setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth];
				[block setWidth:indent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
				NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
				style.textBlocks = @[ block ];
				blockParagraph = style;
			}
			blockKind = line.kind;

			NSDictionary* attributes = @{
				NSFontAttributeName:            font,
				NSForegroundColorAttributeName: line.kind == AgentDiffLineKindContext ? NSColor.secondaryLabelColor : NSColor.labelColor,
				NSParagraphStyleAttributeName:  background ? blockParagraph : paragraph,
			};
			[res appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%@%@", prefix, line.text] attributes:attributes]];
		}
	}
	return total;
}
