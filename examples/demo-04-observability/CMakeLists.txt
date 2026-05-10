cmake_minimum_required(VERSION 3.25)
project(demo-04-svc LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# OpenTelemetry C++ + transitive gRPC/protobuf/abseil come from Conan,
# pulled by `conan install` from Conan Center. The Containerfile invokes
# Conan before this CMake step and exports the dep set via
# CMakeDeps + CMakeToolchain. find_package() resolves against those
# generator outputs.
#
# Note on target name: we link the umbrella target
# `opentelemetry-cpp::opentelemetry-cpp` rather than the per-signal
# component targets (opentelemetry_trace, opentelemetry_metrics, etc.)
# Two reasons:
#   1) The umbrella's INTERFACE_LINK_LIBRARIES encodes correct
#      transitive ordering. Linking individual components produced
#      a link line where libopentelemetry_proto_grpc.a came AFTER
#      libgrpc++.a, so ld couldn't resolve grpc::Status::OK and
#      grpc::GetGlobalCallbackHook() from a later archive (G-21).
#   2) Conan's CMakeDeps generator literally suggests it in its
#      output: "target_link_libraries(... opentelemetry-cpp::opentelemetry-cpp)".
#
# The --start-group/--end-group wrapper is belt-and-suspenders for
# any remaining cross-archive ordering issues among the static libs
# the umbrella pulls in. Linker iterates until no more symbols
# resolve. Standard pattern for static-linkage cross-archive deps.
find_package(opentelemetry-cpp CONFIG REQUIRED)
find_package(Threads REQUIRED)

add_executable(demo-04-svc src/main.cpp)
target_include_directories(demo-04-svc PRIVATE src/third_party)
target_link_libraries(demo-04-svc PRIVATE
    -Wl,--start-group
    opentelemetry-cpp::opentelemetry-cpp
    -Wl,--end-group
    Threads::Threads
)
target_compile_options(demo-04-svc PRIVATE -O2 -DNDEBUG)

install(TARGETS demo-04-svc RUNTIME DESTINATION bin)
