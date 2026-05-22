cmake_minimum_required(VERSION 3.25)
project(statelessness-11-build-tooling LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
add_compile_options(-O2 -DNDEBUG -Wall -Wextra)

# ── vendored helpers as real static libraries (Doc 11) ──
add_library(cgroup_helper STATIC vendor/cgroup_helper/cgroup_helper.cpp)
target_include_directories(cgroup_helper PUBLIC vendor/cgroup_helper)

add_library(psi_reader STATIC vendor/psi_reader/psi_reader.cpp)
target_include_directories(psi_reader PUBLIC vendor/psi_reader)

# ── the demonstration binary ──
add_executable(helper-demo src/main.cpp)
target_link_libraries(helper-demo PRIVATE cgroup_helper psi_reader)

# ── the gtest suite (tests the pure parsers) ──
option(BUILD_TESTING "Build the gtest suite" ON)
if(BUILD_TESTING)
    enable_testing()
    find_package(GTest CONFIG REQUIRED)
    add_executable(helper-tests tests/test_helpers.cpp)
    target_link_libraries(helper-tests PRIVATE
        cgroup_helper psi_reader
        GTest::gtest GTest::gtest_main)
    include(GoogleTest)
    gtest_discover_tests(helper-tests)
endif()

install(TARGETS helper-demo helper-tests RUNTIME DESTINATION bin)
