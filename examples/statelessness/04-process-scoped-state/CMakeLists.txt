cmake_minimum_required(VERSION 3.25)
project(statelessness-04-process-scoped-state LANGUAGES CXX)

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

set(PROTO_FILE ${CMAKE_CURRENT_SOURCE_DIR}/proto/state.proto)
set(GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GENERATED_DIR})

set(PROTO_SRCS ${GENERATED_DIR}/state.pb.cc)
set(PROTO_HDRS ${GENERATED_DIR}/state.pb.h)
set(GRPC_SRCS  ${GENERATED_DIR}/state.grpc.pb.cc)
set(GRPC_HDRS  ${GENERATED_DIR}/state.grpc.pb.h)

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
    COMMENT "Generating gRPC C++ code from state.proto"
    VERBATIM
)

add_executable(state-svc src/main.cpp ${PROTO_SRCS} ${GRPC_SRCS})
target_include_directories(state-svc PRIVATE ${GENERATED_DIR} src)
target_link_libraries(state-svc PRIVATE
    gRPC::grpc++ gRPC::grpc++_reflection protobuf::libprotobuf Threads::Threads)

add_executable(state-client src/client.cpp ${PROTO_SRCS} ${GRPC_SRCS})
target_include_directories(state-client PRIVATE ${GENERATED_DIR} src)
target_link_libraries(state-client PRIVATE
    gRPC::grpc++ protobuf::libprotobuf Threads::Threads)

install(TARGETS state-svc state-client RUNTIME DESTINATION bin)
