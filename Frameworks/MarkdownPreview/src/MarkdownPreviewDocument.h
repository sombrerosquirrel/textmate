// Which documents the preview renders, and which files their rendering may load.

// A Markdown grammar (scope text.html.markdown…), or for documents without
// one yet, a Markdown file extension.
BOOL MarkdownPreviewIsMarkdownDocument (NSString* fileType, NSString* path);

// The folder local files (images) may be loaded from: the project folder, or
// the document’s folder when it’s outside the project. Nil for untitled documents.
NSURL* MarkdownPreviewReadAccessURL (NSString* documentPath, NSString* projectPath);
