"""Demo-04 Conan recipe (Conan 2.x).

Why conanfile.py instead of conanfile.txt: r45a tried to use a fixed set
of pinned versions in conanfile.txt:

    [requires]
    opentelemetry-cpp/1.14.2
    grpc/1.62.0
    protobuf/3.21.12
    abseil/20240116.2

— matching the OneUptime "How to Manage OpenTelemetry C++ Dependencies"
guide (Feb 2026) documented as a tested-as-a-block working combination.
But recipe revisions can move post-publication: the *current* recipe
revision of opentelemetry-cpp/1.14.2 requires protobuf/5.27.0, not
protobuf/3.21.12. Result on r45a's run:

    ERROR: Version conflict: Conflict between protobuf/5.27.0 and
    protobuf/3.21.12 in the graph.
    Conflict originates from opentelemetry-cpp/1.14.2

conanfile.txt has no override mechanism — it can pin top-level versions
but can't say "I know OTel-cpp's recipe wants protobuf/5.27.0; use my
3.21.12 anyway." conanfile.py does, via `self.requires(..., override=True)`.

The cost of overriding: Conan can't reuse pre-built binaries that were
compiled against the recipe-specified transitive versions. With
--build=missing, it rebuilds opentelemetry-cpp 1.14.2 from source against
our overridden grpc/protobuf/abseil. First-build penalty is large
(30-60 min for the full chain) but caches afterward. See G-25 in the
reconciliation plan.

Why this exact combination (G-22, G-24): grpc/1.62.0 has Status::OK and
GetGlobalCallbackHook() defined as linkable static members. gRPC versions
1.65+ removed both as part of an ABI cleanup, while OTel-cpp's pre-built
proto-grpc archives still reference them via inline templates. Pairing
OTel-cpp with a gRPC version that still has the symbols is the only way
to make the link resolve.
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

        # Overridden transitive deps — the OneUptime working combination.
        # override=True tells Conan: "I know the recipe wants something
        # different; use my version instead." Without this, recipe revision
        # drift makes the working-as-of-Feb-2026 combination unresolvable.
        #
        # The version choices:
        # - grpc/1.62.0:   has Status::OK + GetGlobalCallbackHook() as
        #                  linkable statics in libgrpc++.a (G-22).
        # - protobuf/3.21.12: paired with grpc/1.62.0 in OneUptime's combo;
        #                  modern enough for OTel-cpp 1.14.2's protobuf
        #                  feature usage but old enough to predate
        #                  protobuf/4.x's API breaking changes.
        # - abseil/20240116.2: from the same documented combo.
        self.requires("grpc/1.62.0",         override=True)
        self.requires("protobuf/3.21.12",    override=True)
        self.requires("abseil/20240116.2",   override=True)

    def layout(self):
        # No cmake_layout: keep the flat default so
        # build/conan/conan_toolchain.cmake is where the Containerfile
        # expects it. See G-18 for the long version.
        pass
