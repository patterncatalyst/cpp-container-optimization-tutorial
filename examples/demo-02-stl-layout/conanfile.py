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

        # Boost is huge by default. We need exactly one
        # header-only library (boost::container::flat_map) plus
        # whatever it transitively brings (intrusive containers,
        # type traits, mp11). Disable everything else so the
        # build is fast and the binary stays small.
        "boost/*:without_atomic":       True,
        "boost/*:without_chrono":       True,
        "boost/*:without_cobalt":       True,
        "boost/*:without_context":      True,
        "boost/*:without_contract":     True,
        "boost/*:without_coroutine":    True,
        "boost/*:without_date_time":    True,
        "boost/*:without_exception":    True,
        "boost/*:without_fiber":        True,
        "boost/*:without_filesystem":   True,
        "boost/*:without_graph":        True,
        "boost/*:without_graph_parallel": True,
        "boost/*:without_iostreams":    True,
        "boost/*:without_json":         True,
        "boost/*:without_locale":       True,
        "boost/*:without_log":          True,
        "boost/*:without_math":         True,
        "boost/*:without_mpi":          True,
        "boost/*:without_nowide":       True,
        "boost/*:without_program_options": True,
        "boost/*:without_python":       True,
        "boost/*:without_random":       True,
        "boost/*:without_regex":        True,
        "boost/*:without_serialization": True,
        "boost/*:without_stacktrace":   True,
        "boost/*:without_system":       True,
        "boost/*:without_test":         True,
        "boost/*:without_thread":       True,
        "boost/*:without_timer":        True,
        "boost/*:without_type_erasure": True,
        "boost/*:without_url":          True,
        "boost/*:without_wave":         True,
        # Note: we don't disable `container` because that's the
        # whole point of this demo. Header-only by default.
    }

    def requirements(self):
        self.requires("boost/1.86.0")
        self.requires("benchmark/1.9.1")
