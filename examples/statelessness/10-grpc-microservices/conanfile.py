"""statelessness/10-grpc-microservices Conan recipe (Conan 2.x).

The capstone. Dependency set is the verified gRPC trio — gRPC + protobuf +
abseil (G-22..G-30). PostgreSQL is reached via libpq (the C client),
installed as a system package in the Containerfile, NOT via Conan — the
same choice 07 made (libpqxx's bundled CMake breaks this toolchain, G-67;
libpq's stable C ABI also avoids libstdc++ mixing).

Doc 10 additionally calls for opentelemetry-cpp, redis-plus-plus, and
libpqxx. This buildable capstone deliberately omits those heavy/unproven
dependencies and represents them as documented seams (see the README and
request_context.hpp). Everything the example actually compiles and links is
the trio + system libpq.
"""

from conan import ConanFile


class Stateless10GrpcMicroservicesConan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    default_options = {
        "*/*:shared": False,
        "openssl/*:no_fips": True,
    }

    def requirements(self):
        self.requires("grpc/1.54.3")
        self.requires("protobuf/3.21.12", override=True)
        self.requires("abseil/20230125.3", override=True)
