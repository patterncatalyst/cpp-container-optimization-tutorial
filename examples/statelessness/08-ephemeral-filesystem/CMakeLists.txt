cmake_minimum_required(VERSION 3.25)
project(statelessness-08-ephemeral-filesystem LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
add_compile_options(-O2 -DNDEBUG)

# One light dependency: spdlog (pulls fmt), both static. No gRPC chain,
# so no --start-group link override is needed.
find_package(spdlog CONFIG REQUIRED)

add_executable(app src/app.cpp)
target_link_libraries(app PRIVATE spdlog::spdlog)

install(TARGETS app RUNTIME DESTINATION bin)
