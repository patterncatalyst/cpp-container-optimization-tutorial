cmake_minimum_required(VERSION 3.25)
project(demo07 LANGUAGES CXX VERSION 1.0.0)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---- the library ----
add_library(demo07_channel SHARED
    src/lib/channel.cpp
)
target_include_directories(demo07_channel PUBLIC
    $<BUILD_INTERFACE:${CMAKE_SOURCE_DIR}/src/include>
    $<INSTALL_INTERFACE:include>
)
set_target_properties(demo07_channel PROPERTIES
    VERSION   ${PROJECT_VERSION}
    SOVERSION ${PROJECT_VERSION_MAJOR}
)

# ---- service ----
add_executable(demo07-svc src/svc/main.cpp)
target_link_libraries(demo07-svc PRIVATE demo07_channel)

# ---- tests ----
option(BUILD_TESTING "Build the gtest suite" ON)
if(BUILD_TESTING)
    enable_testing()
    find_package(GTest CONFIG REQUIRED)
    add_executable(demo07_tests tests/test_channel.cpp)
    target_link_libraries(demo07_tests PRIVATE
        demo07_channel
        GTest::gtest
        GTest::gmock
        GTest::gtest_main
    )
    include(GoogleTest)
    gtest_discover_tests(demo07_tests)
endif()

install(TARGETS demo07_channel demo07-svc
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
    RUNTIME DESTINATION bin
)
install(DIRECTORY src/include/ DESTINATION include)
