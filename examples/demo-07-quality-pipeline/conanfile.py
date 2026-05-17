from conan import ConanFile
from conan.tools.cmake import CMakeDeps, CMakeToolchain


class Demo07Conan(ConanFile):
    name = "demo07"
    version = "1.0.0"
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    # Pinned versions so the lockfile is meaningful.
    def requirements(self):
        self.requires("gtest/1.14.0")

    def layout(self):
        # G-51: flat layout. Conan's cmake_layout() helper nests
        # generators under `build/<BuildType>/generators/` which
        # doesn't match our CMakePresets.json's expected toolchain
        # path of `${sourceDir}/build/<preset>/conan_toolchain.cmake`.
        # Setting generators and build folders to "." puts the
        # toolchain file and CMakeDeps configs right at the
        # --output-folder root, aligning with our presets.
        self.folders.generators = "."
        self.folders.build = "."

    def build_requirements(self):
        # Compiler/build deps are provided by the Containerfile, not Conan.
        pass
