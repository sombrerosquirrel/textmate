add_library(AgentUI STATIC)
file(GLOB _src src/*.mm)
target_sources(AgentUI PRIVATE ${_src})
textmate_framework(AgentUI)
target_link_libraries(AgentUI PUBLIC AgentClient OakAppKit "-framework Cocoa")

textmate_add_tests(AgentUI)
