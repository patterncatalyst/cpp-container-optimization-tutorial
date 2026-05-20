cmake_minimum_required(VERSION 3.25)
project(statelessness-03-pmr LANGUAGES CXX)

# C++23 for our own code (the G-27 two-layer pattern). std::pmr is the
# star here: monotonic_buffer_resource, unsynchronized_pool_resource,
# the pmr container family.
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
add_compile_options(-O2 -DNDEBUG)

# Force --start-group/--end-group around static archives so the linker
# resolves circular deps among gRPC, protobuf, abseil (G-23).
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> \
     <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

find_package(gRPC     CONFIG REQUIRED)
find_package(Protobuf CONFIG REQUIRED)
find_package(absl     CONFIG REQUIRED)
find_package(Threads  REQUIRED)

# ── gRPC + Protobuf codegen ────────────────────────────────────────────
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
add_executable(pmr-svc src/main.cpp ${PROTO_SRCS} ${GRPC_SRCS})
target_include_directories(pmr-svc PRIVATE ${GENERATED_DIR} src)
target_link_libraries(pmr-svc PRIVATE
    gRPC::grpc++ gRPC::grpc++_reflection protobuf::libprotobuf Threads::Threads)

# ── Client ─────────────────────────────────────────────────────────────
add_executable(pmr-client src/client.cpp ${PROTO_SRCS} ${GRPC_SRCS})
target_include_directories(pmr-client PRIVATE ${GENERATED_DIR} src)
target_link_libraries(pmr-client PRIVATE
    gRPC::grpc++ protobuf::libprotobuf Threads::Threads)

# ── Standalone ASan trap binary ────────────────────────────────────────
# Built with AddressSanitizer and WITHOUT the project-wide -O2/-DNDEBUG
# or LTO, so the use-after-free is caught cleanly with a readable stack.
# It links no gRPC — it's a pure-C++ demonstration of the lifetime trap.
add_executable(pmr-trap src/pmr_trap.cpp)
set_target_properties(pmr-trap PROPERTIES
    INTERPROCEDURAL_OPTIMIZATION OFF)
target_compile_options(pmr-trap PRIVATE -O1 -g -fno-omit-frame-pointer -fsanitize=address)
# -static-libasan bakes the sanitizer runtime into the binary so the
# ubi-minimal runtime image needs no extra package to run it.
target_link_options(pmr-trap PRIVATE -fsanitize=address -static-libasan)

install(TARGETS pmr-svc pmr-client pmr-trap RUNTIME DESTINATION bin)
