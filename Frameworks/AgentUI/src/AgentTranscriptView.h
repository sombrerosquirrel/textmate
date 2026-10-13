#import "AgentTranscript.h"

// Renders an AgentTranscript in a single, selectable text view (TextKit 1, for
// text blocks and tables). Items are re-rendered in place as they change;
// streaming updates are coalesced. Actions (copy or insert a code block, open
// a file, expand thinking) are links handled by the view.

@class AgentTranscriptView;

@protocol AgentTranscriptViewDelegate <NSObject>
@optional
- (void)transcriptView:(AgentTranscriptView*)transcriptView insertCode:(NSString*)code;
- (void)transcriptView:(AgentTranscriptView*)transcriptView openFile:(NSString*)path line:(NSUInteger)line;
@end

@interface AgentTranscriptView : NSTextView
// Returns a scroll view whose document view is a new transcript view.
+ (NSScrollView*)scrollableTranscriptView;

@property (nonatomic) AgentTranscript* transcript;
@property (nonatomic, weak) id<AgentTranscriptViewDelegate> actionDelegate;
@property (nonatomic) NSString* emptyStateString; // shown while the transcript is empty

- (void)setNeedsDisplayItem:(AgentTranscriptItem*)item; // coalesced re-render
- (void)reloadData;                                       // re-render everything now
@end
