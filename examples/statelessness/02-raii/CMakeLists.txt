cmake_minimum_required(VERSION 3.25)
project(statelessness-02-raii LANGUAGES CXX)

# Per-target C++23 (the G-27 two-layer pattern): the Conan profile
# builds dependencies as gnu17; our own code is C++23. std::pmr and
# std::memory_resource are the C++17/20 features this example leans on.
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
add_compile_options(-O2 -DNDEBUG)

# Force --start-group/--end-group around the static archive list so the
# linker resolves circular dependencies among gRPC, protobuf, and
# abseil (G-23, same as demo-03/demo-04).
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> \
     <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

# ── Conan-managed deps ─────────────────────────────────────────────────
# Lighter than demo-03: gRPC + protobuf + abseil only. No OTel, asio, or
# liburing — this example teaches RAII request scope, not observability
# or I/O.
find_package(gRPC     CONFIG REQUIRED)
find_package(Protobuf CONFIG REQUIRED)
find_package(absl     CONFIG REQUIRED)
find_package(Threads  REQUIRED)

# ── Generate gRPC + Protobuf sources from processor.proto ──────────────
set(PROTO_FILE ${CMAKE_CURRENT_SOURCE_DIR}/proto/processor.proto)
set(GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GENERATED_DIR})

set(PROTO_SRCS ${GENERATED_DIR}/processor.pb.cc)
set(PROTO_HDRS ${GENERATED_DIR}/processor.pb.h)
set(GRPC_SRCS  ${GENERATED_DIR}/processor.grpc.pb.cc)
set(GRPC_HDRS  ${GENERATED_DIR}/processor.grpc.pb.h)

get_target_property(GRPC_CPP_PLUGIN_EXECUTABLE gRPC::grpc_cpp_plugin LOCATION)
get_target_property(PROTOC_EXECUTABLE protobuf::protoc LOCATION)

add_custom_command(
    OUTPUT ${PROTO_SRCS} ${PROTO_HDRS} ${GRPC_SRCS} ${GRPC_HDRS}
    COMMAND ${PROTOC_EXECUTABLE}
            --proto_path=${CMAKE_CURRENT_SOURCE_DIR}/proto
            --cpp_out=${GENERATED_DIR}
            --grpc_out=${GENERATED_DIR}
            --plugin=protoc-gen-grpc=${GRPC_CPP_PLUGIN_EXECUTABLE}
            ${PROTO_FILE}
    DEPENDS ${PROTO_FILE}
    COMMENT "Generating gRPC C++ code from processor.proto"
    VERBATIM
)

# ── Server ─────────────────────────────────────────────────────────────
add_executable(raii-svc
    src/main.cpp
    ${PROTO_SRCS} ${GRPC_SRCS}
)
target_include_directories(raii-svc PRIVATE ${GENERATED_DIR} src)
target_link_libraries(raii-svc PRIVATE
    gRPC::grpc++
    gRPC::grpc++_reflection
    protobuf::libprotobuf
    Threads::Threads
)

# ── Client ─────────────────────────────────────────────────────────────
add_executable(raii-client
    src/client.cpp
    ${PROTO_SRCS} ${GRPC_SRCS}
)
target_include_directories(raii-client PRIVATE ${GENERATED_DIR} src)
target_link_libraries(raii-client PRIVATE
    gRPC::grpc++
    protobuf::libprotobuf
    Threads::Threads
)

install(TARGETS raii-svc raii-client RUNTIME DESTINATION bin)
