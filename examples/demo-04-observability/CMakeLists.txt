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
# Note on target names: Conan's opentelemetry-cpp recipe normalizes
# target names with an `opentelemetry_` prefix that doesn't appear in
# upstream OTel-cpp's own CMake config. Building OTel-cpp from source
# gives you `opentelemetry-cpp::trace`; getting it from Conan gives
# you `opentelemetry-cpp::opentelemetry_trace`. Same library, different
# target name. We use the Conan names because we're using Conan.
# See G-19 in the reconciliation plan.
find_package(opentelemetry-cpp CONFIG REQUIRED)
find_package(Threads REQUIRED)

add_executable(demo-04-svc src/main.cpp)
target_include_directories(demo-04-svc PRIVATE src/third_party)
target_link_libraries(demo-04-svc PRIVATE
    opentelemetry-cpp::opentelemetry_trace
    opentelemetry-cpp::opentelemetry_metrics
    opentelemetry-cpp::opentelemetry_logs
    opentelemetry-cpp::opentelemetry_exporter_otlp_grpc
    opentelemetry-cpp::opentelemetry_exporter_otlp_grpc_metrics
    opentelemetry-cpp::opentelemetry_exporter_otlp_grpc_log
    Threads::Threads
)
target_compile_options(demo-04-svc PRIVATE -O2 -DNDEBUG)

install(TARGETS demo-04-svc RUNTIME DESTINATION bin)
