cmake_minimum_required(VERSION 3.25)
project(demo-bench LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(demo-bench src/main.cpp)
target_compile_options(demo-bench PRIVATE -O3 -DNDEBUG -fno-plt)

# Honor PMR / flat_set availability in libstdc++.
target_compile_definitions(demo-bench PRIVATE
    DEMO_BUILD_TYPE="${CMAKE_BUILD_TYPE}"
    DEMO_COMPILER="${CMAKE_CXX_COMPILER_ID}"
)

install(TARGETS demo-bench RUNTIME DESTINATION bin)
