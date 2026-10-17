#import "AgentConnection.h"

// The client side of ACP’s fs/read_text_file and fs/write_text_file for one
// project. Open documents come first, so the agent sees unsaved edits and its
// edits are undoable; other files are read from and written to disk. Paths
// outside the root directory (and additionalDirectories) are refused.
//
// Every write is recorded as an AgentFileChange so the user can review it,
// keep it, or undo it. Not thread-safe: use it on the session’s callback
// queue (the main queue in TextMate).

extern NSErrorDomain const AgentFileSystemErrorDomain;

typedef NS_ERROR_ENUM(AgentFileSystemErrorDomain, AgentFileSystemErrorCode) {
	AgentFileSystemErrorOutsideProject = 1,
	AgentFileSystemErrorNotFound       = 2,
	AgentFileSystemErrorNotText        = 3,
	AgentFileSystemErrorWriteFailed    = 4,
	AgentFileSystemErrorChangedSince   = 5, // the file changed after the agent’s last write
};

// Access to the editor’s open documents. Paths are absolute and standardized.
@protocol AgentDocumentProvider <NSObject>
// Text of the open document at `path`, including unsaved changes; nil if the file isn’t open.
- (NSString*)textOfOpenDocumentAtPath:(NSString*)path;
// Replaces the open document’s text as one undoable edit, leaving it unsaved. NO if the file isn’t open.
- (BOOL)replaceTextOfOpenDocumentAtPath:(NSString*)path withText:(NSString*)text;
@end

@interface AgentFileChange : NSObject
@property (nonatomic, readonly) NSString* path;
@property (nonatomic, readonly) NSString* originalText; // nil when the agent created the file
@property (nonatomic, readonly) NSString* currentText;  // text after the last write
@end

@class AgentFileSystem;

@protocol AgentFileSystemDelegate <NSObject>
@optional
// A change was added, updated, kept, or undone.
- (void)agentFileSystemDidChangeChanges:(AgentFileSystem*)fileSystem;
@end

@interface AgentFileSystem : NSObject
- (instancetype)initWithRootDirectory:(NSString*)rootDirectory;

@property (nonatomic, readonly) NSString* rootDirectory;
@property (nonatomic) NSArray<NSString*>* additionalDirectories;
@property (nonatomic, weak) id<AgentDocumentProvider> documentProvider;
@property (nonatomic, weak) id<AgentFileSystemDelegate> delegate;

- (BOOL)isPathAllowed:(NSString*)path;

// `line` is 1-based; 0 means from the start. `limit` 0 means no limit.
- (NSString*)readTextFileAtPath:(NSString*)path line:(NSUInteger)line limit:(NSUInteger)limit error:(NSError**)error;
- (BOOL)writeText:(NSString*)text toFileAtPath:(NSString*)path error:(NSError**)error;

// Handles fs/read_text_file and fs/write_text_file; replies with a JSON-RPC
// error for anything else.
- (void)handleRequest:(NSString*)method params:(NSDictionary*)params reply:(AgentReplyHandler)reply;

// Changes not yet kept or undone, in the order the files were first changed.
@property (nonatomic, readonly) NSArray<AgentFileChange*>* changes;
// Records an edit made by the user on the agent’s behalf (e.g. Apply in Editor).
- (void)recordChangeAtPath:(NSString*)path originalText:(NSString*)originalText currentText:(NSString*)currentText;
// The file’s text now, from the open document or disk; nil if it doesn’t exist.
- (NSString*)currentTextOfFileAtPath:(NSString*)path;
- (BOOL)hasFileChangedSinceChange:(AgentFileChange*)change;
- (void)keepChange:(AgentFileChange*)change;
- (void)keepAllChanges;
// Restores the original text (a created file is moved to the Trash). Fails
// with AgentFileSystemErrorChangedSince if the file changed after the
// agent’s write, unless `force` is YES.
- (BOOL)undoChange:(AgentFileChange*)change force:(BOOL)force error:(NSError**)error;
@end
