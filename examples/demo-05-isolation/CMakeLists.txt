cmake_minimum_required(VERSION 3.25)
project(demo05 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)

add_executable(tenant-a src/main.cpp)
target_compile_definitions(tenant-a PRIVATE TENANT_A=1)
target_include_directories(tenant-a PRIVATE src/third_party)
target_link_libraries(tenant-a PRIVATE Threads::Threads)
target_compile_options(tenant-a PRIVATE -O3 -DNDEBUG)

add_executable(tenant-b src/main.cpp)
target_compile_definitions(tenant-b PRIVATE TENANT_B=1)
target_link_libraries(tenant-b PRIVATE Threads::Threads)
target_compile_options(tenant-b PRIVATE -O3 -DNDEBUG)

install(TARGETS tenant-a tenant-b RUNTIME DESTINATION bin)
