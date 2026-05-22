cmake_minimum_required(VERSION 3.25)
project(statelessness-09-health-checks LANGUAGES CXX)

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

# ── gRPC codegen for BOTH protos (echo + standard health) ──
set(GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GENERATED_DIR})

get_target_property(GRPC_CPP_PLUGIN_EXECUTABLE gRPC::grpc_cpp_plugin LOCATION)
get_target_property(PROTOC_EXECUTABLE protobuf::protoc LOCATION)

function(generate_grpc PROTO_NAME)
    set(PROTO_FILE ${CMAKE_CURRENT_SOURCE_DIR}/proto/${PROTO_NAME}.proto)
    add_custom_command(
        OUTPUT ${GENERATED_DIR}/${PROTO_NAME}.pb.cc
               ${GENERATED_DIR}/${PROTO_NAME}.pb.h
               ${GENERATED_DIR}/${PROTO_NAME}.grpc.pb.cc
               ${GENERATED_DIR}/${PROTO_NAME}.grpc.pb.h
        COMMAND ${PROTOC_EXECUTABLE}
                --proto_path=${CMAKE_CURRENT_SOURCE_DIR}/proto
                --cpp_out=${GENERATED_DIR}
                --grpc_out=${GENERATED_DIR}
                --plugin=protoc-gen-grpc=${GRPC_CPP_PLUGIN_EXECUTABLE}
                ${PROTO_FILE}
        DEPENDS ${PROTO_FILE}
        COMMENT "Generating gRPC C++ code from ${PROTO_NAME}.proto"
        VERBATIM)
endfunction()

generate_grpc(echo)
generate_grpc(health)

# ── server: gRPC + built-in default health service ──
add_executable(health-svc
    src/health_svc.cpp
    ${GENERATED_DIR}/echo.pb.cc
    ${GENERATED_DIR}/echo.grpc.pb.cc)
target_include_directories(health-svc PRIVATE ${GENERATED_DIR} src)
target_link_libraries(health-svc PRIVATE
    gRPC::grpc++ gRPC::grpc++_reflection protobuf::libprotobuf
    Threads::Threads)

# ── probe: our own grpc_health_probe, from health.proto ──
add_executable(health-probe
    src/health_probe.cpp
    ${GENERATED_DIR}/health.pb.cc
    ${GENERATED_DIR}/health.grpc.pb.cc)
target_include_directories(health-probe PRIVATE ${GENERATED_DIR} src)
target_link_libraries(health-probe PRIVATE
    gRPC::grpc++ protobuf::libprotobuf Threads::Threads)

install(TARGETS health-svc health-probe RUNTIME DESTINATION bin)
