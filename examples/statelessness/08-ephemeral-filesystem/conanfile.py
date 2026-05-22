"""statelessness/08-ephemeral-filesystem Conan recipe (Conan 2.x).

One light dependency: spdlog (the most common modern C++ logging
library, named in Doc 08). spdlog pulls fmt; both are linked statically
so the runtime image needs only libstdc++. No gRPC, no system C
libraries — the build is a quick compile of one binary.

The example exists to show spdlog's read-only-rootfs trap concretely:
basic_logger_mt opens its file in the constructor, so the write fails
with EROFS under a read-only rootfs. The fix is a stdout sink.
"""

from conan import ConanFile


class Stateless08EphemeralFilesystemConan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    default_options = {
        # Static linkage everywhere for a portable runtime image.
        "*/*:shared": False,
    }

    def requirements(self):
        self.requires("spdlog/1.14.1")
