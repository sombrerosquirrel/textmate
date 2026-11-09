#ifndef TRANSCRIPT_VIEW_FAKES_H_7Q2W
#define TRANSCRIPT_VIEW_FAKES_H_7Q2W

#import <AgentUI/AgentTranscriptView.h>

// A code view and a delegate for t_transcript_view (Objective-C classes must be
// declared outside the test runner’s functions)

@interface FakeCodeView : NSView <AgentCodeBlockView>
@property (nonatomic, copy) NSString* code;
@property (nonatomic) CGFloat fittingHeight;
@end

@implementation FakeCodeView
- (void)setCode:(NSString*)code // like OakCodeView, its height follows its code (as a reply streams)
{
	_code = [code copy];
	self.fittingHeight = 20 * [code componentsSeparatedByString:@"\n"].count;
}
@end

@interface FakeTranscriptDelegate : NSObject <AgentTranscriptViewDelegate>
@property (nonatomic) NSMutableArray<FakeCodeView*>* views;
@property (nonatomic) NSDictionary<NSString*, NSString*>* files; // absolute path → text
@property (nonatomic) NSString* openedPath;
@property (nonatomic) NSString* diffPath;
@property (nonatomic) NSString* diffNewText;
@end

@implementation FakeTranscriptDelegate
- (instancetype)init
{
	if(self = [super init])
		_views = [NSMutableArray array];
	return self;
}

- (NSView<AgentCodeBlockView>*)transcriptView:(AgentTranscriptView*)transcriptView viewForCode:(NSString*)code language:(NSString*)language
{
	FakeCodeView* view = [[FakeCodeView alloc] initWithFrame:NSZeroRect];
	view.code = code;
	[_views addObject:view];
	return view;
}

- (NSString*)transcriptView:(AgentTranscriptView*)transcriptView displayNameForLanguage:(NSString*)language
{
	return [language isEqualToString:@"objc"] ? @"Objective-C" : nil;
}

- (NSString*)transcriptView:(AgentTranscriptView*)transcriptView absolutePathForPath:(NSString*)path
{
	NSString* absolute = [path hasPrefix:@"/"] ? path : [@"/project" stringByAppendingPathComponent:path];
	return _files[absolute] ? absolute : nil;
}

- (NSString*)transcriptView:(AgentTranscriptView*)transcriptView textOfFileAtPath:(NSString*)path
{
	return _files[path];
}

- (void)transcriptView:(AgentTranscriptView*)transcriptView openFile:(NSString*)path line:(NSUInteger)line
{
	_openedPath = path;
}

- (void)transcriptView:(AgentTranscriptView*)transcriptView showDiffOfFile:(NSString*)path oldText:(NSString*)oldText newText:(NSString*)newText
{
	_diffPath    = path;
	_diffNewText = newText;
}
@end

#endif
