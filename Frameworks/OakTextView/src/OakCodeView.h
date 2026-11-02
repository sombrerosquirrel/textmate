#import "OakTextView.h"

// A code snippet in a read-only OakTextView, e.g. a code block in the agent
// chat: highlighted by the grammar for `fileType`, no soft wrap (long lines
// scroll sideways) and no gutter. The view is meant to be as tall as the
// text (`fittingHeight`); vertical scrolling goes to the enclosing scroll
// view. Not opened as an editor document, so no language server or Copilot.

@interface OakCodeView : NSView
- (instancetype)initWithCode:(NSString*)code fileType:(NSString*)fileType;

@property (nonatomic, readonly) OakTextView* textView;
@property (nonatomic, copy) NSString* code;               // replaces the text, e.g. while a reply streams in
@property (nonatomic, readonly) CGFloat fittingHeight;    // the text’s height, plus a horizontal scroller if one is shown; KVO-observable
@end
