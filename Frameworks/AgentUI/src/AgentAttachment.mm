#import "AgentAttachment.h"

// Larger files are sent as links for the agent to read itself
static NSUInteger const kMaxEmbeddedFileSize = 512 * 1024;

static NSString* FileURI (NSString* path)
{
	return [NSURL fileURLWithPath:path].absoluteString;
}

@interface AgentAttachment ()
@property (nonatomic, readwrite) AgentAttachmentKind kind;
@property (nonatomic, readwrite) NSString* name;
@property (nonatomic, readwrite) NSString* path;
@property (nonatomic, readwrite) NSUInteger cursorLine;
@property (nonatomic, readwrite) NSUInteger cursorColumn;
@property (nonatomic) NSString* text;
@property (nonatomic) NSUInteger firstLine;
@property (nonatomic) NSUInteger lastLine;
@property (nonatomic) NSData* imageData;
@end

@implementation AgentAttachment
+ (instancetype)fileAttachmentWithPath:(NSString*)path text:(NSString*)text
{
	AgentAttachment* res = [[self alloc] init];
	res.kind = AgentAttachmentKindFile;
	res.path = path;
	res.name = path.lastPathComponent;
	res.text = text;
	return res;
}

+ (instancetype)fileAttachmentWithPath:(NSString*)path text:(NSString*)text cursorLine:(NSUInteger)line column:(NSUInteger)column
{
	AgentAttachment* res = [self fileAttachmentWithPath:path text:text];
	res.cursorLine   = line;
	res.cursorColumn = column;
	if(line)
		res.name = [NSString stringWithFormat:@"%@:%lu:%lu", res.name, line, column];
	return res;
}

+ (instancetype)selectionAttachmentWithPath:(NSString*)path displayName:(NSString*)displayName text:(NSString*)text firstLine:(NSUInteger)firstLine lastLine:(NSUInteger)lastLine
{
	AgentAttachment* res = [[self alloc] init];
	res.kind      = AgentAttachmentKindSelection;
	res.path      = path;
	res.text      = text ?: @"";
	res.firstLine = firstLine;
	res.lastLine  = lastLine;

	NSString* base = path.lastPathComponent ?: displayName ?: @"Selection";
	res.name = firstLine == lastLine ? [NSString stringWithFormat:@"%@:%lu", base, firstLine] : [NSString stringWithFormat:@"%@:%lu–%lu", base, firstLine, lastLine];
	return res;
}

+ (instancetype)imageAttachmentWithPNGData:(NSData*)data name:(NSString*)name
{
	AgentAttachment* res = [[self alloc] init];
	res.kind      = AgentAttachmentKindImage;
	res.name      = name ?: @"Image";
	res.imageData = data;
	return res;
}

- (NSString*)fileText
{
	if(_text)
		return _text;

	NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:_path error:nil];
	if(!attributes || [attributes fileSize] > kMaxEmbeddedFileSize)
		return nil;
	return [NSString stringWithContentsOfFile:_path encoding:NSUTF8StringEncoding error:nil];
}

- (NSDictionary*)contentBlockWithPromptCapabilities:(NSDictionary*)promptCapabilities
{
	BOOL embeddedContext = [promptCapabilities[@"embeddedContext"] boolValue];

	switch(_kind)
	{
		case AgentAttachmentKindFile:
		{
			NSString* text = embeddedContext ? [self fileText] : nil;
			if(text && text.length <= kMaxEmbeddedFileSize)
				return @{ @"type": @"resource", @"resource": @{ @"uri": FileURI(_path), @"text": text, @"mimeType": @"text/plain" } };
			return @{ @"type": @"resource_link", @"uri": FileURI(_path), @"name": _name };
		}

		case AgentAttachmentKindSelection:
		{
			if(embeddedContext)
			{
				NSString* uri = _path ? [NSString stringWithFormat:@"%@#L%lu-%lu", FileURI(_path), _firstLine, _lastLine] : [NSString stringWithFormat:@"untitled:%@", _name];
				return @{ @"type": @"resource", @"resource": @{ @"uri": uri, @"text": _text, @"mimeType": @"text/plain" } };
			}
			NSString* source = _path ?: _name;
			return @{ @"type": @"text", @"text": [NSString stringWithFormat:@"Selection from %@ (lines %lu–%lu):\n```\n%@\n```", source, _firstLine, _lastLine, _text] };
		}

		case AgentAttachmentKindImage:
		{
			if(![promptCapabilities[@"image"] boolValue] || !_imageData)
				return nil;
			return @{ @"type": @"image", @"mimeType": @"image/png", @"data": [_imageData base64EncodedStringWithOptions:0] };
		}
	}
	return nil;
}

- (NSArray<NSDictionary*>*)contentBlocksWithPromptCapabilities:(NSDictionary*)promptCapabilities
{
	NSDictionary* block = [self contentBlockWithPromptCapabilities:promptCapabilities];
	if(!block)
		return @[ ];
	if(!_cursorLine)
		return @[ block ];
	NSString* note = [NSString stringWithFormat:@"The cursor is at line %lu, column %lu of %@.", _cursorLine, _cursorColumn, _path];
	return @[ block, @{ @"type": @"text", @"text": note } ];
}

+ (NSArray<NSDictionary*>*)promptWithText:(NSString*)text attachments:(NSArray<AgentAttachment*>*)attachments promptCapabilities:(NSDictionary*)promptCapabilities
{
	return [self promptWithText:text attachments:attachments currentFile:nil promptCapabilities:promptCapabilities];
}

+ (NSArray<NSDictionary*>*)promptWithText:(NSString*)text attachments:(NSArray<AgentAttachment*>*)attachments currentFile:(AgentAttachment*)currentFile promptCapabilities:(NSDictionary*)promptCapabilities
{
	NSMutableArray* res = [NSMutableArray array];
	if(text.length)
		[res addObject:@{ @"type": @"text", @"text": text }];

	// Not needed when the current file is attached with its cursor, which says the same
	BOOL attachedWithCursor = NO;
	for(AgentAttachment* attachment in attachments)
	{
		[res addObjectsFromArray:[attachment contentBlocksWithPromptCapabilities:promptCapabilities]];
		if(attachment.kind == AgentAttachmentKindFile && attachment.cursorLine && [attachment.path isEqualToString:currentFile.path])
			attachedWithCursor = YES;
	}

	if(res.count && currentFile.path && !attachedWithCursor)
	{
		NSString* cursor = currentFile.cursorLine ? [NSString stringWithFormat:@", with the cursor at line %lu, column %lu", currentFile.cursorLine, currentFile.cursorColumn] : @"";
		NSString* note   = [NSString stringWithFormat:@"The user has %@ open in the editor%@. Unless they say otherwise, requests that don’t name a file refer to it, and text to add or insert goes at the cursor.", currentFile.path, cursor];
		[res addObject:@{ @"type": @"text", @"text": note }];
	}
	return res;
}
@end
