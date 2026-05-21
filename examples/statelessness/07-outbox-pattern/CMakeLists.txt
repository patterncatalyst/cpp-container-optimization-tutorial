cmake_minimum_required(VERSION 3.25)
project(statelessness-07-outbox-pattern LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
add_compile_options(-O2 -DNDEBUG)

# Force --start-group/--end-group around static archives so the linker
# resolves circular deps among gRPC, protobuf, abseil (G-23). The system
# libpq and librdkafka are shared and unaffected by the grouping.
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> \
     <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

find_package(gRPC       CONFIG REQUIRED)
find_package(Protobuf   CONFIG REQUIRED)
find_package(absl       CONFIG REQUIRED)
find_package(PostgreSQL REQUIRED)             # system libpq
find_package(Threads    REQUIRED)
find_package(PkgConfig  REQUIRED)
pkg_check_modules(RDKAFKA REQUIRED IMPORTED_TARGET rdkafka)  # system librdkafka (C)

# ── gRPC codegen (order-svc + order-client only) ──
set(PROTO_FILE ${CMAKE_CURRENT_SOURCE_DIR}/proto/order.proto)
set(GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GENERATED_DIR})
set(PROTO_SRCS ${GENERATED_DIR}/order.pb.cc)
set(GRPC_SRCS  ${GENERATED_DIR}/order.grpc.pb.cc)

get_target_property(GRPC_CPP_PLUGIN_EXECUTABLE gRPC::grpc_cpp_plugin LOCATION)
get_target_property(PROTOC_EXECUTABLE protobuf::protoc LOCATION)

add_custom_command(
    OUTPUT ${PROTO_SRCS} ${GRPC_SRCS}
           ${GENERATED_DIR}/order.pb.h ${GENERATED_DIR}/order.grpc.pb.h
    COMMAND ${PROTOC_EXECUTABLE}
            --proto_path=${CMAKE_CURRENT_SOURCE_DIR}/proto
            --cpp_out=${GENERATED_DIR}
            --grpc_out=${GENERATED_DIR}
            --plugin=protoc-gen-grpc=${GRPC_CPP_PLUGIN_EXECUTABLE}
            ${PROTO_FILE}
    DEPENDS ${PROTO_FILE}
    COMMENT "Generating gRPC C++ code from order.proto"
    VERBATIM)

# ── producer: gRPC + libpq ──
add_executable(order-svc src/order_svc.cpp ${PROTO_SRCS} ${GRPC_SRCS})
target_include_directories(order-svc PRIVATE ${GENERATED_DIR} src)
target_link_libraries(order-svc PRIVATE
    gRPC::grpc++ gRPC::grpc++_reflection protobuf::libprotobuf
    PostgreSQL::PostgreSQL Threads::Threads)

# ── client: gRPC ──
add_executable(order-client src/client.cpp ${PROTO_SRCS} ${GRPC_SRCS})
target_include_directories(order-client PRIVATE ${GENERATED_DIR} src)
target_link_libraries(order-client PRIVATE
    gRPC::grpc++ protobuf::libprotobuf Threads::Threads)

# ── relay: libpq + librdkafka ──
add_executable(outbox-relay src/relay.cpp)
target_include_directories(outbox-relay PRIVATE src)
target_link_libraries(outbox-relay PRIVATE
    PostgreSQL::PostgreSQL PkgConfig::RDKAFKA Threads::Threads)

# ── consumer: libpq + librdkafka ──
add_executable(order-consumer src/consumer.cpp)
target_include_directories(order-consumer PRIVATE src)
target_link_libraries(order-consumer PRIVATE
    PostgreSQL::PostgreSQL PkgConfig::RDKAFKA Threads::Threads)

install(TARGETS order-svc order-client outbox-relay order-consumer
        RUNTIME DESTINATION bin)
