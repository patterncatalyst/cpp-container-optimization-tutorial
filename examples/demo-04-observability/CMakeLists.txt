cmake_minimum_required(VERSION 3.25)
project(demo-04-svc LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# OpenTelemetry C++ + transitive gRPC/protobuf/abseil come from Conan,
# pulled by `conan install` from Conan Center. The Containerfile invokes
# Conan before this CMake step and exports the dep set via
# CMakeDeps + CMakeToolchain. find_package() resolves against those
# generator outputs. See conanfile.txt for the recipe spec.
find_package(opentelemetry-cpp CONFIG REQUIRED)
find_package(Threads REQUIRED)

add_executable(demo-04-svc src/main.cpp)
target_include_directories(demo-04-svc PRIVATE src/third_party)
target_link_libraries(demo-04-svc PRIVATE
    opentelemetry-cpp::trace
    opentelemetry-cpp::metrics
    opentelemetry-cpp::logs
    opentelemetry-cpp::otlp_grpc_exporter
    opentelemetry-cpp::otlp_grpc_metrics_exporter
    opentelemetry-cpp::otlp_grpc_log_record_exporter
    Threads::Threads
)
target_compile_options(demo-04-svc PRIVATE -O2 -DNDEBUG)

install(TARGETS demo-04-svc RUNTIME DESTINATION bin)
