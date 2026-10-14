add_library(OakEditorPanels STATIC)
file(GLOB _src src/*.mm)
target_sources(OakEditorPanels PRIVATE ${_src})
textmate_framework(OakEditorPanels)
target_link_libraries(OakEditorPanels PUBLIC "-framework Cocoa")

textmate_add_tests(OakEditorPanels)
