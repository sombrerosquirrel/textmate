#import "AgentFileSystem.h"

NSErrorDomain const AgentFileSystemErrorDomain = @"AgentFileSystemErrorDomain";

static NSInteger const kJSONRPCResourceNotFound = -32002; // ACP’s “resource not found”

static NSError* FileSystemError (AgentFileSystemErrorCode code, NSString* format, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError* FileSystemError (AgentFileSystemErrorCode code, NSString* format, ...)
{
	va_list ap;
	va_start(ap, format);
	NSString* description = [[NSString alloc] initWithFormat:format arguments:ap];
	va_end(ap);
	return [NSError errorWithDomain:AgentFileSystemErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: description }];
}

// Resolves symbolic links in the longest existing part of `path`, so a link
// inside the project can’t point the agent outside it
static NSString* ResolvedPath (NSString* path)
{
	NSString* existing = path;
	NSMutableArray<NSString*>* rest = [NSMutableArray array];
	while(existing.length > 1 && ![NSFileManager.defaultManager fileExistsAtPath:existing])
	{
		[rest insertObject:existing.lastPathComponent atIndex:0];
		existing = existing.stringByDeletingLastPathComponent;
	}

	char buf[PATH_MAX];
	NSString* res = realpath(existing.fileSystemRepresentation, buf) ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:buf length:strlen(buf)] : existing;
	for(NSString* component in rest)
		res = [res stringByAppendingPathComponent:component];
	return res;
}

static BOOL PathIsInsideDirectory (NSString* path, NSString* directory)
{
	if([path isEqualToString:directory] || [directory isEqualToString:@"/"])
		return YES;
	return [path hasPrefix:[directory stringByAppendingString:@"/"]];
}

// Lines [line, line + limit) of `text`, 1-based, keeping line endings
static NSString* LinesOfText (NSString* text, NSUInteger line, NSUInteger limit)
{
	if(line <= 1 && limit == 0)
		return text;

	NSUInteger first = line > 1 ? line - 1 : 0, current = 0, start = NSNotFound, end = text.length;
	if(first == 0)
		start = 0;
	for(NSUInteger i = 0; i < text.length; ++i)
	{
		if([text characterAtIndex:i] != '\n')
			continue;
		++current;
		if(current == first)
			start = i + 1;
		if(limit && start != NSNotFound && current == first + limit)
		{
			end = i + 1;
			break;
		}
	}
	return start == NSNotFound ? @"" : [text substringWithRange:NSMakeRange(start, end - start)];
}

@interface AgentFileChange ()
@property (nonatomic, readwrite) NSString* path;
@property (nonatomic, readwrite) NSString* originalText;
@property (nonatomic, readwrite) NSString* currentText;
@end

@implementation AgentFileChange
@end

@implementation AgentFileSystem
{
	NSString* _resolvedRootDirectory;
	NSMutableArray<AgentFileChange*>* _changes;
}

- (instancetype)initWithRootDirectory:(NSString*)rootDirectory
{
	if(self = [super init])
	{
		_rootDirectory         = rootDirectory.stringByStandardizingPath;
		_resolvedRootDirectory = ResolvedPath(_rootDirectory);
		_additionalDirectories = @[ ];
		_changes               = [NSMutableArray array];
	}
	return self;
}

- (NSArray<AgentFileChange*>*)changes
{
	return [_changes copy];
}

- (void)changesDidChange
{
	if([_delegate respondsToSelector:@selector(agentFileSystemDidChangeChanges:)])
		[_delegate agentFileSystemDidChangeChanges:self];
}

// =========
// = Paths =
// =========

- (BOOL)isPathAllowed:(NSString*)path
{
	if(![path isKindOfClass:[NSString class]] || ![path hasPrefix:@"/"])
		return NO;

	NSString* resolved = ResolvedPath(path.stringByStandardizingPath);
	if(PathIsInsideDirectory(resolved, _resolvedRootDirectory))
		return YES;
	for(NSString* directory in _additionalDirectories)
	{
		if(PathIsInsideDirectory(resolved, ResolvedPath(directory.stringByStandardizingPath)))
			return YES;
	}
	return NO;
}

- (NSString*)checkedPath:(NSString*)path error:(NSError**)error
{
	if(![path isKindOfClass:[NSString class]] || ![path hasPrefix:@"/"])
	{
		if(error)
			*error = FileSystemError(AgentFileSystemErrorOutsideProject, @"Path must be absolute: %@", path);
		return nil;
	}
	if(![self isPathAllowed:path])
	{
		if(error)
			*error = FileSystemError(AgentFileSystemErrorOutsideProject, @"TextMate doesn’t allow access outside the project folder (%@): %@", _rootDirectory, path);
		return nil;
	}
	return path.stringByStandardizingPath;
}

// ===================
// = Reading/Writing =
// ===================

- (NSString*)currentTextOfFileAtPath:(NSString*)path
{
	if(NSString* text = [_documentProvider textOfOpenDocumentAtPath:path])
		return text;
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nullptr];
}

- (NSString*)readTextFileAtPath:(NSString*)path line:(NSUInteger)line limit:(NSUInteger)limit error:(NSError**)error
{
	if(!(path = [self checkedPath:path error:error]))
		return nil;

	NSString* text = [_documentProvider textOfOpenDocumentAtPath:path];
	if(!text)
	{
		BOOL isDirectory = NO;
		if(![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory)
		{
			if(error)
				*error = FileSystemError(AgentFileSystemErrorNotFound, isDirectory ? @"Not a file: %@" : @"File not found: %@", path);
			return nil;
		}
		if(!(text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nullptr]))
		{
			if(error)
				*error = FileSystemError(AgentFileSystemErrorNotText, @"Not a UTF-8 text file: %@", path);
			return nil;
		}
	}
	return LinesOfText(text, line, limit);
}

- (BOOL)storeText:(NSString*)text atPath:(NSString*)path error:(NSError**)error
{
	if([_documentProvider replaceTextOfOpenDocumentAtPath:path withText:text])
		return YES;

	NSError* fsError;
	NSString* directory = path.stringByDeletingLastPathComponent;
	if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&fsError]
		// Not atomic: keeps the file’s permissions, owner and extended attributes
		|| ![[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path options:0 error:&fsError])
	{
		if(error)
			*error = FileSystemError(AgentFileSystemErrorWriteFailed, @"Unable to write %@: %@", path, fsError.localizedDescription);
		return NO;
	}
	return YES;
}

- (BOOL)writeText:(NSString*)text toFileAtPath:(NSString*)path error:(NSError**)error
{
	if(!(path = [self checkedPath:path error:error]))
		return NO;

	NSString* originalText = [self currentTextOfFileAtPath:path];
	if(![self storeText:text atPath:path error:error])
		return NO;

	[self recordChangeAtPath:path originalText:originalText currentText:text];
	return YES;
}

- (void)handleRequest:(NSString*)method params:(NSDictionary*)params reply:(AgentReplyHandler)reply
{
	NSDictionary* dict = [params isKindOfClass:[NSDictionary class]] ? params : @{ };
	NSString* path     = [dict[@"path"] isKindOfClass:[NSString class]] ? dict[@"path"] : nil;

	NSError* error;
	id result;
	if([method isEqualToString:@"fs/read_text_file"])
	{
		NSUInteger line  = [dict[@"line"] isKindOfClass:[NSNumber class]] ? MAX([dict[@"line"] integerValue], 0) : 0;
		NSUInteger limit = [dict[@"limit"] isKindOfClass:[NSNumber class]] ? MAX([dict[@"limit"] integerValue], 0) : 0;
		if(NSString* content = [self readTextFileAtPath:path line:line limit:limit error:&error])
			result = @{ @"content": content };
	}
	else if([method isEqualToString:@"fs/write_text_file"])
	{
		NSString* content = [dict[@"content"] isKindOfClass:[NSString class]] ? dict[@"content"] : nil;
		if(!content)
			error = [NSError errorWithDomain:AgentJSONRPCErrorDomain code:AgentJSONRPCErrorInvalidParams userInfo:@{ NSLocalizedDescriptionKey: @"Missing content" }];
		else if([self writeText:content toFileAtPath:path error:&error])
			result = @{ };
	}
	else
	{
		error = [NSError errorWithDomain:AgentJSONRPCErrorDomain code:AgentJSONRPCErrorMethodNotFound userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Method not found: %@", method] }];
	}

	if([error.domain isEqualToString:AgentFileSystemErrorDomain] && error.code == AgentFileSystemErrorNotFound)
		error = [NSError errorWithDomain:AgentJSONRPCErrorDomain code:kJSONRPCResourceNotFound userInfo:error.userInfo];
	reply(result, error);
}

// ===========
// = Changes =
// ===========

- (AgentFileChange*)changeAtPath:(NSString*)path
{
	for(AgentFileChange* change in _changes)
	{
		if([change.path isEqualToString:path])
			return change;
	}
	return nil;
}

- (void)recordChangeAtPath:(NSString*)path originalText:(NSString*)originalText currentText:(NSString*)currentText
{
	AgentFileChange* change = [self changeAtPath:path];
	if(!change)
	{
		change = [[AgentFileChange alloc] init];
		change.path         = path;
		change.originalText = originalText;
		[_changes addObject:change];
	}
	change.currentText = currentText;

	// Written back to how it was: nothing left to review
	if([change.currentText isEqualToString:change.originalText])
		[_changes removeObject:change];
	[self changesDidChange];
}

- (BOOL)hasFileChangedSinceChange:(AgentFileChange*)change
{
	NSString* text = [self currentTextOfFileAtPath:change.path];
	return text != change.currentText && ![text isEqualToString:change.currentText];
}

- (void)keepChange:(AgentFileChange*)change
{
	[_changes removeObject:change];
	[self changesDidChange];
}

- (void)keepAllChanges
{
	[_changes removeAllObjects];
	[self changesDidChange];
}

- (BOOL)undoChange:(AgentFileChange*)change force:(BOOL)force error:(NSError**)error
{
	if(!force && [self hasFileChangedSinceChange:change])
	{
		if(error)
			*error = FileSystemError(AgentFileSystemErrorChangedSince, @"%@ has changed since the agent edited it.", change.path.lastPathComponent);
		return NO;
	}

	if(change.originalText)
	{
		if(![self storeText:change.originalText atPath:change.path error:error])
			return NO;
	}
	else if([NSFileManager.defaultManager fileExistsAtPath:change.path])
	{
		NSError* fsError;
		if(![NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:change.path] resultingItemURL:nil error:&fsError])
		{
			if(error)
				*error = FileSystemError(AgentFileSystemErrorWriteFailed, @"Unable to move %@ to the Trash: %@", change.path, fsError.localizedDescription);
			return NO;
		}
	}

	[_changes removeObject:change];
	[self changesDidChange];
	return YES;
}
@end
