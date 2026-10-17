add_library(AgentClient STATIC)
file(GLOB _src src/*.mm)
target_sources(AgentClient PRIVATE ${_src})
textmate_framework(AgentClient)
target_link_libraries(AgentClient PUBLIC xdiff "-framework Foundation")

textmate_add_tests(AgentClient)
