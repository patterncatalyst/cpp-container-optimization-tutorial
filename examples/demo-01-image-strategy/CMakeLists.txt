cmake_minimum_required(VERSION 3.25)
project(demo-svc LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# We use cpp-httplib's single-header form; vendored under src/third_party
# to keep this example hermetic and avoid network fetches inside the
# container build.
add_executable(demo-svc src/main.cpp)
target_include_directories(demo-svc PRIVATE src/third_party)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# Surface the toolchain identity in the binary itself; the demo prints
# this on /metrics so the comparison output is unambiguous.
target_compile_definitions(demo-svc PRIVATE
    DEMO_BUILD_TYPE="${CMAKE_BUILD_TYPE}"
    DEMO_COMPILER="${CMAKE_CXX_COMPILER_ID}"
    DEMO_COMPILER_VERSION="${CMAKE_CXX_COMPILER_VERSION}"
)

# Threads: cpp-httplib needs std::thread.
find_package(Threads REQUIRED)
target_link_libraries(demo-svc PRIVATE Threads::Threads)

install(TARGETS demo-svc RUNTIME DESTINATION bin)
