// A line above the prompt that’s always there, so the chat above it doesn’t
// move. While the agent works: a slowly blinking dot, what it’s doing, the time
// since the message was sent, and the turn’s tool calls and tokens. The dot
// stops blinking while the agent waits for an answer. After the turn: how it
// ended, with the same figures. Empty before the first message.

@interface AgentActivityView : NSView
@property (nonatomic, getter = isActive) BOOL active;   // starts the clock when set
@property (nonatomic, getter = isWaiting) BOOL waiting; // for the user, e.g. a permission card
@property (nonatomic) NSString* activity;               // “Thinking”, a tool call’s title, …
@property (nonatomic) NSUInteger toolCalls;
@property (nonatomic) double tokens;                    // used since the message was sent, 0 if unknown
@property (nonatomic) NSString* outcome;                // how the turn ended, “Done” unless set
@property (nonatomic, readonly) NSString* statusText;   // what the line says, after the dot

- (void)clear; // empties the line, e.g. for a new chat

+ (NSString*)stringFromTimeInterval:(NSTimeInterval)interval; // “0:42”, “1:05:03”
+ (NSString*)stringFromTokens:(double)count;                  // “950”, “1.2k”, “3.4M”
@end
