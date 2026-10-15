add_library(MarkdownPreview STATIC)
file(GLOB _src src/*.mm)
target_sources(MarkdownPreview PRIVATE ${_src})
textmate_framework(MarkdownPreview)
target_link_libraries(MarkdownPreview PUBLIC AgentClient OakFoundation OakMarkdown Preferences
  "-framework Cocoa" "-framework WebKit" "-framework UniformTypeIdentifiers")

textmate_add_tests(MarkdownPreview)
