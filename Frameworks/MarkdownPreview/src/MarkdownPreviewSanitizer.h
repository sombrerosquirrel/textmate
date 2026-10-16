// Filters HTML from cmark-gfm the way GitHub does when raw HTML isn’t allowed
// as written: tags on an allow-list (<b>, <kbd>, <details>, …) are kept with
// their safe attributes, other tags are removed and their text kept.
//
// Use it on output of `cmark-gfm --unsafe --extension tagfilter`: tagfilter
// already turns <script>, <style>, <iframe>, … into text.

// Links (href, src, cite) are kept only if relative or http(s)/mailto, and
// for images also data:image/… URLs. Checkboxes are always disabled.
NSString* MarkdownPreviewSanitizedHTML (NSString* html);
