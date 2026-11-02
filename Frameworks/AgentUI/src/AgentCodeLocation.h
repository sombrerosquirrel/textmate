// Where a code block in a reply sits: the files it may come from, and its
// lines in one of them.

@interface AgentCodeLocation : NSObject
// Paths named by a fence’s info string (“swift Sources/App.swift”,
// “objc:Frameworks/A.mm”, `python title="a/b.py"`, or just a path), then
// those named in `precedingText` (the text just before the block), the last
// named first. Line suffixes (“:12”, “:12-20”) are dropped.
+ (NSArray<NSString*>*)pathsInInfo:(NSString*)info;
+ (NSArray<NSString*>*)pathsInText:(NSString*)precedingText;

// Up to three lines of text before the fenced block in `markdown` whose
// content is `code`, nil if there is no such block.
+ (NSString*)textBeforeCode:(NSString*)code inMarkdown:(NSString*)markdown;

// The 1-based lines of `text` that `code` shows, { first line, number of
// lines }, or { NSNotFound, 0 }. Lines are compared without surrounding white
// space; blank lines are ignored, and lines such as “…” or “// ...” stand
// for left-out lines. At least half of the code’s lines must be found in
// order, and a one-line block only matches a line that occurs once.
+ (NSRange)lineRangeOfCode:(NSString*)code inText:(NSString*)text;
@end
