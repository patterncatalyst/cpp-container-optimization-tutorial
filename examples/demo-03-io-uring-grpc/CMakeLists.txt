cmake_minimum_required(VERSION 3.25)
project(demo03 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---- liburing for the echo_uring binary ----
find_library(URING_LIB uring REQUIRED)
find_path(URING_INCLUDE_DIR liburing.h REQUIRED)

add_executable(echo-uring src/echo_uring.cpp)
target_include_directories(echo-uring PRIVATE ${URING_INCLUDE_DIR})
target_link_libraries(echo-uring PRIVATE ${URING_LIB})
target_compile_options(echo-uring PRIVATE -O3 -DNDEBUG)

# ---- gRPC for the async server ----
# We rely on system-installed gRPC and protobuf (the Containerfile installs
# them via dnf). Using find_package(gRPC CONFIG) keeps this CMakeLists
# portable across distros that ship newer gRPC.
find_package(Protobuf REQUIRED)
find_package(gRPC CONFIG REQUIRED)

set(PROTO_SRC src/echo.proto)
set(GENERATED_DIR ${CMAKE_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GENERATED_DIR})

# Generate protobuf and gRPC stubs at configure time.
get_target_property(PROTOC_EXEC protobuf::protoc IMPORTED_LOCATION_RELEASE)
if(NOT PROTOC_EXEC)
    get_target_property(PROTOC_EXEC protobuf::protoc IMPORTED_LOCATION)
endif()
get_target_property(GRPC_CPP_PLUGIN gRPC::grpc_cpp_plugin IMPORTED_LOCATION_RELEASE)
if(NOT GRPC_CPP_PLUGIN)
    get_target_property(GRPC_CPP_PLUGIN gRPC::grpc_cpp_plugin IMPORTED_LOCATION)
endif()

add_custom_command(
    OUTPUT
        ${GENERATED_DIR}/echo.pb.cc
        ${GENERATED_DIR}/echo.pb.h
        ${GENERATED_DIR}/echo.grpc.pb.cc
        ${GENERATED_DIR}/echo.grpc.pb.h
    COMMAND ${PROTOC_EXEC}
            --proto_path=${CMAKE_SOURCE_DIR}/src
            --cpp_out=${GENERATED_DIR}
            --grpc_out=${GENERATED_DIR}
            --plugin=protoc-gen-grpc=${GRPC_CPP_PLUGIN}
            ${CMAKE_SOURCE_DIR}/${PROTO_SRC}
    DEPENDS ${PROTO_SRC}
)

add_executable(grpc-async-server
    src/grpc_async_server.cpp
    ${GENERATED_DIR}/echo.pb.cc
    ${GENERATED_DIR}/echo.grpc.pb.cc
)
target_include_directories(grpc-async-server PRIVATE ${GENERATED_DIR})
target_link_libraries(grpc-async-server PRIVATE
    gRPC::grpc++
    protobuf::libprotobuf
)
target_compile_options(grpc-async-server PRIVATE -O3 -DNDEBUG)

install(TARGETS echo-uring grpc-async-server RUNTIME DESTINATION bin)
