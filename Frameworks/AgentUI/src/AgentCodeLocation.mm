#import "AgentCodeLocation.h"

static NSUInteger const kMaximumStarts    = 500; // places to try for the first line
static NSUInteger const kSkippedLines     = 3;   // file lines a block may leave out without saying so
static NSUInteger const kElidedLines      = 2000;

static NSString* WithoutLineSuffix (NSString* str)
{
	NSRange suffix = [str rangeOfString:@":[0-9]+(-[0-9]+)?$" options:NSRegularExpressionSearch];
	return suffix.location == NSNotFound ? str : [str substringToIndex:suffix.location];
}

// “Sources/App.swift”, “main.cc”, “~/x/y.py:12” — not “e.g.”, “1.2.3”, URLs or directories
static NSString* PathInToken (NSString* token)
{
	token = [token stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"'`()[]<>,;:!?"]];
	while([token hasSuffix:@"."])
		token = [token substringToIndex:token.length - 1];
	token = WithoutLineSuffix(token);

	if(token.length < 3 || [token containsString:@"://"] || [token hasPrefix:@"."] && ![token hasPrefix:@"./"] && ![token hasPrefix:@"../"])
		return nil;
	if([token rangeOfString:@"^[A-Za-z0-9_./~+@-]+$" options:NSRegularExpressionSearch].location == NSNotFound)
		return nil;

	// A file name with an extension, not a version number or “e.g”
	if([token rangeOfString:@"^[a-z]\\.[a-z]$" options:NSRegularExpressionSearch].location != NSNotFound)
		return nil;
	return [token.lastPathComponent rangeOfString:@"^[A-Za-z0-9_+@-][A-Za-z0-9_.+@-]*\\.[A-Za-z][A-Za-z0-9]{0,11}$" options:NSRegularExpressionSearch].location != NSNotFound ? token : nil;
}

static void AddPath (NSMutableArray<NSString*>* paths, NSString* path)
{
	if(path && ![paths containsObject:path])
		[paths addObject:path];
}

static NSString* Trimmed (NSString* line)
{
	return [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

// Leading white space in columns, a tab counting 4
static NSUInteger Indent (NSString* line)
{
	NSUInteger res = 0;
	for(NSUInteger i = 0; i < line.length; ++i)
	{
		unichar ch = [line characterAtIndex:i];
		if(ch == ' ')
			res += 1;
		else if(ch == '\t')
			res += 4;
		else
			break;
	}
	return res;
}

// “...”, “…”, “// ... unchanged”, “# …”, “/* ... */”
static BOOL IsElision (NSString* trimmedLine)
{
	NSString* str = [trimmedLine stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/*#;-<!> \t"]];
	return [str hasPrefix:@"..."] || [str hasPrefix:@"…"];
}

@implementation AgentCodeLocation
+ (NSArray<NSString*>*)pathsInInfo:(NSString*)info
{
	NSMutableArray<NSString*>* res = [NSMutableArray array];
	if(!info.length)
		return res;

	NSRegularExpression* attribute = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:title|file|filename|path)=(?:\"([^\"]+)\"|'([^']+)'|(\\S+))" options:0 error:nil];
	for(NSTextCheckingResult* match in [attribute matchesInString:info options:0 range:NSMakeRange(0, info.length)])
	{
		for(NSUInteger group = 1; group <= 3; ++group)
		{
			if([match rangeAtIndex:group].location != NSNotFound)
				AddPath(res, WithoutLineSuffix([info substringWithRange:[match rangeAtIndex:group]]));
		}
	}

	NSArray<NSString*>* words = [info componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	for(NSUInteger i = 0; i < words.count; ++i)
	{
		NSString* word = words[i];
		if([word containsString:@"="])
			continue;

		// “objc:Frameworks/A.mm”
		NSString* path = PathInToken(word);
		NSRange colon = [word rangeOfString:@":"];
		if(!path && i == 0 && colon.location != NSNotFound && colon.location > 0)
			path = PathInToken([word substringFromIndex:NSMaxRange(colon)]);
		AddPath(res, path);
	}
	return res;
}

+ (NSArray<NSString*>*)pathsInText:(NSString*)precedingText
{
	NSMutableArray<NSString*>* res = [NSMutableArray array];
	NSArray<NSString*>* tokens = [precedingText componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	for(NSString* token in tokens.reverseObjectEnumerator)
		AddPath(res, PathInToken(token));
	return res;
}

+ (NSString*)textBeforeCode:(NSString*)code inMarkdown:(NSString*)markdown
{
	NSArray<NSString*>* lines = [markdown componentsSeparatedByString:@"\n"];
	NSString* const wanted = [Trimmed(code) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];

	NSUInteger textStart = 0; // first line after the previous block
	for(NSUInteger i = 0; i < lines.count; ++i)
	{
		NSString* fence = [Trimmed(lines[i]) hasPrefix:@"```"] ? @"```" : ([Trimmed(lines[i]) hasPrefix:@"~~~"] ? @"~~~" : nil);
		if(!fence)
			continue;

		NSUInteger end = i + 1;
		while(end < lines.count && ![Trimmed(lines[end]) hasPrefix:fence])
			++end;

		NSMutableArray<NSString*>* content = [NSMutableArray array];
		for(NSUInteger j = i + 1; j < end; ++j)
			[content addObject:Trimmed(lines[j])];
		NSMutableArray<NSString*>* codeLines = [NSMutableArray array];
		for(NSString* line in [wanted componentsSeparatedByString:@"\n"])
			[codeLines addObject:Trimmed(line)];

		if([[content componentsJoinedByString:@"\n"] isEqualToString:[codeLines componentsJoinedByString:@"\n"]])
		{
			// Up to three lines of text just before the fence
			NSMutableArray<NSString*>* before = [NSMutableArray array];
			for(NSUInteger j = i; j > textStart && before.count < 3; --j)
			{
				if(Trimmed(lines[j - 1]).length)
					[before insertObject:lines[j - 1] atIndex:0];
			}
			return [before componentsJoinedByString:@"\n"];
		}

		textStart = MIN(end + 1, lines.count);
		i = end;
	}
	return nil;
}

+ (NSRange)lineRangeOfCode:(NSString*)code inText:(NSString*)text
{
	NSRange const notFound = NSMakeRange(NSNotFound, 0);
	if(!code.length || !text.length)
		return notFound;

	NSMutableArray<NSString*>* codeLines = [NSMutableArray array]; // non-blank, trimmed
	NSMutableArray<NSNumber*>* elided    = [NSMutableArray array];
	NSMutableArray<NSNumber*>* indents   = [NSMutableArray array];
	NSUInteger significant = 0;
	for(NSString* line in [code componentsSeparatedByString:@"\n"])
	{
		NSString* trimmed = Trimmed(line);
		if(!trimmed.length)
			continue;
		BOOL elision = IsElision(trimmed);
		[codeLines addObject:trimmed];
		[elided addObject:@(elision)];
		[indents addObject:@(Indent(line))];
		if(!elision)
			++significant;
	}

	NSUInteger firstIndex = [elided indexOfObject:@NO];
	if(firstIndex == NSNotFound)
		return notFound;

	NSArray<NSString*>* fileLines = [text componentsSeparatedByString:@"\n"];
	NSMutableArray<NSString*>* trimmedFile = [NSMutableArray arrayWithCapacity:fileLines.count];
	NSMutableArray<NSNumber*>* fileIndents = [NSMutableArray arrayWithCapacity:fileLines.count];
	for(NSString* line in fileLines)
	{
		[trimmedFile addObject:Trimmed(line)];
		[fileIndents addObject:@(Indent(line))];
	}
	NSUInteger const n = trimmedFile.count;

	NSMutableArray<NSNumber*>* starts = [NSMutableArray array];
	for(NSUInteger i = 0; i < n && starts.count < kMaximumStarts; ++i)
	{
		if([trimmedFile[i] isEqualToString:codeLines[firstIndex]])
			[starts addObject:@(i)];
	}

	if(significant == 1)
		return starts.count == 1 ? NSMakeRange(starts[0].unsignedIntegerValue + 1, 1) : notFound;

	NSUInteger bestMatched = 0, bestStart = 0, bestLast = 0;
	for(NSNumber* startNumber in starts)
	{
		NSUInteger const start = startNumber.unsignedIntegerValue;
		NSUInteger last = start, matched = 1;
		BOOL afterElision = NO;
		for(NSUInteger k = firstIndex + 1; k < codeLines.count; ++k)
		{
			if(elided[k].boolValue)
			{
				afterElision = YES;
				continue;
			}

			// After left-out lines, a line indented as in the code (relative to
			// the first line) beats an earlier one that isn’t, e.g. for “}”
			NSInteger const wantedIndent = (NSInteger)indents[k].unsignedIntegerValue - (NSInteger)indents[firstIndex].unsignedIntegerValue + (NSInteger)fileIndents[start].unsignedIntegerValue;
			NSUInteger const limit = MIN(n, last + 1 + (afterElision ? kElidedLines : kSkippedLines + 1));
			NSUInteger found = NSNotFound;
			for(NSUInteger i = last + 1; i < limit; ++i)
			{
				if(![trimmedFile[i] isEqualToString:codeLines[k]])
					continue;
				if(found == NSNotFound)
					found = i;
				if(!afterElision || (NSInteger)fileIndents[i].unsignedIntegerValue == wantedIndent)
				{
					found = i;
					break;
				}
			}
			if(found != NSNotFound)
			{
				last = found;
				++matched;
				afterElision = NO;
			}
		}

		if(matched > bestMatched)
		{
			bestMatched = matched;
			bestStart   = start;
			bestLast    = last;
		}
	}

	if(bestMatched < 2 || 2 * bestMatched < significant)
		return notFound;
	return NSMakeRange(bestStart + 1, bestLast - bestStart + 1);
}
@end
