#import "AgentTranscript.h"
#import <AgentClient/AgentTerminal.h>

// Renders an AgentTranscript in a single, selectable text view (TextKit 1, for
// text blocks and tables). Items are re-rendered in place as they change;
// streaming updates are coalesced. Actions (copy or insert a code block, open
// a file, fold an item) are links handled by the view.
//
// Items fold to one line (▾ / ▸). Each code block in a reply is a line with
// its language, length and place (the file and lines it shows, a link), and
// starts folded; unfolded, it shows an editor view from the delegate, kept
// in an attachment as tall as the code.

@class AgentTranscriptView;

// A read-only view of a code block, e.g. OakCodeView
@protocol AgentCodeBlockView <NSObject>
@property (nonatomic, copy) NSString* code;            // set while a reply streams in
@property (nonatomic, readonly) CGFloat fittingHeight; // KVO-observable
@end

@protocol AgentTranscriptViewDelegate <NSObject>
@optional
- (void)transcriptView:(AgentTranscriptView*)transcriptView insertCode:(NSString*)code;
- (void)transcriptView:(AgentTranscriptView*)transcriptView applyCode:(NSString*)code;
- (void)transcriptView:(AgentTranscriptView*)transcriptView openFile:(NSString*)path line:(NSUInteger)line;
// `oldText` nil: a new file.
- (void)transcriptView:(AgentTranscriptView*)transcriptView showDiffOfFile:(NSString*)path oldText:(NSString*)oldText newText:(NSString*)newText;
- (void)transcriptView:(AgentTranscriptView*)transcriptView selectPermissionOption:(NSString*)optionId forItem:(AgentTranscriptItem*)item;
// One of a notice’s or error’s actions was clicked.
- (void)transcriptView:(AgentTranscriptView*)transcriptView performAction:(NSString*)action forItem:(AgentTranscriptItem*)item;

// Code blocks: an editor view for unfolded blocks (nil: the block’s text),
// and a name for the fence’s language, e.g. “Objective-C++” for “objc”.
- (NSView<AgentCodeBlockView>*)transcriptView:(AgentTranscriptView*)transcriptView viewForCode:(NSString*)code language:(NSString*)language;
- (NSString*)transcriptView:(AgentTranscriptView*)transcriptView displayNameForLanguage:(NSString*)language;
// To find where a code block sits: the absolute path of an existing file for
// `path` (as written in a reply, e.g. relative to the project), its text
// (unsaved edits included), and the open documents, which are also searched.
- (NSString*)transcriptView:(AgentTranscriptView*)transcriptView absolutePathForPath:(NSString*)path;
- (NSString*)transcriptView:(AgentTranscriptView*)transcriptView textOfFileAtPath:(NSString*)path;
- (NSArray<NSString*>*)openFilePathsForTranscriptView:(AgentTranscriptView*)transcriptView;
@end

@interface AgentTranscriptView : NSTextView
// Returns a scroll view whose document view is a new transcript view.
+ (NSScrollView*)scrollableTranscriptView;

@property (nonatomic) AgentTranscript* transcript;
@property (nonatomic, weak) id<AgentTranscriptViewDelegate> actionDelegate;
@property (nonatomic) NSString* emptyStateString; // shown while the transcript is empty
@property (nonatomic) AgentTerminalManager* terminalManager; // output of tool calls with terminal content
// Whether code blocks show folded to their line; setting it applies to every
// block, also those clicked open or folded
@property (nonatomic) BOOL foldsCodeBlocks;
// Replies’ Markdown styled like GitHub’s instead of the built-in look; code
// blocks keep the editor’s theme either way
@property (nonatomic) BOOL usesGitHubStyle;
// Folds or opens everything with a ▾ / ▸: the items and their code blocks.
// Later replies’ code blocks follow, as with foldsCodeBlocks.
- (void)setAllFolded:(BOOL)flag;
// The item being worked on (nil: none): its marker blinks and its line shows
// the time and tokens since it started. `tokens` is the session’s total.
- (void)setWorkingItem:(AgentTranscriptItem*)item tokens:(double)tokens;
// The next update goes to the end of the chat, wherever it’s scrolled to, and
// leaves the end of the text halfway up the panel, so a reply prints into the
// room below without the text moving.
- (void)makeRoomForReply;

// Code blocks in replies, e.g. in the editor’s theme (see OakMarkdownStyle);
// re-renders the transcript.
- (void)setCodeBlockBackgroundColor:(NSColor*)backgroundColor textColor:(NSColor*)textColor highlighter:(NSAttributedString*(^)(NSString* code, NSString* language))highlighter;

- (void)setNeedsDisplayItem:(AgentTranscriptItem*)item; // coalesced re-render
- (void)reloadData;                                       // re-render everything now
@end
