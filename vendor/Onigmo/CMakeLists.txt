add_library(Onigmo STATIC)

# src/setup.c only contains a constructor (Unicode-aware \w, \b, [[:alpha:]],
# etc.), so nothing references it and the linker would drop it from the
# static archive. Put the object file directly on every consumer's link line.
add_library(Onigmo_setup OBJECT src/setup.c)
target_link_libraries(Onigmo INTERFACE $<TARGET_OBJECTS:Onigmo_setup>)
add_dependencies(Onigmo Onigmo_setup)

file(GLOB _enc
  vendor/enc/ascii.c
  vendor/enc/euc_jp.c
  vendor/enc/iso8859_1.c
  vendor/enc/sjis.c
  vendor/enc/unicode.c
  vendor/enc/utf*.c)
file(GLOB _vendor vendor/reg*.c vendor/st.c)

target_sources(Onigmo PRIVATE ${_enc} ${_vendor})

# Create symlink so <Onigmo/oniguruma.h> resolves
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/include")
if(NOT EXISTS "${CMAKE_CURRENT_BINARY_DIR}/include/Onigmo")
  file(CREATE_LINK
    "${CMAKE_CURRENT_SOURCE_DIR}/vendor"
    "${CMAKE_CURRENT_BINARY_DIR}/include/Onigmo"
    SYMBOLIC)
endif()
target_include_directories(Onigmo PUBLIC
  "${CMAKE_CURRENT_BINARY_DIR}/include")
target_include_directories(Onigmo PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/vendor")

target_compile_options(Onigmo PRIVATE
  $<$<COMPILE_LANGUAGE:C>:-Wno-incompatible-pointer-types>
  $<$<COMPILE_LANGUAGE:C>:-Wno-char-subscripts>)

textmate_add_tests(Onigmo)
