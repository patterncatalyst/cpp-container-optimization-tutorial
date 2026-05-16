"""Demo-06 Conan recipe (Conan 2.x) — r85 with OpenTelemetry.

Builds the 3-way allocator comparison (std::allocator, std::pmr,
mimalloc) instrumented with OpenTelemetry traces, metrics, and
logs exported via OTLP/gRPC to the LGTM observability stack.

The dep chain matches demo-04's, for two reasons:

1. **Same toolchain shape, same gotchas avoided.** Demo-04 went
   through ~20 rounds (r28-r52) to land a working
   opentelemetry-cpp + grpc + protobuf + abseil combination on
   our gcc-toolset-14 / UBI 9 toolchain. Most of the catalog
   entries G-13 through G-31 came out of that work. Copying
   demo-04's pinned versions means r85 inherits the wins for free
   instead of re-shaking the dep graph.

2. **Same lockfile flow.** If we ever pin a real conan.lock for
   demo-06, the dep set should match demo-04's so the same
   lockfile-regeneration script logic works.

The 3-way allocator variant story is preserved:
- std::allocator (default glibc malloc, no extra dep)
- std::pmr::synchronized_pool_resource + monotonic_buffer (no extra dep)
- mimalloc/2.2.4 (Microsoft's allocator; CMake-based recipe)

The 4-way → 3-way decision (r71-r74 → r75) stands; see those plan
entries for the jemalloc + GCC 14 strictness story. §7 prose
includes jemalloc as an alternative to mimalloc with appropriate
book citations, preserving the educational content without
requiring the binary to build.

Build notes:
- mimalloc is static-linked into each demo binary (CMakeLists
  --whole-archive trick) so each binary has exactly one allocator;
  there's no runtime switch.
- opentelemetry-cpp is also static-linked; the binary doesn't pull
  any C++ ecosystem package at runtime. ubi-minimal + libstdc++ is
  all we need in the runtime stage.
- First build pulls and compiles grpc, protobuf, abseil,
  opentelemetry-cpp, openssl, mimalloc from source. Budget 30-60
  minutes for a clean cache (per demo-04's experience).
  Subsequent rebuilds: ~30 seconds (just our app code).

Why override=True on grpc/protobuf/abseil (G-24, G-25, G-26):
The opentelemetry-cpp/1.14.2 recipe declares
"requires grpc/X.Y.Z" with X.Y.Z fixed; if that X.Y.Z has been
yanked from Conan Center or has known incompatibilities with the
abseil version it pulls, the install fails. The override= mechanism
forces the dep graph to use the pinned versions known to work with
our toolchain. Recipe revisions drift on Conan Center over time,
so the override pinning is the only reliable approach.

See conanfile comments in demo-04 for the full archaeology on each
override choice; demo-06 inherits the same set.
"""

from conan import ConanFile


class Demo06Conan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    # Per-package options. The "*/*:" wildcard form is Conan 2.x's syntax
    # for "apply this option to every package that has it."
    default_options = {
        "*/*:shared": False,

        # mimalloc options. The CMake recipe exposes several toggles;
        # we want static, no-secure-mode (production would set it),
        # and we enable huge-page support at runtime via env var
        # MIMALLOC_USE_HUGE_OS_PAGES (no recipe option needed).
        "mimalloc/*:override":   False,    # we use the static-link path,
                                            # not the LD_PRELOAD-style override
        "mimalloc/*:secure":     False,
        "mimalloc/*:single_object": False,

        # OpenTelemetry C++ wiring (r85+).
        "opentelemetry-cpp/*:with_otlp_grpc": True,    # the demo's exporter
        "opentelemetry-cpp/*:with_otlp_http": False,   # not used
        "opentelemetry-cpp/*:with_zipkin":   False,    # drops libcurl (G-17)
        "opentelemetry-cpp/*:shared":        False,    # static into binary

        # OpenSSL: drop FIPS to skip the Digest::SHA perl module dep (G-16).
        # Even with FIPS off we still need the other openssl perl modules
        # (see Containerfile dnf list).
        "openssl/*:no_fips":                 True,
    }

    def requirements(self):
        # mimalloc: the original demo-06 dep (r75+).
        self.requires("mimalloc/2.2.4")

        # OpenTelemetry C++ + overrides (r85+). See demo-04's
        # conanfile for the long story; short version: opentelemetry-
        # cpp/1.14.2's recipe pulls grpc with versions that are
        # either yanked from Conan Center or have abseil API
        # mismatches against our toolchain. Override to the
        # demo-04-proven set.
        self.requires("opentelemetry-cpp/1.14.2")
        self.requires("grpc/1.54.3",         override=True)
        self.requires("protobuf/3.21.12",    override=True)
        self.requires("abseil/20230125.3",   override=True)

    def layout(self):
        # No cmake_layout: keep the flat default so
        # build/conan/conan_toolchain.cmake is where the Containerfile
        # expects it. See G-18 for the long version.
        pass
