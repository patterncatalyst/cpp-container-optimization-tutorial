from conan import ConanFile
from conan.tools.cmake import CMakeDeps, CMakeToolchain, cmake_layout


class Demo06Conan(ConanFile):
    name = "demo07"
    version = "1.0.0"
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    # Pinned versions so the lockfile is meaningful.
    def requirements(self):
        self.requires("gtest/1.14.0")

    def layout(self):
        cmake_layout(self)

    def build_requirements(self):
        # Compiler/build deps are provided by the Containerfile, not Conan.
        pass
