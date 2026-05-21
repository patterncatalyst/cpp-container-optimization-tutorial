"""statelessness/07-state-externalization Conan recipe (Conan 2.x).

The gRPC + protobuf + abseil trio is the same one verified end-to-end in
the other compendium examples (gotchas G-22..G-30). This example adds
ONE new dependency: libpqxx, the C++ client for PostgreSQL, which pulls
libpq transitively.

libpqxx is the new variable. Both gRPC and libpq depend transitively on
OpenSSL and zlib; if Conan resolves them to incompatible versions you'll
get a clear "version conflict" at `conan install` naming the package and
the two requirers. The fix is a single override line here pinning the
shared dependency to one version (the same pattern as the protobuf and
abseil overrides below). We deliberately do NOT add a speculative
OpenSSL/zlib override up front: an unnecessary or wrong override can
itself cause a conflict, so we let Conan resolve first and add the
minimal override only if the host build reports one.

If you intentionally upgrade a pin:
  1. Bump it here
  2. Regenerate the lockfile (see the Containerfile's empty-lock path)
  3. Run scripts/test-stateless-demo-07-state-externalization.sh
"""

from conan import ConanFile


class Stateless07StateExternalizationConan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    default_options = {
        # Static linkage everywhere for a portable runtime image. With
        # libpq static, the runtime image needs only libstdc++ — no
        # libpq.so to ship.
        "*/*:shared": False,
        # OpenSSL FIPS skipped (Digest::SHA on UBI 9 without EPEL — G-16).
        "openssl/*:no_fips": True,
    }

    def requirements(self):
        # The verified gRPC trio.
        self.requires("grpc/1.54.3")
        self.requires("protobuf/3.21.12", override=True)
        self.requires("abseil/20230125.3", override=True)
        # New: PostgreSQL client. Pulls libpq transitively.
        # 7.9.0 (not 7.7.x): libpqxx reworked its CMake build in 7.8.
        # 7.7.x ships a cmake/config.cmake that calls the long-removed
        # internal command `cmake_determine_compile_features`, which
        # fails to configure under the modern CMake Conan uses to build
        # the package (gotcha G-67).
        self.requires("libpqxx/7.9.0")
