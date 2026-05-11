"""Demo-02 Conan recipe (Conan 2.x).

Why conanfile.py over conanfile.txt: even when no overrides are
needed, the .py format gives us a stable entry point that can grow
to handle overrides later if recipe revision drift bites (G-25).
Demo-04's r46 ended up converting; doing it from the start is
cheaper than retrofitting.

What this demo needs:

- boost — for `boost::container::flat_map`, the headline container
  this demo benchmarks against `std::unordered_map` and friends.
- benchmark — Google Benchmark for the timing harness. Stable,
  ubiquitous, supports JSON output for downstream scripting.

Notably absent: opentelemetry-cpp, gRPC, protobuf, abseil. Demo-02
is a pure-CPU benchmark; no signal export, no observability stack
side-car, no network. That makes the build dramatically simpler
than demo-04's 22-round saga.
"""

from conan import ConanFile


class Demo02Conan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    default_options = {
        # Static-link everything for a portable runtime image.
        "*/*:shared": False,

        # Boost: header-only. All this demo needs from Boost is
        # `boost::container::flat_map`, which is a template-only
        # facility in <boost/container/flat_map.hpp>. Setting
        # `header_only=True` tells Conan to skip building any of
        # Boost's compiled libraries (atomic, filesystem, system,
        # process, log, regex, …) — neither building them nor
        # validating their internal cross-dependencies. r55 tried
        # to enumerate ~30 `without_X: True` opt-outs manually and
        # hit a validation error because Boost's `process` library
        # was still enabled-by-default and required `filesystem`
        # and `system`, both of which I'd disabled. Header-only
        # mode sidesteps all of that.
        "boost/*:header_only": True,
    }

    def requirements(self):
        self.requires("boost/1.86.0")
        self.requires("benchmark/1.9.1")
