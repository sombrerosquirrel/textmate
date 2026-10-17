#ifndef FAKE_DOCUMENT_PROVIDER_H_5A7D20
#define FAKE_DOCUMENT_PROVIDER_H_5A7D20

#import <AgentClient/AgentFileSystem.h>

// Open documents for the tests: path → text
@interface FakeDocumentProvider : NSObject <AgentDocumentProvider>
@property (nonatomic) NSMutableDictionary<NSString*, NSString*>* documents;
@end


@implementation FakeDocumentProvider
- (instancetype)init
{
	if(self = [super init])
		_documents = [NSMutableDictionary dictionary];
	return self;
}

- (NSString*)textOfOpenDocumentAtPath:(NSString*)path
{
	return _documents[path];
}

- (BOOL)replaceTextOfOpenDocumentAtPath:(NSString*)path withText:(NSString*)text
{
	if(!_documents[path])
		return NO;
	_documents[path] = text;
	return YES;
}
@end

#endif
