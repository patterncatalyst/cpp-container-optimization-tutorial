---
title: "Appendix A — Conan, autotools, and UBI 9's minimal perl"
order: 16
description: "A survival guide for building autotools-based C++ deps (libcurl, c-ares, openssl, etc.) on UBI 9 via Conan, learned the hard way during demo-04."
duration: 8 minutes
---

## Why this exists

This tutorial's demo-04 took six rounds of build failures to converge.
None of them were demo-04 bugs. All of them were the same underlying issue
in a different costume: **UBI 9 ships a deliberately minimal perl, and
Conan's bundled build tools assume the system perl is "complete."** When
the assumption fails, you get this:

    Can't locate FindBin.pm in @INC
    Can't locate Time/Piece.pm in @INC
    Can't locate Digest/SHA.pm in @INC
    Can't locate threads.pm in @INC
    Can't locate Thread/Queue.pm in @INC

…each one stopping a from-source dep build dead. We hit five of these in
sequence before pivoting strategy. This appendix is the recipe so you don't
have to repeat the journey.

The lesson generalizes well beyond demo-04. **libcurl, c-ares, openssl,
nghttp2, and several other staples of the C++ ecosystem use autotools
under the hood**. If you're building any of them via Conan on UBI 9 (or
RHEL 9, Rocky 9, Alma 9 — same packaging model), you'll meet the same
walls.

## The pattern

Three things conspire:

1. **Conan from-source builds.** Conan Center pre-builds packages for
   common profiles (gcc 11/12 with cppstd=17, libstdc++11 ABI). Profiles
   off this main path — gcc-toolset-14, cppstd=23, all-static-linkage —
   often miss pre-builts and fall through to a from-source compile.
2. **From-source builds run perl scripts.** OpenSSL's `Configure` is
   perl. `mk-fipsmodule-cnf.pl` is perl. autotools' `aclocal`,
   `automake`, `autoheader` are all perl. `autoreconf` invokes the
   whole stack.
3. **UBI 9's perl is minimal.** Each standard-library module
   (`FindBin`, `IPC::Cmd`, `Thread::Queue`, etc.) is a separate RPM.
   The base `perl` package only gives you the interpreter and a small
   core. Anything else needs `dnf install perl-<Module>`.

A normal Fedora or Debian developer environment hides this because those
distros ship a more complete perl in the base. UBI's deliberate
minimalism makes the gap visible.

## The complete shopping list

Three categories, by what consumes the modules:

### OpenSSL `Configure` script — 10 modules

OpenSSL 3.x's `Configure` is a perl program. Its full required-modules
list is in `openssl/INSTALL.md`:

```
perl-FindBin
perl-IPC-Cmd
perl-Data-Dumper
perl-Pod-Html
perl-Pod-Usage
perl-File-Compare
perl-File-Copy
perl-File-Path
perl-Time-Piece
perl-Getopt-Long
```

### OpenSSL FIPS post-build — 1 module (or skip FIPS)

After OpenSSL compiles, `util/mk-fipsmodule-cnf.pl` runs and computes a
SHA-256 hash of `providers/fips.so` for runtime integrity verification.
That script needs:

```
perl-Digest-SHA
```

**Or** disable FIPS in your conanfile and skip this whole code path:

```
[options]
openssl/*:no_fips=True
```

For demos and most non-compliance use cases, `no_fips=True` is fine —
it shrinks the static library, cuts build time, and removes the
Digest::SHA dependency. Keep FIPS on if you have a regulatory
requirement.

### Autotools (automake / aclocal / autoreconf) — 4 modules

Automake's perl scripts use the threading primitives heavily:
`Automake/Channels.pm` builds a `Thread::Queue` of work items per
`use threads`. The full set:

```
perl-threads
perl-threads-shared
perl-Thread-Queue
perl-Term-ANSIColor
```

A footnote: **none of these are in the `perl-core` metapackage** even
on systems where `perl-core` exists. They're standalone packages. If
you're tempted to "just install perl-core and call it a day," you'll
still hit `Can't locate threads.pm in @INC` because the threading
modules are intentionally separate.

`perl-Term-ANSIColor` isn't strictly required to build; it's used by
some autotools error formatting paths. Including it heads off a near-
future stumble.

### Total

Fifteen perl modules cover OpenSSL + autotools + most autotools-based
deps (libcurl, c-ares, nghttp2, brotli, etc.). This is the complete
list demo-04 converged to:

```dockerfile
RUN dnf install -y --setopt=install_weak_deps=False \
        gcc-toolset-14 \
        cmake \
        ninja-build \
        git \
        python3-pip \
        perl-FindBin \
        perl-IPC-Cmd \
        perl-Data-Dumper \
        perl-Pod-Html \
        perl-Pod-Usage \
        perl-File-Compare \
        perl-File-Copy \
        perl-File-Path \
        perl-Time-Piece \
        perl-Getopt-Long \
        perl-Digest-SHA \
        perl-threads \
        perl-threads-shared \
        perl-Thread-Queue \
        perl-Term-ANSIColor \
    && dnf clean all
```

## Worked example: libcurl from source via Conan on UBI 9

libcurl is the canonical autotools-using C library. Its build does
`autoreconf -fi`, then `configure`, then `make`. The `autoreconf`
step is where UBI 9 trips you up; once that passes, the `configure`
shell script and the C compilation are unremarkable.

### conanfile.txt

```
[requires]
libcurl/8.19.0

[generators]
CMakeDeps
CMakeToolchain

[layout]
cmake_layout

[options]
# libcurl options. Trim the protocol set if you don't need them all
# — each disabled feature is less code, fewer transitive deps, and
# a smaller static library.
libcurl/*:shared=False
libcurl/*:with_ssl=openssl     # the default; openssl static via Conan
libcurl/*:with_libssh2=False   # often unused; pulls libssh2
libcurl/*:with_libidn=False    # IDN support; often unused
libcurl/*:with_brotli=False
libcurl/*:with_zstd=False
libcurl/*:with_nghttp2=False   # HTTP/2; trim if HTTP/1.1 is enough

# Skip openssl FIPS module — perl-Digest-SHA dance optional.
openssl/*:no_fips=True

# Static everywhere so the runtime image is small.
*:shared=False
```

### Containerfile

```dockerfile
ARG UBI_VERSION=9.4
FROM registry.access.redhat.com/ubi9/ubi:${UBI_VERSION} AS build

# UBI w/o entitlement: silence subscription-manager.
RUN rm -f /etc/yum.repos.d/redhat.repo && \
    sed -i 's/^enabled=1/enabled=0/' \
        /etc/dnf/plugins/subscription-manager.conf 2>/dev/null || true

# The full perl-module shopping list — see the appendix for what
# each batch covers. Fifteen modules total.
RUN dnf install -y --setopt=install_weak_deps=False \
        gcc-toolset-14 cmake ninja-build git python3-pip \
        perl-FindBin perl-IPC-Cmd perl-Data-Dumper \
        perl-Pod-Html perl-Pod-Usage perl-File-Compare \
        perl-File-Copy perl-File-Path perl-Time-Piece \
        perl-Getopt-Long perl-Digest-SHA \
        perl-threads perl-threads-shared perl-Thread-Queue \
        perl-Term-ANSIColor \
    && dnf clean all

ENV PATH=/opt/rh/gcc-toolset-14/root/usr/bin:$PATH
RUN pip3 install --no-cache-dir 'conan~=2.0' && \
    conan profile detect --force

WORKDIR /src
COPY conanfile.txt CMakeLists.txt ./
RUN conan install . --output-folder=build/conan \
                    -s build_type=Release --build=missing

COPY src/ ./src/
RUN cmake -S . -B build -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=build/conan/conan_toolchain.cmake \
    && cmake --build build -j"$(nproc)"
```

### Validation

`conan install . --build=missing` will:

1. Download zlib, openssl from Conan Center (or build them — openssl
   often builds from source on uncommon profiles).
2. Build libcurl from source, invoking `autoreconf -fi` which calls
   aclocal, autoheader, automake, autoconf.
3. Run libcurl's `configure` script (POSIX shell, no perl).
4. Compile libcurl's C sources.
5. Stage the static library and headers for downstream consumers.

If any of those perl invocations fails with `Can't locate X.pm`, your
perl module list is incomplete. Add the missing module and retry.

The fifteen-module list above has been verified empirically against
openssl/3.6.2 + libcurl/8.19.0 + their full autotools dance. If a
future version of openssl, automake, or libcurl adds a new perl
module dependency, the recipe extends naturally.

## Three simplifying alternatives

Sometimes the right answer is to side-step the problem entirely.

### Skip the dep

If a Conan transitive dep needs autotools and you don't actually use
it, disable it. Demo-04 did this for `opentelemetry-cpp`:

```
opentelemetry-cpp/*:with_zipkin=False    # drops libcurl from the tree
```

When Zipkin is disabled, OTel-cpp doesn't pull libcurl. The whole
autotools build path is never exercised. **Sometimes the right answer
to a missing-tool problem is to remove the tool's consumer.** It's
worth checking whether each transitive dep in your tree is actually
used by your code; Conan's `--build=missing` will happily compile
several megabytes of code you'll never link.

### Use the system package

UBI 9 has openssl in BaseOS. EPEL 9 has libcurl. If you don't strictly
need the latest version that Conan would build, you can use the
system version and tell Conan to find it:

```dockerfile
RUN dnf install -y \
        https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
RUN dnf install -y openssl-devel libcurl-devel
```

…and in the conanfile:

```
[requires]
# (don't list openssl or libcurl)

[platform_requires]
openssl/system
libcurl/system
```

The `[platform_requires]` block tells Conan "these come from the
system, not Conan Center." Tradeoff: less version control, but
zero from-source-build cost and zero perl-module gymnastics.

### Pin a profile that Conan Center pre-builds for

`compiler.cppstd=17` and `compiler.version=11` (UBI 9's default gcc)
hit the most pre-built coverage. If you can live without C++23
features in your dep tree, drop the cppstd:

```dockerfile
RUN conan profile detect --force && \
    sed -i 's|^compiler.cppstd=.*|compiler.cppstd=17|' \
        /root/.conan2/profiles/default
```

Your application code can still use C++23 — `CMAKE_CXX_STANDARD 23`
in your `CMakeLists.txt` controls that target's flags independently
of the Conan profile. Only the Conan deps build at C++17 then, and
they reach pre-built parity.

## Decision matrix

| Situation | Best answer |
|---|---|
| You need libcurl/openssl, control matters | Full perl list + Conan from source |
| You don't actually use the dep | Skip it via Conan options |
| Latest version is fine | Use system package via `[platform_requires]` |
| Build time matters more than version pinning | Drop `cppstd` to hit more pre-builts |
| Production with FIPS compliance | Keep FIPS on; install `perl-Digest-SHA` |

## Cross-references

This appendix synthesizes lessons documented in the project's
reconciliation plan as gotchas:

- **G-13** — UBI 9 BaseOS+AppStream don't carry the modern C++
  ecosystem; switch to Conan or enable EPEL.
- **G-14** — Even EPEL doesn't have everything; refactor to
  Conan-managed deps.
- **G-15** — OpenSSL Configure script needs ten perl modules.
- **G-16** — OpenSSL FIPS post-build needs Digest::SHA, or skip
  FIPS via `no_fips=True`.
- **G-17** — Autotools (libcurl's build chain) needs four more
  perl modules; or skip the consumer.

§13 (Reproducibility & ABI) is the curriculum's chapter on Conan
and hermetic builds. This appendix is the operational survival
guide that complements the theoretical material there.
