"""statelessness/11-build-tooling Conan recipe (Conan 2.x).

The leanest example in the set: the only dependency is GoogleTest, for the
unit tests of the vendored helpers' pure parsers. The helpers themselves
(cgroup_helper, psi_reader) and the demo binary use only the standard
library and Linux syscalls — no Conan deps, no gRPC, no system packages.

This mirrors Doc 11's guidance that the small vendored helpers are
"Conan-free static libraries": minimal dependencies, not worth the overhead
of separate packages. GoogleTest is a test-only dependency.
"""

from conan import ConanFile


class Stateless11BuildToolingConan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    def requirements(self):
        self.requires("gtest/1.14.0")
