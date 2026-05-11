cmake_minimum_required(VERSION 3.25)
project(demo-02-stl-layout LANGUAGES CXX)

# Why CMAKE_CXX_STANDARD set per-target rather than from the
# profile: the same two-layer pattern demo-04 ended up using
# (G-27). The Conan profile may use a more conservative cppstd
# for dep builds (e.g., gnu17 for boost's older recipes), while
# we want our benchmark to use C++23 features like `std::span`,
# `std::expected`, ranges, and chrono literals.
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Hard-on optimization for a benchmark: -O3 + -march=native would
# tempt us, but -march=native bakes in CPU features that the
# container may not have at runtime (PRD calls out AVX-512
# mismatch as a §14 pitfall). Stick to portable -O3 + LTO.
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
add_compile_options(-O3 -DNDEBUG)

find_package(Boost CONFIG REQUIRED)
find_package(benchmark CONFIG REQUIRED)

add_executable(stl-bench src/main.cpp)
target_link_libraries(stl-bench PRIVATE
    benchmark::benchmark
    benchmark::benchmark_main
    boost::boost
)

install(TARGETS stl-bench RUNTIME DESTINATION bin)
