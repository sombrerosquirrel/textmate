#import "MarkdownPreviewDocument.h"

BOOL MarkdownPreviewIsMarkdownDocument (NSString* fileType, NSString* path)
{
	if([fileType hasPrefix:@"text.html.markdown"])
		return YES;
	static NSSet<NSString*>* const extensions = [NSSet setWithArray:@[ @"md", @"markdown", @"mdown", @"mkd", @"mkdn" ]];
	return [extensions containsObject:path.pathExtension.lowercaseString];
}

NSURL* MarkdownPreviewReadAccessURL (NSString* documentPath, NSString* projectPath)
{
	if(!documentPath)
		return nil;
	if(projectPath.length && [documentPath hasPrefix:[projectPath.stringByStandardizingPath stringByAppendingString:@"/"]])
		return [NSURL fileURLWithPath:projectPath isDirectory:YES];
	return [NSURL fileURLWithPath:documentPath.stringByDeletingLastPathComponent isDirectory:YES];
}
