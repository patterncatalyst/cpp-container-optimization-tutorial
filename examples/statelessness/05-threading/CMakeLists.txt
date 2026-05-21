cmake_minimum_required(VERSION 3.25)
project(statelessness-05-threading LANGUAGES CXX)

# No external dependencies: this example is pure standard library plus
# reading /sys/fs/cgroup, so there's no Conan step and no gRPC chain —
# it builds in seconds.
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
add_compile_options(-O2 -DNDEBUG)

find_package(Threads REQUIRED)

add_executable(cpu-probe src/cpu_probe.cpp)
target_include_directories(cpu-probe PRIVATE src)
target_link_libraries(cpu-probe PRIVATE Threads::Threads)

add_executable(pool-bench src/pool_bench.cpp)
target_include_directories(pool-bench PRIVATE src)
target_link_libraries(pool-bench PRIVATE Threads::Threads)

install(TARGETS cpu-probe pool-bench RUNTIME DESTINATION bin)
