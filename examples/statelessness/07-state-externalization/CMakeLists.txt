cmake_minimum_required(VERSION 3.25)
project(statelessness-07-state-externalization LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
add_compile_options(-O2 -DNDEBUG)

# Force --start-group/--end-group around static archives so the linker
# resolves circular deps among gRPC, protobuf, abseil (G-23). libpqxx
# and libpq are added to the same group below.
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> \
     <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

find_package(gRPC     CONFIG REQUIRED)
find_package(Protobuf CONFIG REQUIRED)
find_package(absl     CONFIG REQUIRED)
find_package(libpqxx  CONFIG REQUIRED)
find_package(Threads  REQUIRED)

set(PROTO_FILE ${CMAKE_CURRENT_SOURCE_DIR}/proto/order.proto)
set(GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GENERATED_DIR})

set(PROTO_SRCS ${GENERATED_DIR}/order.pb.cc)
set(PROTO_HDRS ${GENERATED_DIR}/order.pb.h)
set(GRPC_SRCS  ${GENERATED_DIR}/order.grpc.pb.cc)
set(GRPC_HDRS  ${GENERATED_DIR}/order.grpc.pb.h)

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
    COMMENT "Generating gRPC C++ code from order.proto"
    VERBATIM
)

add_executable(order-svc src/main.cpp ${PROTO_SRCS} ${GRPC_SRCS})
target_include_directories(order-svc PRIVATE ${GENERATED_DIR} src)
target_link_libraries(order-svc PRIVATE
    gRPC::grpc++ gRPC::grpc++_reflection protobuf::libprotobuf
    libpqxx::pqxx Threads::Threads)

add_executable(order-client src/client.cpp ${PROTO_SRCS} ${GRPC_SRCS})
target_include_directories(order-client PRIVATE ${GENERATED_DIR} src)
target_link_libraries(order-client PRIVATE
    gRPC::grpc++ protobuf::libprotobuf Threads::Threads)

install(TARGETS order-svc order-client RUNTIME DESTINATION bin)
