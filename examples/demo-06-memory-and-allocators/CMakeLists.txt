cmake_minimum_required(VERSION 3.25)
project(demo-06-memory-and-allocators LANGUAGES CXX)

# C++23 for our app code (the gnu17 profile is for dependency builds —
# the G-27 two-layer pattern from demo-04).
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
add_compile_options(-O3 -DNDEBUG)

# ── Link-order wrapper for OTel + gRPC + protobuf + abseil (r85, G-23) ──
#
# opentelemetry-cpp's OTLP/gRPC exporter, gRPC itself, protobuf, and
# abseil have mutual circular symbol dependencies when linked
# statically. Without --start-group/--end-group bracketing, the
# linker makes a single pass over the .a files in the order CMake
# lists them, and any unresolved-then-resolved-then-needed-again
# cycle produces "undefined reference" errors.
#
# Override CMAKE_CXX_LINK_EXECUTABLE to wrap the entire
# <LINK_LIBRARIES> section in --start-group/--end-group. The linker
# re-scans the bracketed archives until no new unresolved symbols
# appear. Costs a few seconds on link; worth it for not chasing
# library-order trial-and-error.
#
# Coexistence with mimalloc's --whole-archive bracketing:
# --whole-archive is scoped to a specific archive (mimalloc-static)
# inside the target_link_libraries list. The outer --start-group is
# a re-scan directive for the whole library set. They compose
# correctly — the linker first parses the --whole-archive directive
# for the bracketed archive (pulling in every mimalloc symbol),
# then the --start-group/--end-group wraps the entire set for the
# resolution pass. Verified by demo-04 r28-r52 archaeology.
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

# Find Conan-managed deps.
find_package(mimalloc CONFIG REQUIRED)
find_package(Threads REQUIRED)

# OpenTelemetry C++ — r85 adds traces/metrics/logs export via
# OTLP/gRPC. The umbrella target `opentelemetry-cpp::opentelemetry-cpp`
# pulls in every OTel-cpp sub-target we use (trace, metrics, logs,
# otlp_grpc_exporter), plus all transitive gRPC/protobuf/abseil
# pieces. Resolved via G-19 in the gotcha catalog.
find_package(opentelemetry-cpp CONFIG REQUIRED)

# Shared sources — workload is independent of allocator choice.
# Each binary picks its allocator behavior at compile time via
# ALLOC_TYPE_* defines, plus (for mimalloc) link-time library
# replacement of the global new/delete via --whole-archive.
set(SHARED_SOURCES
    src/main.cpp
    src/workload.cpp
)

# ── Variant 1: std::allocator (default glibc malloc) ──────────────────
add_executable(demo06-svc-std ${SHARED_SOURCES})
target_compile_definitions(demo06-svc-std PRIVATE ALLOC_TYPE_STD)
target_include_directories(demo06-svc-std PRIVATE src src/third_party)
target_link_libraries(demo06-svc-std PRIVATE
    Threads::Threads
    opentelemetry-cpp::opentelemetry-cpp
)

# ── Variant 2: std::pmr (monotonic_buffer + synchronized_pool) ────────
add_executable(demo06-svc-pmr ${SHARED_SOURCES})
target_compile_definitions(demo06-svc-pmr PRIVATE ALLOC_TYPE_PMR)
target_include_directories(demo06-svc-pmr PRIVATE src src/third_party)
target_link_libraries(demo06-svc-pmr PRIVATE
    Threads::Threads
    opentelemetry-cpp::opentelemetry-cpp
)

# ── Variant 3: mimalloc static-linked ─────────────────────────────────
# mimalloc's static library installs a constructor that replaces
# global malloc/free/new/delete; the user doesn't need to call any
# mimalloc API. Target name from Conan recipe is `mimalloc-static`
# (flat, no `mimalloc::` namespace prefix — confirmed by Conan's
# 'Target declared' build output in r75).
#
# Static-lib constructor pull-in: `mimalloc-static` is an
# INTERFACE IMPORTED target (not a STATIC_LIBRARY target with a
# concrete file path), so we can't use $<TARGET_FILE:...> to get
# its archive path for --whole-archive bracketing. Instead, we
# put --whole-archive / --no-whole-archive directly into the
# target_link_libraries list bracketing the target. CMake passes
# these in order to the linker; the target name gets expanded to
# its underlying library paths in between the markers, forcing
# all symbols (including the mi_process_init constructor) to be
# pulled into the final binary.
add_executable(demo06-svc-mimalloc ${SHARED_SOURCES})
target_compile_definitions(demo06-svc-mimalloc PRIVATE ALLOC_TYPE_MIMALLOC)
target_include_directories(demo06-svc-mimalloc PRIVATE src src/third_party)
target_link_libraries(demo06-svc-mimalloc PRIVATE
    "-Wl,--whole-archive"
    mimalloc-static
    "-Wl,--no-whole-archive"
    Threads::Threads
    opentelemetry-cpp::opentelemetry-cpp
)

install(TARGETS
    demo06-svc-std demo06-svc-pmr demo06-svc-mimalloc
    RUNTIME DESTINATION bin
)
