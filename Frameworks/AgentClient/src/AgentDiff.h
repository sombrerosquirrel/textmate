// Line diff of two texts (xdiff, histogram algorithm), for reviewing an
// agent’s edits: hunks with context, +/− counts, and unified diff text.

typedef NS_ENUM(NSInteger, AgentDiffLineKind) {
	AgentDiffLineKindContext = 0,
	AgentDiffLineKindAdded,
	AgentDiffLineKindRemoved,
};

@interface AgentDiffLine : NSObject
@property (nonatomic, readonly) AgentDiffLineKind kind;
@property (nonatomic, readonly) NSString* text;       // without the line ending
@property (nonatomic, readonly) NSUInteger oldLine;   // 1-based; 0 for added lines
@property (nonatomic, readonly) NSUInteger newLine;   // 1-based; 0 for removed lines
@end

@interface AgentDiffHunk : NSObject
@property (nonatomic, readonly) NSUInteger oldStart;
@property (nonatomic, readonly) NSUInteger oldCount;
@property (nonatomic, readonly) NSUInteger newStart;
@property (nonatomic, readonly) NSUInteger newCount;
@property (nonatomic, readonly) NSArray<AgentDiffLine*>* lines;
@end

@interface AgentDiff : NSObject
// `oldText` nil: a new file.
+ (instancetype)diffWithOldText:(NSString*)oldText newText:(NSString*)newText contextLines:(NSUInteger)contextLines;

@property (nonatomic, readonly) NSArray<AgentDiffHunk*>* hunks;
@property (nonatomic, readonly) NSUInteger addedLineCount;
@property (nonatomic, readonly) NSUInteger removedLineCount;
@property (nonatomic, readonly, getter = isEmpty) BOOL empty;

// `diff -u` style text with ---/+++ headers, e.g. for a diff document.
- (NSString*)unifiedDiffWithOldName:(NSString*)oldName newName:(NSString*)newName;
@end
