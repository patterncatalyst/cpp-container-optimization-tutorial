"""Demo-06 Conan recipe (Conan 2.x) — v1 (r71).

v1 scope: prove 4-way allocator-linked binaries build and run on
our UBI 9 + gcc-toolset-14 toolchain. Adds:

- mimalloc/2.2.4   (Microsoft's allocator; CMake-based recipe)
- jemalloc/5.3.1   (Facebook's allocator; autotools-based recipe;
                    fixed user-namespace-remap issue from 5.2.1)

v2 (r72) will add: opentelemetry-cpp + cpp-httplib for the LGTM-
wired HTTP server entrypoint. Splitting v1/v2 keeps the risk surface
small: if mimalloc or jemalloc links break, we diagnose without the
OTel chain piled on top.

Build notes:
- Both allocators are static-linked into the demo binaries to keep
  the runtime image small. Each binary has exactly one allocator;
  there's no runtime switch.
- jemalloc requires `--with-jemalloc-prefix=je_` to coexist with
  glibc malloc — Conan's recipe enables this by default for shared
  builds. For static builds (our case), the symbol replacement is
  total: the binary's `malloc`/`free`/`new`/`delete` all route
  through jemalloc.
- mimalloc's static lib mode replaces global new/delete via a
  static initializer; the user doesn't need to call any mimalloc
  API explicitly.
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

        # jemalloc options. The autotools recipe needs careful tuning:
        # - --with-jemalloc-prefix='' for total replacement (our case)
        # - --enable-prof OFF (we don't need jemalloc's heap profiler)
        # - --disable-libdl false on Linux (mandatory for some recent
        #   distros)
        "jemalloc/*:prefix":     "",       # full replacement, no `je_` prefix
        "jemalloc/*:enable_prof":     False,
        "jemalloc/*:enable_stats":    True,   # cheap; useful for the demo
        "jemalloc/*:enable_debug":    False,
    }

    def requirements(self):
        self.requires("mimalloc/2.2.4")
        self.requires("jemalloc/5.3.1")
