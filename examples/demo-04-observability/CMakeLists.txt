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
# Why CMAKE_CXX_LINK_EXECUTABLE override below (G-23): r41 tried to
# wrap the libs in -Wl,--start-group / -Wl,--end-group by passing
# them as items in target_link_libraries. CMake reordered the link
# command such that BOTH linker flags ended up adjacent to each
# other BEFORE the library list — producing an empty group followed
# by an unwrapped library list. The result was a no-op: the linker
# fell back to standard left-to-right archive resolution, and
# libopentelemetry_proto_grpc.a (consumer) still ended up after
# libgrpc++.a (provider). The only reliable way to force --start-group
# /--end-group around <LINK_LIBRARIES> is to override the link
# command template itself, which is what the set() below does.
find_package(opentelemetry-cpp CONFIG REQUIRED)
find_package(Threads REQUIRED)

# Force --start-group/--end-group around all link libraries.
# Without this, Conan's CMakeDeps-generated link order leaves
# libopentelemetry_proto_grpc.a after libgrpc++.a, and the
# proto_grpc archive's references to grpc::Status::OK and
# grpc::GetGlobalCallbackHook() (and similar cross-archive
# symbols) go unresolved. With the group, ld iterates the
# wrapped archives until no more symbols can be resolved.
# This is the only mechanism that actually wraps <LINK_LIBRARIES>
# in CMake; the alternative (items inside target_link_libraries
# or LINK_OPTIONS) gets reordered by CMake into an empty group.
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

add_executable(demo-04-svc src/main.cpp)
target_include_directories(demo-04-svc PRIVATE src/third_party)
target_link_libraries(demo-04-svc PRIVATE
    opentelemetry-cpp::opentelemetry-cpp
    Threads::Threads
)
target_compile_options(demo-04-svc PRIVATE -O2 -DNDEBUG)

install(TARGETS demo-04-svc RUNTIME DESTINATION bin)
