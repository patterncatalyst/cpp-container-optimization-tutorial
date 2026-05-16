"""Demo-06 Conan recipe (Conan 2.x) — v1 3-way variant (r75).

v1 scope: prove 3-way allocator-linked binaries build and run on
our UBI 9 + gcc-toolset-14 toolchain. The three variants:

- std::allocator (default glibc malloc, no extra dep)
- std::pmr::synchronized_pool_resource + monotonic_buffer (no extra dep)
- mimalloc/2.2.4 (Microsoft's allocator; CMake-based recipe)

v2 (r76+) will add: opentelemetry-cpp + cpp-httplib for the LGTM-
wired HTTP server entrypoint.

The 4-way → 3-way decision (r71-r74 → r75):

We originally planned to include jemalloc/5.3.1 as a fourth variant
(see r70 design discussion). r71-r74 attempted to land it; we
hit two independent build-toolchain issues, fixed the first
(chmod gap, G-33) at the build-step layer as a workaround, and
spent three rounds trying to fix the second (GCC 14 conformance
strictness, G-34) without success. The GCC 14 compatibility
flags refused to propagate through Conan's autotools toolchain
in any of the mechanisms we tried (env CFLAGS, tools.build:cflags
conf).

After three failed attempts, we judged the cost-benefit balance
had shifted: jemalloc adds breadth ("a fourth data point") but
no fundamentally new concept beyond what mimalloc already
demonstrates. The Latency book's "general-purpose allocator tax"
thesis is fully demonstrable with three variants. Andrist & Sehr
Ch. 7's allocator-aware container discussion is fully reified by
PMR alone. Iglberger Ch. 7's Bridge/PIMPL discussion (lifetime
ownership of memory_resource) doesn't need a fourth allocator
either.

§7 prose will include a paragraph describing jemalloc as an
alternative to mimalloc with the trade-offs (per-arena vs
segment-based allocation, fragmentation behavior, etc.), citing
Latency Ch. 3 and Ghosh Ch. 5. That preserves the educational
content without requiring the binary to build.

Readers wanting jemalloc in their own copies can follow that
prose; the tutorial doesn't have to do it for them. If upstream
ever fixes the GCC 14 conformance issues or the Conan recipe
gains a CMake-based variant, we can revisit.

Build notes:
- mimalloc is static-linked into the demo binary. Each binary has
  exactly one allocator; there's no runtime switch.
- mimalloc's static lib mode replaces global new/delete via a
  static initializer; the user doesn't need to call any mimalloc
  API explicitly. The CMakeLists --whole-archive linker flag
  ensures the initializer is actually present in the final binary.
"""

from conan import ConanFile


class Demo06Conan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    default_options = {
        "*/*:shared": False,

        # mimalloc options. The CMake recipe exposes several toggles;
        # we want static, no-secure-mode (production would set it),
        # and we'll enable huge-page support at runtime via env var
        # MIMALLOC_USE_HUGE_OS_PAGES (no recipe option needed).
        "mimalloc/*:override":   False,    # we use the static-link path,
                                            # not the LD_PRELOAD-style override
        "mimalloc/*:secure":     False,
        "mimalloc/*:single_object": False,
    }

    def requirements(self):
        self.requires("mimalloc/2.2.4")
