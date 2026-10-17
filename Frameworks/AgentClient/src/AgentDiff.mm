#import "AgentDiff.h"
#include <regex.h> // xdiff.h uses regex_t
#include <xdiff.h>
#include <string>

@interface AgentDiffLine ()
@property (nonatomic, readwrite) AgentDiffLineKind kind;
@property (nonatomic, readwrite) NSString* text;
@property (nonatomic, readwrite) NSUInteger oldLine;
@property (nonatomic, readwrite) NSUInteger newLine;
@end

@implementation AgentDiffLine
@end

@interface AgentDiffHunk ()
@property (nonatomic, readwrite) NSUInteger oldStart;
@property (nonatomic, readwrite) NSUInteger oldCount;
@property (nonatomic, readwrite) NSUInteger newStart;
@property (nonatomic, readwrite) NSUInteger newCount;
@property (nonatomic, readwrite) NSMutableArray<AgentDiffLine*>* mutableLines;
@end

@implementation AgentDiffHunk
- (NSArray<AgentDiffLine*>*)lines { return [_mutableLines copy]; }
@end

namespace
{
	// xdiff emits each record as a prefix (“@@ … @@”, “ ”, “+”, “-”) plus the line
	int collect_output (void* priv, mmbuffer_t* mb, int nbuf)
	{
		std::string& out = *(std::string*)priv;
		for(int i = 0; i < nbuf; ++i)
			out.append(mb[i].ptr, mb[i].size);
		return 0;
	}

	// The unified diff of a and b, without ---/+++ headers
	std::string unified_diff (std::string a, std::string b, long contextLines)
	{
		// Without a trailing newline the last line would differ only by
		// “\ No newline at end of file”; treat both as ending in a newline
		if(!a.empty() && a.back() != '\n')
			a.push_back('\n');
		if(!b.empty() && b.back() != '\n')
			b.push_back('\n');

		mmfile_t mf_a, mf_b;
		mf_a.ptr  = a.empty() ? nullptr : &a[0];
		mf_a.size = (long)a.size();
		mf_b.ptr  = b.empty() ? nullptr : &b[0];
		mf_b.size = (long)b.size();

		xpparam_t xpp;
		memset(&xpp, 0, sizeof(xpp));
		xpp.flags = XDF_HISTOGRAM_DIFF;

		xdemitconf_t xec;
		memset(&xec, 0, sizeof(xec));
		xec.ctxlen = contextLines;

		std::string out;
		xdemitcb_t ecb;
		memset(&ecb, 0, sizeof(ecb));
		ecb.priv     = &out;
		ecb.out_line = collect_output;

		xdl_diff(&mf_a, &mf_b, &xpp, &xec, &ecb);
		return out;
	}
}

@implementation AgentDiff
{
	NSString* _body;
	NSMutableArray<AgentDiffHunk*>* _hunks;
}

+ (instancetype)diffWithOldText:(NSString*)oldText newText:(NSString*)newText contextLines:(NSUInteger)contextLines
{
	AgentDiff* diff = [[self alloc] init];
	std::string body = unified_diff(oldText ? std::string(oldText.UTF8String ?: "") : std::string(), std::string(newText.UTF8String ?: ""), (long)contextLines);
	[diff parseUnifiedDiff:[[NSString alloc] initWithBytes:body.data() length:body.size() encoding:NSUTF8StringEncoding] ?: @""];
	return diff;
}

- (void)parseUnifiedDiff:(NSString*)body
{
	_body  = body;
	_hunks = [NSMutableArray array];

	AgentDiffHunk* hunk;
	NSUInteger oldLine = 0, newLine = 0;
	for(NSString* line in [body componentsSeparatedByString:@"\n"])
	{
		if([line hasPrefix:@"@@"])
		{
			int oldStart = 0, oldCount = 1, newStart = 0, newCount = 1;
			if(sscanf(line.UTF8String, "@@ -%d,%d +%d,%d", &oldStart, &oldCount, &newStart, &newCount) < 4)
			{
				// Counts of 1 are left out: “@@ -3 +3,2 @@”
				oldCount = newCount = 1;
				if(sscanf(line.UTF8String, "@@ -%d +%d,%d", &oldStart, &newStart, &newCount) < 2)
					sscanf(line.UTF8String, "@@ -%d,%d +%d", &oldStart, &oldCount, &newStart);
			}

			hunk = [[AgentDiffHunk alloc] init];
			hunk.oldStart     = oldStart;
			hunk.oldCount     = oldCount;
			hunk.newStart     = newStart;
			hunk.newCount     = newCount;
			hunk.mutableLines = [NSMutableArray array];
			[_hunks addObject:hunk];

			// A count of 0 gives the line before the (empty) range
			oldLine = oldCount ? oldStart : oldStart + 1;
			newLine = newCount ? newStart : newStart + 1;
			continue;
		}

		if(!hunk || !line.length || [line hasPrefix:@"\\"])
			continue;

		AgentDiffLine* diffLine = [[AgentDiffLine alloc] init];
		diffLine.text = [line substringFromIndex:1];
		switch([line characterAtIndex:0])
		{
			case '+':
				diffLine.kind    = AgentDiffLineKindAdded;
				diffLine.newLine = newLine++;
				++_addedLineCount;
			break;
			case '-':
				diffLine.kind    = AgentDiffLineKindRemoved;
				diffLine.oldLine = oldLine++;
				++_removedLineCount;
			break;
			default:
				diffLine.kind    = AgentDiffLineKindContext;
				diffLine.oldLine = oldLine++;
				diffLine.newLine = newLine++;
			break;
		}
		[hunk.mutableLines addObject:diffLine];
	}
}

- (NSArray<AgentDiffHunk*>*)hunks
{
	return [_hunks copy];
}

- (BOOL)isEmpty
{
	return _hunks.count == 0;
}

- (NSString*)unifiedDiffWithOldName:(NSString*)oldName newName:(NSString*)newName
{
	return [NSString stringWithFormat:@"--- %@\n+++ %@\n%@", oldName, newName, _body];
}
@end
