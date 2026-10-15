add_library(MarkdownPreview STATIC)
file(GLOB _src src/*.mm)
target_sources(MarkdownPreview PRIVATE ${_src})
textmate_framework(MarkdownPreview)
target_link_libraries(MarkdownPreview PUBLIC OakMarkdown "-framework Cocoa")

textmate_add_tests(MarkdownPreview)
