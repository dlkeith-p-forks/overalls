# Portable native code shared by Mila's desktop runners: the v1 poke opener
# (mila-native-poke-open-v1) over Monocypher, with a CTest over the shared
# vectors. The Windows runner adds this directory; it also builds alone:
#
#   cmake -S mila/app/native -B build -DMILA_MONOCYPHER_DIR=<monocypher-4.0.3>
#   cmake --build build && ctest --test-dir build --output-on-failure
cmake_minimum_required(VERSION 3.14)
project(mila_native LANGUAGES C CXX)

set(MILA_MONOCYPHER_DIR "" CACHE PATH
  "Monocypher 4 source tree (the directory holding src/monocypher.c)")
if(NOT EXISTS "${MILA_MONOCYPHER_DIR}/src/monocypher.c")
  message(FATAL_ERROR "MILA_MONOCYPHER_DIR must name a Monocypher 4 source tree")
endif()

add_library(mila_monocypher STATIC "${MILA_MONOCYPHER_DIR}/src/monocypher.c")
target_include_directories(mila_monocypher PUBLIC "${MILA_MONOCYPHER_DIR}/src")

add_library(mila_poke STATIC
  "src/hkdf.cpp"
  "src/json.cpp"
  "src/poke_opener.cpp"
)
target_compile_features(mila_poke PUBLIC cxx_std_17)
target_include_directories(mila_poke PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(mila_poke PUBLIC mila_monocypher)
if(MSVC)
  target_compile_options(mila_poke PRIVATE /W4 /WX)
else()
  target_compile_options(mila_poke PRIVATE -Wall -Wextra -Werror)
endif()

option(MILA_NATIVE_TESTS "Build the poke opener's CTest" ON)
if(MILA_NATIVE_TESTS)
  enable_testing()
  add_executable(mila_poke_opener_test "test/poke_opener_test.cpp")
  target_link_libraries(mila_poke_opener_test PRIVATE mila_poke)
  get_filename_component(MILA_POKE_FIXTURES
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../protocol/test/fixtures/push_pokes.json" ABSOLUTE)
  add_test(NAME mila_poke_opener COMMAND mila_poke_opener_test "${MILA_POKE_FIXTURES}")
endif()
