add_library(OakMarkdown STATIC)
file(GLOB _src src/*.mm)
target_sources(OakMarkdown PRIVATE ${_src})
textmate_framework(OakMarkdown)
target_link_libraries(OakMarkdown PUBLIC "-framework Cocoa")

textmate_add_tests(OakMarkdown)
