"""Demo-04 Conan recipe (Conan 2.x).

Why conanfile.py instead of conanfile.txt: r45a's conanfile.txt approach
hit a recipe-revision drift conflict when opentelemetry-cpp/1.14.2's
current recipe revision was found to require protobuf/5.27.0 (not the
3.21.12 from OneUptime's documented combo). conanfile.txt has no
override mechanism; conanfile.py does, via
`self.requires(..., override=True)`. See G-25.

Why this specific override set (G-26): r46 first tried grpc/1.62.0 from
OneUptime's Feb 2026 guide, but Conan Center yanked that version
sometime between Feb and May 2026:

    ERROR: Package 'grpc/1.62.0' not resolved: Unable to find
    'grpc/1.62.0' in remotes.

Per the conan-center-index config.yml, the gRPC versions still hosted
are 1.50.0, 1.50.1, 1.54.3, 1.65.0, 1.67.1, 1.78.1. Of these, only
≤ 1.64 still have grpc::Status::OK and grpc::GetGlobalCallbackHook()
defined as linkable static members in libgrpc++.a (G-22). That leaves
1.50.x and 1.54.3. We pick 1.54.3 — the most recent of the still-hosted
"old enough" versions, paired with protobuf/3.21.12 in its release era,
and well-tested.

The cost of overriding: Conan can't reuse pre-built binaries that were
compiled against the recipe-specified transitive versions. With
--build=missing, it rebuilds opentelemetry-cpp 1.14.2 from source against
our overridden grpc/protobuf/abseil chain. First-build penalty is large
(30-60 min) but caches afterward.
"""

from conan import ConanFile


class Demo04Conan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeDeps", "CMakeToolchain"

    # Per-package options. The "*/*:" wildcard form is Conan 2.x's syntax for
    # "apply this option to every package that has it."
    default_options = {
        # OpenTelemetry C++ wiring
        "opentelemetry-cpp/*:with_otlp_grpc": True,    # the demo's exporter
        "opentelemetry-cpp/*:with_otlp_http": False,   # not used
        "opentelemetry-cpp/*:with_zipkin":   False,    # drops libcurl (G-17)
        "opentelemetry-cpp/*:shared":        False,    # static into binary

        # OpenSSL: drop FIPS to skip the Digest::SHA perl module dep (G-16)
        "openssl/*:no_fips":                 True,

        # Static everything for a portable runtime image
        "*/*:shared":                        False,
    }

    def requirements(self):
        # Top-level: opentelemetry-cpp pulled normally.
        self.requires("opentelemetry-cpp/1.14.2")

        # Overridden transitive deps — pinning to versions still on
        # Conan Center that have the gRPC symbols OTel-cpp's
        # pre-built archives reference.
        #
        # Why grpc/1.54.3 specifically (G-26):
        # - Conan Center yanked grpc/1.62.0 (the OneUptime-documented
        #   version) sometime between Feb 2026 and May 2026. r46's
        #   override=True for grpc/1.62.0 produced:
        #     "Package 'grpc/1.62.0' not resolved: Unable to find
        #      'grpc/1.62.0' in remotes."
        # - Of the gRPC versions still hosted (per the conan-center-index
        #   config.yml), only 1.50.0, 1.50.1, 1.54.3, 1.65.0, 1.67.1,
        #   1.78.1 are present. Versions ≥ 1.65 have `Status::OK` and
        #   `GetGlobalCallbackHook()` removed (G-22), so we need
        #   ≤ 1.64. That leaves 1.50.x and 1.54.3.
        # - 1.54.3 is the most recent of the available "old enough"
        #   versions, so it's the closest to OneUptime's tested 1.62.0.
        #
        # Why protobuf/3.21.12 (despite Conan flagging it as deprecated):
        # gRPC 1.54.3 was released paired with protobuf 3.21.x. The
        # deprecation warning is informational; the package still
        # builds and links correctly.
        #
        # Why abseil/20230125.3 (G-28): r48's gnu17 fix unmasked the
        # next layer of incompatibility. gRPC 1.54.3 source calls
        # `absl::StrCat`, but the abseil/20240116.2 (Jan 2024 LTS)
        # didn't expose StrCat at the call site gRPC expected:
        #     error: 'StrCat' is not a member of 'absl'
        #         absl::StrCat("tcp-client:", addr_uri.value()))
        # Cause: abseil restructures namespace internals across LTS
        # versions, and gRPC 1.54.3 was tested against the
        # abseil/20230125 LTS line. Pairing 1.54.3 with the wrong
        # abseil LTS produces source-level API mismatches that no
        # override flag can fix. Use the abseil version paired with
        # this gRPC in its release era — confirmed by Conan Center
        # issues showing `abseil/20230125.3` + `grpc/1.54.3` as a
        # clean pair.
        self.requires("grpc/1.54.3",         override=True)
        self.requires("protobuf/3.21.12",    override=True)
        self.requires("abseil/20230125.3",   override=True)

    def layout(self):
        # No cmake_layout: keep the flat default so
        # build/conan/conan_toolchain.cmake is where the Containerfile
        # expects it. See G-18 for the long version.
        pass
