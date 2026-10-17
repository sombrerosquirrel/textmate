#import <AgentClient/AgentFileSystem.h>

// The files the agent changed in this chat, shown above the prompt like VS
// Code’s working set: each file with its +/− line counts and Diff, Keep and
// Undo, plus Keep All and Undo All. Hidden while there are no changes.

@class AgentChangesView;

@protocol AgentChangesViewDelegate <NSObject>
- (void)changesView:(AgentChangesView*)changesView openChange:(AgentFileChange*)change;
- (void)changesView:(AgentChangesView*)changesView showDiffOfChange:(AgentFileChange*)change;
- (void)changesView:(AgentChangesView*)changesView keepChanges:(NSArray<AgentFileChange*>*)changes;
- (void)changesView:(AgentChangesView*)changesView undoChanges:(NSArray<AgentFileChange*>*)changes;
@end

@interface AgentChangesView : NSView
@property (nonatomic, weak) id<AgentChangesViewDelegate> delegate;
@property (nonatomic) NSArray<AgentFileChange*>* changes;
@property (nonatomic) NSString* rootDirectory; // file names are shown relative to it
@end
