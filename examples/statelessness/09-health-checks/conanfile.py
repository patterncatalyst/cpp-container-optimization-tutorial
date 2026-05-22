"""statelessness/09-health-checks Conan recipe (Conan 2.x).

The gRPC standard health protocol example. Dependency set is just the
verified gRPC trio — gRPC + protobuf + abseil (G-22..G-30) — and nothing
else: no PostgreSQL, no Kafka, no OpenTelemetry. The whole point of this
example is the health/lifecycle machinery, so it stays minimal.

The server uses gRPC's BUILT-IN default health service
(grpc::EnableDefaultHealthCheckService); our health-probe client is
generated from the bundled proto/health.proto. Neither needs a network
fetch at build time.
"""

from conan import ConanFile


class Stateless09HealthChecksConan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    default_options = {
        # Static linkage everywhere for a portable runtime image.
        "*/*:shared": False,
        # OpenSSL FIPS skipped (Digest::SHA on UBI 9 without EPEL — G-16).
        "openssl/*:no_fips": True,
    }

    def requirements(self):
        # The verified gRPC trio. No system packages needed at all.
        self.requires("grpc/1.54.3")
        self.requires("protobuf/3.21.12", override=True)
        self.requires("abseil/20230125.3", override=True)
