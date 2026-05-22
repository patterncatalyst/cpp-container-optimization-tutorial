cmake_minimum_required(VERSION 3.25)
project(statelessness-10-grpc-microservices LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
add_compile_options(-O2 -DNDEBUG)

# Force --start-group/--end-group around static archives so the linker
# resolves circular deps among gRPC, protobuf, abseil (G-23). System libpq
# is shared and unaffected by the grouping.
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> \
     <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

find_package(gRPC       CONFIG REQUIRED)
find_package(Protobuf   CONFIG REQUIRED)
find_package(absl       CONFIG REQUIRED)
find_package(PostgreSQL REQUIRED)             # system libpq
find_package(Threads    REQUIRED)

# ── gRPC codegen for the three protos ──
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

generate_grpc(pricing)
generate_grpc(tax)
generate_grpc(health)

# ── pricing-svc: the capstone (gRPC + libpq; calls tax over gRPC) ──
add_executable(pricing-svc
    src/pricing_svc.cpp
    ${GENERATED_DIR}/pricing.pb.cc ${GENERATED_DIR}/pricing.grpc.pb.cc
    ${GENERATED_DIR}/tax.pb.cc     ${GENERATED_DIR}/tax.grpc.pb.cc)
target_include_directories(pricing-svc PRIVATE ${GENERATED_DIR} src)
target_link_libraries(pricing-svc PRIVATE
    gRPC::grpc++ gRPC::grpc++_reflection protobuf::libprotobuf
    PostgreSQL::PostgreSQL Threads::Threads)

# ── tax-svc: the outbound upstream ──
add_executable(tax-svc
    src/tax_svc.cpp
    ${GENERATED_DIR}/tax.pb.cc ${GENERATED_DIR}/tax.grpc.pb.cc)
target_include_directories(tax-svc PRIVATE ${GENERATED_DIR} src)
target_link_libraries(tax-svc PRIVATE
    gRPC::grpc++ gRPC::grpc++_reflection protobuf::libprotobuf
    Threads::Threads)

# ── health-probe: our minimal grpc_health_probe (from health.proto) ──
add_executable(health-probe
    src/health_probe.cpp
    ${GENERATED_DIR}/health.pb.cc ${GENERATED_DIR}/health.grpc.pb.cc)
target_include_directories(health-probe PRIVATE ${GENERATED_DIR} src)
target_link_libraries(health-probe PRIVATE
    gRPC::grpc++ protobuf::libprotobuf Threads::Threads)

# ── pricing-client: drives PriceOrder from the demo ──
add_executable(pricing-client
    src/pricing_client.cpp
    ${GENERATED_DIR}/pricing.pb.cc ${GENERATED_DIR}/pricing.grpc.pb.cc)
target_include_directories(pricing-client PRIVATE ${GENERATED_DIR} src)
target_link_libraries(pricing-client PRIVATE
    gRPC::grpc++ protobuf::libprotobuf Threads::Threads)

install(TARGETS pricing-svc tax-svc health-probe pricing-client RUNTIME DESTINATION bin)
