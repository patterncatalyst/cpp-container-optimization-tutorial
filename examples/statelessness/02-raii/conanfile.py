"""statelessness/02-raii Conan recipe (Conan 2.x).

Lighter than demo-03/demo-04: this example needs only gRPC + protobuf
+ abseil. No OpenTelemetry, asio, or liburing — the teaching point is
the RequestContext RAII lifecycle, not observability or I/O.

The gRPC / protobuf / abseil versions are pinned to the same trio the
tutorial verified end-to-end in demo-03 and demo-04 (gotchas G-22..G-30
in _plans/reconciliation-plan.md). Reusing the known-good versions
keeps this example's build on the same proven path; dropping OTel
removes the heaviest part of the dependency graph, so the first build
is meaningfully faster than the observability demos.

If you intentionally upgrade a pin:
  1. Bump it here
  2. Regenerate the lockfile (see the Containerfile's empty-lock path)
  3. Run scripts/test-stateless-demo-02-raii.sh
  4. Use the G-22..G-30 catalog as a reference for what may surface
"""

from conan import ConanFile


class Stateless02RaiiConan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    default_options = {
        # Static linkage everywhere for a portable runtime image.
        "*/*:shared": False,
        # OpenSSL FIPS skipped (Digest::SHA dependency on UBI 9 without
        # EPEL — G-16). gRPC pulls OpenSSL transitively.
        "openssl/*:no_fips": True,
    }

    def requirements(self):
        # Same gRPC trio as the verified demos, minus OTel. gRPC brings
        # protobuf and abseil transitively; the explicit overrides pin
        # them to the versions the rest of the tutorial uses.
        self.requires("grpc/1.54.3")
        self.requires("protobuf/3.21.12", override=True)
        self.requires("abseil/20230125.3", override=True)
