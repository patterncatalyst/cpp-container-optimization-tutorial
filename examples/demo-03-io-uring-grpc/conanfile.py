"""Demo-03 Conan recipe (Conan 2.x).

Inherits demo-04's hard-won override chain exactly (rounds r28-r52
documented in the reconciliation plan, gotchas G-22 through G-30).
Adds standalone `asio` for the Asio-backed echo server. liburing
itself comes from the UBI 9 system package, not Conan.

Why standalone asio not boost::asio: same library code, but Conan
recipe and option surface is smaller. boost::asio drags in
boost::system + boost::thread + boost::date_time as compiled deps;
standalone asio is header-only and self-contained. The
`ASIO_HAS_IO_URING` switch works identically.

Why grpc 1.54.3 + abseil 20230125.3 + protobuf 3.21.12 + OTel-cpp
1.14.2: see G-22, G-24, G-25, G-26, G-27, G-28 in the reconciliation
plan. This combination is verified end-to-end by demo-04 (r51, 3/3
signals reaching the LGTM stack).

If you intentionally want to upgrade any version here:
  1. Bump the pin
  2. Run `./scripts/regenerate-demo-03-lockfile.sh`
  3. Run `./scripts/test-demo-03-io-uring-grpc.sh`
  4. Diagnose whatever surfaces using the G-22..G-30 catalog as a
     reference for the kinds of issues to expect.
"""

from conan import ConanFile


class Demo03Conan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    default_options = {
        # Static linkage everywhere for a portable runtime image.
        # See demo-04's conanfile.py for the long version.
        "*/*:shared": False,

        # OTel-cpp: drop zipkin (curl dep) and prometheus (we use
        # OTLP gRPC, not the Prometheus pull endpoint). Same as
        # demo-04.
        "opentelemetry-cpp/*:with_zipkin":     False,
        "opentelemetry-cpp/*:with_prometheus": False,
        "opentelemetry-cpp/*:with_otlp_grpc":  True,
        "opentelemetry-cpp/*:with_otlp_http":  False,

        # OpenSSL FIPS skipped (Digest::SHA dependency on UBI 9
        # without EPEL — G-16).
        "openssl/*:no_fips": True,
    }

    def requirements(self):
        # The OneUptime-derived override chain. See G-22..G-28 in
        # the reconciliation plan for why each pin is what it is.
        self.requires("opentelemetry-cpp/1.14.2")
        self.requires("grpc/1.54.3",         override=True)
        self.requires("protobuf/3.21.12",    override=True)
        self.requires("abseil/20230125.3",   override=True)

        # Standalone asio for the Asio io_uring echo server.
        # Header-only; ASIO_HAS_IO_URING is set via CMake.
        self.requires("asio/1.32.0")
