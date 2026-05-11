cmake_minimum_required(VERSION 3.25)
project(demo-03-io-uring-grpc LANGUAGES CXX)

# Per-target C++23 (the G-27 two-layer pattern). Profile is gnu17
# for dep builds; this overrides to C++23 for our own code.
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
add_compile_options(-O3 -DNDEBUG)

# Same CMAKE_CXX_LINK_EXECUTABLE override as demo-04 (G-23): force
# real --start-group/--end-group around static archive lists so the
# linker can resolve circular dependencies between gRPC, abseil, and
# their friends. Without this, target_link_libraries-injected groups
# get reordered away.
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> \
     <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

# ── Find Conan-managed deps ────────────────────────────────────────────

find_package(opentelemetry-cpp CONFIG REQUIRED)
find_package(gRPC             CONFIG REQUIRED)
find_package(Protobuf         CONFIG REQUIRED)
find_package(absl             CONFIG REQUIRED)
find_package(asio             CONFIG REQUIRED)
find_package(Threads          REQUIRED)

# liburing comes from the UBI 9 dnf install, not Conan. Use
# pkg-config to find it.
find_package(PkgConfig REQUIRED)
pkg_check_modules(URING REQUIRED IMPORTED_TARGET liburing)

# ── Generate gRPC + Protobuf sources from echo.proto ──────────────────
#
# Conan's gRPC recipe exposes the protoc + grpc_cpp_plugin executables
# as imported targets. We invoke them manually in a custom command
# rather than using the FetchContent or gRPC's own helper, because
# the helper has been flaky across recipe revisions (G-19).

set(PROTO_FILE ${CMAKE_CURRENT_SOURCE_DIR}/proto/echo.proto)
set(GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GENERATED_DIR})

set(PROTO_SRCS ${GENERATED_DIR}/echo.pb.cc)
set(PROTO_HDRS ${GENERATED_DIR}/echo.pb.h)
set(GRPC_SRCS  ${GENERATED_DIR}/echo.grpc.pb.cc)
set(GRPC_HDRS  ${GENERATED_DIR}/echo.grpc.pb.h)

get_target_property(GRPC_CPP_PLUGIN_EXECUTABLE
                    gRPC::grpc_cpp_plugin LOCATION)
get_target_property(PROTOC_EXECUTABLE
                    protobuf::protoc LOCATION)

add_custom_command(
    OUTPUT ${PROTO_SRCS} ${PROTO_HDRS} ${GRPC_SRCS} ${GRPC_HDRS}
    COMMAND ${PROTOC_EXECUTABLE}
            --proto_path=${CMAKE_CURRENT_SOURCE_DIR}/proto
            --cpp_out=${GENERATED_DIR}
            --grpc_out=${GENERATED_DIR}
            --plugin=protoc-gen-grpc=${GRPC_CPP_PLUGIN_EXECUTABLE}
            ${PROTO_FILE}
    DEPENDS ${PROTO_FILE}
    COMMENT "Generating gRPC C++ code from echo.proto"
    VERBATIM
)

# ── Server binary — main.cpp wires gRPC + io_uring + Asio echo ────────

add_executable(demo-03-svc
    src/main.cpp
    ${PROTO_SRCS} ${GRPC_SRCS}
)

target_include_directories(demo-03-svc PRIVATE
    ${GENERATED_DIR}
    src
)

# Asio standalone (not boost::asio); ASIO_STANDALONE tells it to
# avoid boost includes. ASIO_HAS_IO_URING activates the io_uring
# backend (requires liburing-devel at build time and liburing at
# runtime, both handled by the Containerfile).
target_compile_definitions(demo-03-svc PRIVATE
    ASIO_STANDALONE
    ASIO_HAS_IO_URING
    ASIO_DISABLE_EPOLL
)

# Same umbrella OTel-cpp library set as demo-04 plus gRPC + protobuf
# plus liburing for io_uring direct calls. CMAKE_CXX_LINK_EXECUTABLE
# above guarantees these are wrapped in --start-group/--end-group so
# the linker resolves them.
target_link_libraries(demo-03-svc PRIVATE
    opentelemetry-cpp::api
    opentelemetry-cpp::sdk
    opentelemetry-cpp::trace
    opentelemetry-cpp::metrics
    opentelemetry-cpp::logs
    opentelemetry-cpp::otlp_grpc_exporter
    opentelemetry-cpp::otlp_grpc_metrics_exporter
    opentelemetry-cpp::otlp_grpc_log_record_exporter
    gRPC::grpc++
    gRPC::grpc++_reflection
    protobuf::libprotobuf
    asio::asio
    PkgConfig::URING
    Threads::Threads
)

# ── Load-gen client binary — small TCP client used by demo.sh ─────────

add_executable(tcp-loadgen src/tcp_loadgen.cpp)
target_link_libraries(tcp-loadgen PRIVATE Threads::Threads)

install(TARGETS demo-03-svc tcp-loadgen RUNTIME DESTINATION bin)
