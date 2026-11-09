#ifndef INLINE_PROMPT_FAKES_H_7Q2K
#define INLINE_PROMPT_FAKES_H_7Q2K

#import <AgentUI/AgentInlinePromptController.h>

// Records what the inline prompt asks its delegate to insert
@interface InlinePromptRecorder : NSObject <AgentInlinePromptDelegate>
@property (nonatomic) NSString* insertedText;
@property (nonatomic) BOOL replaced;
@property (nonatomic) NSMutableArray<NSNumber*>* modes;
@end

@implementation InlinePromptRecorder
- (void)inlinePrompt:(AgentInlinePromptController*)inlinePrompt submitText:(NSString*)text { }
- (void)inlinePromptStop:(AgentInlinePromptController*)inlinePrompt { }
- (void)inlinePrompt:(AgentInlinePromptController*)inlinePrompt answerPermission:(BOOL)allow { }
- (void)inlinePromptKeepChanges:(AgentInlinePromptController*)inlinePrompt { }
- (void)inlinePromptUndoChanges:(AgentInlinePromptController*)inlinePrompt { }
- (void)inlinePromptShowChat:(AgentInlinePromptController*)inlinePrompt { }
- (void)inlinePrompt:(AgentInlinePromptController*)inlinePrompt insertText:(NSString*)text mode:(AgentInlineInsertMode)mode
{
	_insertedText = text;
	_replaced     = mode == AgentInlineInsertReplacingSelection;
	if(!_modes)
		_modes = [NSMutableArray array];
	[_modes addObject:@(mode)];
}
@end

#endif
