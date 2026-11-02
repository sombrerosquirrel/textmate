// A diff’s lines as text, as the chat and the inline prompt show them: context
// lines dimmed, and each run of added or removed lines on one tinted rectangle,
// from the + or − to the edge, however its lines are indented. Hunks are
// separated by ⋯.

@class AgentDiff;

// Appends “\n” and the line for each diff line, indented by `indent`, stopping
// after `maxLines` (0: all). Returns the number of lines the diff has.
NSUInteger AgentAppendDiffLines (NSMutableAttributedString* res, AgentDiff* diff, NSFont* font, CGFloat indent, NSUInteger maxLines);
