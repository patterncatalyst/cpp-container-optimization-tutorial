"""statelessness/07-state-externalization Conan recipe (Conan 2.x).

Identical dependency set to the other compendium gRPC examples: gRPC +
protobuf + abseil (the verified G-22..G-30 trio). No OpenTelemetry.

PostgreSQL is reached through libpq (the C client), which is installed
from UBI's own AppStream as a system package in the Containerfile — NOT
via Conan. That choice avoids the libpqxx Conan recipe, whose bundled
CMake build (cmake/config.cmake -> cmake_determine_compile_features)
fails to configure under the CMake in this toolchain across libpqxx
versions (gotcha G-67), and it sidesteps any OpenSSL/zlib resolution
conflict between gRPC's chain and libpq's. libpq's stable C ABI also
removes the libstdc++ mixing concern a system C++ library would raise.
The connection-pool patterns (Doc 07) are identical either way; only the
connection type differs (PGconn* vs pqxx::connection).
"""

from conan import ConanFile


class Stateless07OutboxPatternConan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    default_options = {
        # Static linkage everywhere for a portable runtime image.
        "*/*:shared": False,
        # OpenSSL FIPS skipped (Digest::SHA on UBI 9 without EPEL — G-16).
        "openssl/*:no_fips": True,
    }

    def requirements(self):
        # The verified gRPC trio. libpq is a system package (see the
        # Containerfile), not a Conan dependency.
        self.requires("grpc/1.54.3")
        self.requires("protobuf/3.21.12", override=True)
        self.requires("abseil/20230125.3", override=True)
