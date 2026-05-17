"""
sections.py — slide content for the C++ container optimization deck.

Each section has:
  - num: §-number
  - title: section title
  - tagline: subtitle on the section divider
  - divider_notes: speaker script for the section opener
  - slides: list of slide-builder dicts

Slide dicts include all the data needed by build-pptx.py.

This file is human-edited prose; build-pptx.py is the renderer.
"""
from pptx.dml.color import RGBColor
from pptx.util import Pt
from pptx.enum.text import PP_ALIGN


# Re-import colors from build script — same palette
class C:
    ACCENT_CYAN    = RGBColor(0x00, 0xBC, 0xD4)
    ACCENT_BLUE    = RGBColor(0x1E, 0x6F, 0xC8)
    ACCENT_GREEN   = RGBColor(0x27, 0xAE, 0x60)
    ACCENT_RED     = RGBColor(0xE8, 0x48, 0x55)
    ACCENT_ORANGE  = RGBColor(0xF5, 0xA6, 0x23)
    ACCENT_PURPLE  = RGBColor(0x9B, 0x59, 0xB6)
    TEXT_DARK      = RGBColor(0x1A, 0x2B, 0x3C)
    TEXT_MUTED     = RGBColor(0x90, 0xA4, 0xAE)
    BG_CARD_LIGHT  = RGBColor(0xEC, 0xF0, 0xF1)
    BG_CARD_SOFT   = RGBColor(0xE0, 0xE8, 0xF0)


# Diagram directory (set by build-pptx.py)
DG = "/tmp/diagrams-png"


# Helper to make a paragraph dict
def para(text, size=Pt(16), bold=False, italic=False,
         color=C.TEXT_DARK, bullet=False, align=PP_ALIGN.LEFT):
    return dict(text=text, size=size, bold=bold, italic=italic,
                color=color, bullet=bullet, align=align)


def bullet(text, size=Pt(15)):
    return dict(text=text, size=size, bold=False, color=C.TEXT_DARK,
                bullet=True)


def heading(text, size=Pt(18), color=None):
    return dict(text=text, size=size, bold=True,
                color=color or C.TEXT_DARK)


SECTIONS = [
# ============================================================================
# §0 — Outline & reading order
# ============================================================================
{
    "num": 0,
    "label": "Section 00",
    "title": "Outline & reading order",
    "tagline": "The map. Don't skip it on your first read.",
    "divider_notes": (
        "Quick map before we start. Three deliverables: this deck, the "
        "companion site, and seven runnable demos. The deck is the curated "
        "three-hour path. The site has every code listing and every "
        "measurement in long form — call it three to four hours of "
        "reading. The demos are the bedrock; everything I'll say has a "
        "podman command behind it that produces the number on the slide. "
        "If you want to follow along on your laptop, the prereqs are "
        "Fedora 44, Podman 5 rootless, and about thirty minutes of "
        "patience for the first build."
    ),
    "slides": [],   # §0 is divider-only
},

# ============================================================================
# §1 — Prerequisites
# ============================================================================
{
    "num": 1,
    "label": "Section 01",
    "title": "Prerequisites",
    "tagline": "Fedora 44 + Podman 5.x + GCC 14 + Conan 2 + cgroup v2 delegation",
    "divider_notes": (
        "Three minutes on prereqs. The whole tutorial is calibrated for "
        "Fedora 44 because it ships GCC 14, recent Clang, kernel 6.x with "
        "current io_uring features, and cgroups v2 by default. Other "
        "distros mostly work; macOS via podman machine works for the "
        "image-building parts and breaks for the kernel-feature demos."
    ),
    "slides": [
        dict(kind="content",
             title="The toolchain at a glance",
             body=[
                 heading("Build-time"),
                 bullet("Conan 2.x — package manager + lockfiles (§13)"),
                 bullet("CMake + Ninja — presets, hermetic builds"),
                 bullet("gcc-toolset-14 or Clang 18 — C++23, sanitizers, LTO/PGO (§5)"),
                 heading("Runtime", color=C.ACCENT_BLUE),
                 bullet("Podman 5.x rootless — podman compose, slirp4netns"),
                 bullet("OCI runtime: crun + conmon — applies cgroup v2 + user namespace"),
                 bullet("Base images: UBI 9 / ubi-micro / scratch — multi-stage in §4"),
                 bullet("Load generators: hey (HTTP), ghz (gRPC)"),
                 bullet("Observability: otel-lgtm (§10) — all-in-one Grafana stack"),
             ],
             diagram=f"{DG}/01-prerequisites-toolchain.jpg",
             notes=(
                 "Two columns. On the left, build-time: Conan manages "
                 "dependencies and produces lockfiles; CMake plus Ninja drives "
                 "the build; either GCC 14 from gcc-toolset or Clang 18 does "
                 "the actual compilation. Standard hermetic build flow.\n\n"
                 "On the right, runtime: Podman 5 rootless runs the container; "
                 "crun and conmon apply the cgroup v2 limits and the user "
                 "namespace; the base image is UBI or ubi-micro depending on "
                 "what you trade off (we'll cover that in section 4). Load "
                 "generators are hey for HTTP and ghz for gRPC. The "
                 "observability stack is the grafana/otel-lgtm all-in-one "
                 "image — Prometheus, Tempo, Loki, Mimir, Grafana, OTel "
                 "collector, one container.\n\n"
                 "The host underneath is Fedora 44 — kernel 6, cgroup v2, "
                 "systemd, and the profiling tools we'll use in section 10. "
                 "One non-obvious prereq: cgroup v2 controller delegation has "
                 "to be enabled for rootless podman to set cpu.weight and "
                 "cpuset.cpus. We have a helper script for that; section 11 "
                 "covers the failure mode if you skip it."
             )),
        dict(kind="content",
             title="What works, what doesn't",
             body=[
                 heading("Works as-is", color=C.ACCENT_GREEN),
                 bullet("Fedora 44, Fedora Silverblue (toolbox), RHEL 9 with EPEL"),
                 bullet("Most demos work on Ubuntu 24.04 with package substitutions"),
                 heading("Caveats", color=C.ACCENT_ORANGE),
                 bullet("macOS via 'podman machine': image building works; cgroup/NUMA/io_uring demos don't"),
                 bullet("WSL2: language sections fine; kernel-feature demos limited"),
                 bullet("Older kernels (<6.0): io_uring multishot disabled — Demo 3 reduced functionality"),
                 heading("Does not work", color=C.ACCENT_RED),
                 bullet("Windows native Podman — kernel-feature demos require Linux"),
                 bullet("Docker Desktop on macOS — same limitation as podman machine"),
             ],
             code=None,
             notes=(
                 "Three buckets. Works as-is: Fedora 44 is the primary target. "
                 "Silverblue with a toolbox works fine. RHEL 9 plus EPEL "
                 "covers most of it. Ubuntu 24 works for most demos but you "
                 "need to substitute package names — dnf becomes apt and the "
                 "package names shift slightly.\n\n"
                 "Caveats: macOS via podman machine — the container images "
                 "build correctly because the build happens in a Linux VM, "
                 "but anything that touches cgroups, NUMA, or io_uring is "
                 "going to behave differently because you're running through "
                 "a VM layer. The demos will warn and skip those parts.\n\n"
                 "Does not work: Windows native Podman — same VM problem. "
                 "Docker Desktop has the same issue. If you're on those "
                 "platforms, run the demos against a Linux VM directly or "
                 "use a cloud VM."
             )),
    ],
},

# ============================================================================
# §2 — Introduction & mental model
# ============================================================================
{
    "num": 2,
    "label": "Section 02",
    "title": "Introduction & mental model",
    "tagline": "Why container constraints change C++ performance reasoning",
    "divider_notes": (
        "Now the framing. Most C++ performance advice you'll read on the "
        "internet assumes a bare-metal mental model: one tuned host, one "
        "workload, the kernel doing what you expect. In production, that "
        "workload is one of dozens sharing a host, the toolchain comes "
        "from an OCI image, the binary may be built for an instruction "
        "set the host doesn't have, and the kernel parameters that decide "
        "your tail latency live three layers of abstraction away in "
        "cgroups v2. We're going to close that gap."
    ),
    "slides": [
        dict(kind="stat-row",
             title="The container performance gap",
             stats=[
                 ("60%", "of C++ services overprovision memory because the\n"
                         "default allocator ignores cgroup limits",
                  C.ACCENT_RED),
                 ("2-10×", "p99 latency drift from a noisy neighbor with\n"
                          "default scheduler weights (see §11)",
                  C.ACCENT_ORANGE),
                 ("4-7%", "typical PGO gain on top of LTO for service\n"
                          "request handlers (Demo 1)",
                  C.ACCENT_GREEN),
                 ("26×", "image size delta: naive single-stage vs ubi-micro\n"
                         "multi-stage (Demo 1)",
                  C.ACCENT_CYAN),
             ],
             notes=(
                 "Four data points to set the stakes. These are real "
                 "measurements from the seven demos we'll run today, not "
                 "vendor numbers.\n\n"
                 "Sixty percent: that's the proportion of C++ services in "
                 "the field that overprovision memory because the default "
                 "glibc malloc reads /proc/meminfo and assumes it has access "
                 "to whatever the host has. Inside a 2GB container on a 256GB "
                 "node, that means malloc thinks it has 256GB to play with. "
                 "Eventually the cgroup terminates the process. Section 7 "
                 "covers the fix.\n\n"
                 "Two to ten X: p99 latency drift from a single noisy "
                 "neighbor sharing CPU with default scheduler weights. That's "
                 "Demo 5's headline result. The fix is cgroup cpu.weight or "
                 "cpuset.cpus; the section is §11.\n\n"
                 "Four to seven percent: typical PGO gain on top of LTO for "
                 "a request-handler workload. Small in absolute terms; "
                 "real, free, and compounding across millions of requests. "
                 "Demo 1 shows the build pipeline.\n\n"
                 "Twenty-six X: image size delta from naive single-stage "
                 "to a multi-stage ubi-micro build. 689 megabytes down to "
                 "26 megabytes. That changes cold-start latency, registry "
                 "pull cost, and your CVE surface. Demo 1 again."
             )),
        dict(kind="diagram",
             title="The four-layer mental model",
             diagram=f"{DG}/02-introduction-four-layers.jpg",
             caption=("Compile-time → image layout → kernel boundary → "
                      "runtime isolation. The tutorial walks the layers in order."),
             notes=(
                 "This is the frame I want you to carry through the rest of "
                 "the talk. Four layers, each with its own perf levers, each "
                 "with its own failure modes.\n\n"
                 "Layer one is compile time. LTO, PGO, constexpr, the "
                 "decisions you make in your CMakePresets.json. Sections 5 "
                 "covers this. The lever here is the compiler and what you "
                 "tell it about your target.\n\n"
                 "Layer two is image layout. What goes in the base image, "
                 "how you stack stages, what the runtime layer actually "
                 "contains. Sections 4. The lever is your Containerfile.\n\n"
                 "Layer three is the kernel boundary. Syscall cost, "
                 "io_uring vs epoll, namespace boundaries, what crossing "
                 "into the kernel costs you per call. Sections 8 and 9.\n\n"
                 "Layer four is runtime isolation. Cgroup limits, scheduler "
                 "weights, NUMA placement, what shares your CPU and memory. "
                 "Section 11.\n\n"
                 "When you're optimizing, ask which layer you're actually "
                 "touching. Most people optimize layer one — language "
                 "features — and ignore that their service runs in a "
                 "constrained sandbox where layers two through four are "
                 "doing more to their p99 than any constexpr can fix."
             )),
        dict(kind="content",
             title="Why this section's framing matters",
             body=[
                 para("Three production failure modes that come from layer-confusion:",
                      bold=True),
                 dict(text="", size=Pt(8)),
                 heading("1. The bare-metal advice trap", color=C.ACCENT_RED),
                 bullet("\"Use -O3 and -march=native\" works on your laptop, ships AVX-512 to a runtime host that doesn't have it, crashes with SIGILL. §14."),
                 heading("2. The default-allocator-OOM trap", color=C.ACCENT_RED),
                 bullet("glibc malloc reads host RAM. Container has 2GB. malloc claims 64GB. Pod OOMs mid-request. §7."),
                 heading("3. The noisy-neighbor surprise", color=C.ACCENT_RED),
                 bullet("Your code is fine. The host's other tenant just got promoted to CFS class A. Your p99 doubles. §11."),
                 dict(text="", size=Pt(8)),
                 para("Each section in this tutorial has a worked demo with measurements. "
                      "Reproduce them on your own hardware — that's the proof.", italic=True),
             ],
             notes=(
                 "Three concrete failure modes that come from operating in "
                 "one layer while assuming you're in another.\n\n"
                 "First: the bare-metal advice trap. Most C++ optimization "
                 "guides assume you're building for a known target host. "
                 "-march=native produces a binary for whatever CPU you "
                 "compile on. If you compile on a Skylake-X laptop with "
                 "AVX-512 and run on a Cascade Lake runtime host without it, "
                 "you get SIGILL — illegal instruction — at the first AVX-512 "
                 "instruction the binary executes. Demo 1 and section 14 "
                 "cover this.\n\n"
                 "Second: the default-allocator-OOM trap. This one's the "
                 "single most common production issue with C++ in "
                 "containers. The default glibc malloc reads /proc/meminfo "
                 "from the host kernel, not the cgroup. It claims memory "
                 "based on what the host has — and your container has "
                 "memory.max set much lower. Eventually you allocate past "
                 "the cgroup limit and the kernel terminates the process. "
                 "Section 7 has the fix; Demo 6 shows the measurement.\n\n"
                 "Third: the noisy-neighbor surprise. You tuned your "
                 "service to a known p99. It goes into production. Six "
                 "months later, a new tenant ships on the same node. Your "
                 "p99 doubles overnight. Nothing changed in your code. "
                 "What changed is the scheduler-weight balance on the "
                 "host. Demo 5 and section 11."
             )),
    ],
},

# ============================================================================
# §3 — RAII & container resource discipline
# ============================================================================
{
    "num": 3,
    "label": "Section 03",
    "title": "RAII & resource discipline",
    "tagline": "The C++ idiom the rest of the tutorial assumes",
    "divider_notes": (
        "Ten minutes on RAII — Resource Acquisition Is Initialization. "
        "Every C++ engineer in this room has used it, but the framing I "
        "want to add is this: outside a container, leaking a few file "
        "descriptors is cosmetic. Inside a 256 MB cgroup with nofile=1024 "
        "and a service expected to stay up for weeks, leaks compound into "
        "outages. RAII is the discipline that holds your code together "
        "across every exit path — normal returns, early returns, "
        "exceptions, and panics."
    ),
    "slides": [
        dict(kind="diagram",
             title="RAII = resource lifetime tied to scope",
             diagram=f"{DG}/03-raii-discipline.jpg",
             caption="Four resource classes — memory, fds, locks, sockets — all benefit from the same lifetime model.",
             notes=(
                 "Diagram is the framing: four resource classes that all "
                 "fit the same model.\n\n"
                 "Memory: unique_ptr, shared_ptr, vector — destructors free.\n\n"
                 "File descriptors: this is the one most engineers don't "
                 "wrap. Raw int fds from open(), socket(), accept(). The "
                 "canonical wrapper is twenty lines — we'll show it on the "
                 "next slide.\n\n"
                 "Locks: lock_guard, scoped_lock, unique_lock. RAII for "
                 "mutexes.\n\n"
                 "Sockets: same pattern as fds, often via a higher-level "
                 "wrapper like Asio's tcp::socket which is itself RAII.\n\n"
                 "Inside a container the stakes go up. nofile is typically "
                 "1024 in default containers. A leaking handler in a "
                 "high-traffic service blows past that in minutes. "
                 "memory.max is the same story. Lock acquisition under "
                 "cgroup CPU throttling can stall for tens of milliseconds. "
                 "RAII isn't a style choice; it's the only way to keep "
                 "lifetime correct under constrained, high-rate workloads."
             )),
        dict(kind="code-content",
             title="The canonical unique_fd",
             body=[
                 para("Twenty lines of C++23 that you'll write once and never re-think:"),
             ],
             code="""class unique_fd {
    int fd_ = -1;
public:
    unique_fd() = default;
    explicit unique_fd(int fd) noexcept : fd_(fd) {}

    unique_fd(unique_fd&& o) noexcept
        : fd_(std::exchange(o.fd_, -1)) {}

    unique_fd& operator=(unique_fd&& o) noexcept {
        if (this != &o) {
            reset();
            fd_ = std::exchange(o.fd_, -1);
        }
        return *this;
    }

    ~unique_fd() { reset(); }
    int get() const noexcept { return fd_; }
    int release() noexcept { return std::exchange(fd_, -1); }
    void reset(int fd = -1) noexcept {
        if (fd_ != -1) ::close(fd_);
        fd_ = fd;
    }

    // Move-only
    unique_fd(const unique_fd&) = delete;
    unique_fd& operator=(const unique_fd&) = delete;
};""",
             notes=(
                 "Twenty lines. Move-only, automatic close on destruction, "
                 "no-throw guarantees on every operation that matters. "
                 "Mark it move-only because copying a file descriptor "
                 "doesn't have one canonical meaning — you'd want dup() "
                 "which is its own operation.\n\n"
                 "Three usage patterns. First, factory function: "
                 "make_unique_fd(open(...)) returns by value, RVO elides "
                 "the move. Second, member ownership: a class holding a "
                 "socket holds a unique_fd member, and the class's "
                 "destructor closes it for free. Third, function-local: "
                 "the fd lives until end of scope, including exception "
                 "paths.\n\n"
                 "What RAII does NOT save you from: lifetime extension "
                 "via raw pointers to RAII-owned memory; dangling "
                 "references when ownership is shared across threads "
                 "without a synchronization primitive; cross-process "
                 "resources that don't have a destructor at all (shared "
                 "memory segments, named semaphores). For those, you need "
                 "explicit cleanup hooks — typically std::atexit or a "
                 "signal handler that releases on SIGTERM. Section 7 "
                 "covers the LinuxMemoryChecker pattern that handles the "
                 "OOM signal case."
             )),
        dict(kind="content",
             title="What RAII doesn't fix",
             body=[
                 heading("Resources RAII handles cleanly", color=C.ACCENT_GREEN),
                 bullet("Memory (unique_ptr, vector, string, etc.)"),
                 bullet("File descriptors (with a wrapper like unique_fd)"),
                 bullet("Mutexes (lock_guard, scoped_lock)"),
                 bullet("Sockets via Asio / standalone-asio"),
                 dict(text="", size=Pt(6)),
                 heading("Resources that need explicit cleanup", color=C.ACCENT_ORANGE),
                 bullet("Cross-process: shared memory segments, named semaphores"),
                 bullet("OS-level: signal handlers must release before SIGTERM"),
                 bullet("PMR arenas: the memory_resource must outlive the allocator (§7)"),
                 dict(text="", size=Pt(6)),
                 heading("Anti-patterns that defeat RAII", color=C.ACCENT_RED),
                 bullet("Holding raw pointers/references to RAII-owned memory across scopes"),
                 bullet("`shared_ptr` cycles — they leak silently"),
                 bullet("`exit()` calls — destructors don't run on exit() vs return from main()"),
             ],
             notes=(
                 "Three categories. First, what RAII handles cleanly: "
                 "memory in any standard container or smart pointer, file "
                 "descriptors via a wrapper, mutexes via lock_guard or "
                 "scoped_lock, sockets via Asio.\n\n"
                 "Second, what needs explicit cleanup: cross-process "
                 "resources don't have automatic destruction at process "
                 "exit. Shared memory segments need explicit "
                 "shm_unlink(). Named semaphores need sem_unlink(). OS "
                 "signals — if your service needs to release something "
                 "before SIGTERM cleanly terminates the process, you wire "
                 "up a signal handler. PMR arenas: a polymorphic_allocator "
                 "holds a pointer to a memory_resource. The arena must "
                 "outlive the allocator — section 7 has the bug catalog.\n\n"
                 "Third, anti-patterns. Holding raw pointers or references "
                 "to RAII-owned memory across scopes — classic dangling "
                 "reference, the borrow checker would have caught it. "
                 "shared_ptr cycles leak silently, weak_ptr breaks them. "
                 "And calling exit() bypasses destructors — that's a "
                 "fatality if your destructors do something important like "
                 "flushing a write-ahead log. Use std::quick_exit or just "
                 "return from main."
             )),
    ],
},

# ============================================================================
# §4 — Container strategy
# ============================================================================
{
    "num": 4,
    "label": "Section 04",
    "title": "Container strategy",
    "tagline": "UBI vs ubi-micro vs scratch + multi-stage builds = Demo 1",
    "divider_notes": (
        "Now we hit Demo 1 territory. Container strategy: which base image, "
        "what multi-stage looks like, why the toolchain doesn't belong in "
        "production. The numbers you saw on the gap slide — 689 megabytes "
        "down to 26 — that's this section's measurable."
    ),
    "slides": [
        dict(kind="diagram",
             title="Multi-stage build: separate builder from runtime",
             diagram=f"{DG}/04-image-strategy-multistage.jpg",
             caption="One Containerfile, two stages. The builder has the toolchain; the runtime has the binary.",
             notes=(
                 "Multi-stage builds are the single biggest lever. The "
                 "builder stage has GCC, ld, the C library headers, "
                 "dozens of build dependencies. The runtime stage has "
                 "your binary plus its shared library closure.\n\n"
                 "The COPY between stages is where the magic happens. "
                 "You COPY --from=builder /app/build/svc /usr/local/bin/svc. "
                 "That's it. Nothing from the builder stage exists in the "
                 "final image except the bytes you explicitly copy.\n\n"
                 "Three variants we'll measure in Demo 1: single-stage "
                 "naive (the anti-pattern, builder and runtime in one "
                 "image, 689 MB); ubi-multistage (builder is ubi9, runtime "
                 "is ubi9-minimal, 114 MB); ubi-micro (builder is ubi9, "
                 "runtime is ubi9-micro with static libstdc++, 26 MB). "
                 "Twenty-six-fold size reduction; same C++ source code; "
                 "same runtime performance for our HTTP echo service. The "
                 "only thing you trade is debug surface — ubi-micro has "
                 "no shell, no package manager, no debugger."
             )),
        dict(kind="stat-row",
             title="Demo 1 — three variants, measured",
             stats=[
                 ("689 MB", "single-stage naive\n(builder + runtime)", C.ACCENT_RED),
                 ("114 MB", "ubi-multistage\n(ubi9 + ubi9-minimal)", C.ACCENT_ORANGE),
                 ("26 MB", "ubi-micro\n(static libstdc++)", C.ACCENT_GREEN),
                 ("4-5%", "PGO improvement\nat p99 (on top of LTO)", C.ACCENT_CYAN),
             ],
             notes=(
                 "Headline numbers from Demo 1. The 689 megabytes is the "
                 "honest baseline — what you get if you copy a "
                 "Containerfile from a blog post that ships the build "
                 "image as the runtime image. Every CVE that ships with "
                 "gcc is in your production image at that point. Every "
                 "new ld release means your registry pull gets bigger.\n\n"
                 "ubi-multistage takes you down to 114 MB. Same C++ "
                 "binary, just produced in a separate stage and copied "
                 "into a runtime image that doesn't have a compiler. "
                 "Six-fold reduction, same runtime perf, dramatically "
                 "smaller CVE surface.\n\n"
                 "ubi-micro is 26 MB. Static libstdc++, no shell, no "
                 "package manager. Suitable for production C++ services "
                 "that don't need glibc NSS modules. If you do need NSS "
                 "or dlopen of glibc-dependent libraries, stay on "
                 "ubi-minimal.\n\n"
                 "The PGO number — 4 to 5 percent at p99, on top of LTO. "
                 "Small in absolute terms, real in aggregate, and free "
                 "once the build pipeline is wired up. Demo 1's PGO step "
                 "instruments, runs a synthetic training workload, "
                 "rebuilds with the profile, and prints the delta."
             )),
        dict(kind="demo-cue",
             demo_num=1,
             demo_name="Demo 1 — Image Strategy",
             demo_command="cd examples/demo-01-image-strategy && ./demo.sh",
             demo_description=(
                 "Builds the same C++23 HTTP service three different ways and adds a PGO pass on top. "
                 "Prints a comparison table: image size, build time, p50/p95/p99 latency for each variant."
             ),
             demo_url="patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/demo-01-image-strategy/",
             notes=(
                 "We're going to run Demo 1 live. The first build is "
                 "five to ten minutes on a fresh cache, about a minute "
                 "after that. We'll see the size deltas immediately and "
                 "the latency comparison once `hey` finishes its load "
                 "run.\n\n"
                 "What to watch for in the output: first the size column "
                 "— that should show the 26× spread between single-stage "
                 "naive and ubi-micro. Then the p50/p95/p99 column — that "
                 "should show very small absolute differences between "
                 "ubi-multistage and ubi-micro (the static libstdc++ doesn't "
                 "cost us anything at runtime), and a meaningful PGO "
                 "improvement on top of plain LTO."
             )),
    ],
},

# ============================================================================
# §5 — Compile-time wins
# ============================================================================
{
    "num": 5,
    "label": "Section 05",
    "title": "Compile-time wins",
    "tagline": "LTO, PGO, constexpr — what each does, when each is worth it",
    "divider_notes": (
        "Still Demo 1 territory but a different lens. LTO and PGO are "
        "the free-ish wins; constexpr is the language feature that "
        "doesn't show up in any compiler flag but compounds across the "
        "codebase. Let's walk each one with its real cost."
    ),
    "slides": [
        dict(kind="diagram",
             title="The PGO pipeline",
             diagram=f"{DG}/05-compile-time-pgo-flow.jpg",
             caption="Two-pass build: instrument → train → optimize. Demo 1's `./demo-pgo.sh` runs it end-to-end.",
             notes=(
                 "PGO is a two-pass build, that's it. First pass: "
                 "compile with -fprofile-generate. The binary writes "
                 "profile data to disk as it runs. Second pass: run a "
                 "training workload against that instrumented binary. "
                 "Realistic load is what makes PGO useful — the profile "
                 "captures which functions are hot and which branches go "
                 "which way. Third pass: recompile with "
                 "-fprofile-use=path. The compiler now knows the hot path "
                 "and can lay out the code accordingly: hot blocks "
                 "inlined, cold blocks moved out of cache, branch "
                 "predictions seeded.\n\n"
                 "Demo 1's PGO script does this end-to-end with a "
                 "synthetic training workload — `hey -n 50000 -c 50`. "
                 "Production teams should capture an actual traffic "
                 "profile, ideally via tcpreplay against the "
                 "instrumented binary, but the synthetic version "
                 "demonstrates the mechanics."
             )),
        dict(kind="content-code",
             title="LTO and PGO in CMakePresets",
             body=[
                 para("Adding LTO and PGO is a few lines per preset:"),
             ],
             code="""{
  "configurePresets": [
    {
      "name": "release-lto",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Release",
        "CMAKE_INTERPROCEDURAL_OPTIMIZATION": "ON"
      }
    },
    {
      "name": "release-pgo-gen",
      "inherits": "release-lto",
      "cacheVariables": {
        "CMAKE_CXX_FLAGS": "-fprofile-generate=/tmp/pgo"
      }
    },
    {
      "name": "release-pgo-use",
      "inherits": "release-lto",
      "cacheVariables": {
        "CMAKE_CXX_FLAGS": "-fprofile-use=/tmp/pgo"
      }
    }
  ]
}""",
             notes=(
                 "Four presets that compose. release-lto turns on "
                 "CMAKE_INTERPROCEDURAL_OPTIMIZATION which translates to "
                 "-flto in GCC and Clang. That's it for LTO.\n\n"
                 "release-pgo-gen inherits from release-lto and adds "
                 "-fprofile-generate. This is the instrumented build. "
                 "Run the training workload against this binary.\n\n"
                 "release-pgo-use inherits from release-lto and adds "
                 "-fprofile-use, pointing at the same path. This is the "
                 "final optimized build. The compiler reads the profile "
                 "data from the training run and bakes the hot/cold "
                 "layout into the binary.\n\n"
                 "Build time impact: LTO adds about 30 percent to the "
                 "build wall-clock. PGO adds another pass plus the "
                 "training run, so the full PGO build is roughly 2× the "
                 "LTO build. Do PGO only on release branches in CI; do "
                 "LTO on every release."
             )),
        dict(kind="content",
             title="constexpr — the underused lever",
             body=[
                 para("C++20/23 made constexpr substantially more powerful. Three patterns worth knowing:"),
                 dict(text="", size=Pt(8)),
                 heading("1. constexpr containers", color=C.ACCENT_BLUE),
                 bullet("std::vector, std::string are constexpr-friendly in C++20"),
                 bullet("Build lookup tables at compile time — zero runtime cost"),
                 heading("2. consteval functions", color=C.ACCENT_BLUE),
                 bullet("'must be evaluated at compile time' — stronger than constexpr"),
                 bullet("Use for: config parsing, FNV/CRC of compile-time strings, dimensional checks"),
                 heading("3. constexpr std::format (C++23)", color=C.ACCENT_BLUE),
                 bullet("Format strings checked at compile time"),
                 bullet("Type mismatches become compile errors, not runtime exceptions"),
                 dict(text="", size=Pt(8)),
                 para("Demo 1's HTTP service uses constexpr for its routing table — zero allocation at startup.",
                      italic=True),
             ],
             notes=(
                 "Three constexpr patterns that show up in modern C++ "
                 "codebases.\n\n"
                 "First: constexpr containers. In C++20, std::vector and "
                 "std::string became constexpr-friendly. You can build "
                 "lookup tables at compile time — for instance, a "
                 "perfect-hash router that's computed once during "
                 "compilation and embedded as a literal in the binary. "
                 "Zero runtime cost for the table construction.\n\n"
                 "Second: consteval. The 'must be evaluated at compile "
                 "time' qualifier. Strict — the compiler emits an error "
                 "if the inputs aren't constant expressions. Use for "
                 "things like FNV or CRC of compile-time strings (route "
                 "matching), dimensional analysis (a unit system that "
                 "rejects unit-mismatched arithmetic at compile time), "
                 "config parsing that should fail at build time, not "
                 "runtime.\n\n"
                 "Third: constexpr std::format in C++23. The format "
                 "string is checked at compile time, so type mismatches "
                 "become compile errors instead of runtime exceptions. "
                 "This is the kind of change that becomes invisible once "
                 "you have it — a class of bug just stops happening.\n\n"
                 "Demo 1's HTTP service uses a constexpr routing table — "
                 "zero allocation at startup, all the path-matching is "
                 "done by perfect-hash lookups computed by the compiler."
             )),
    ],
},

# ============================================================================
# §6 — STL & layout
# ============================================================================
{
    "num": 6,
    "label": "Section 06",
    "title": "STL, layout & C++20/23 containers",
    "tagline": "Cache locality beats algorithmic complexity at the scales that matter",
    "divider_notes": (
        "Demo 2 territory. The data-structure question. Most C++ services "
        "default to std::unordered_map because the textbook says O(1). "
        "At small N that's right; at the scales most production services "
        "operate, cache locality dominates and the contiguous alternatives "
        "win. C++20 added std::flat_map and std::flat_set specifically "
        "because this lesson keeps getting relearned."
    ),
    "slides": [
        dict(kind="diagram",
             title="Flat vs node-based: cache behavior",
             diagram=f"{DG}/06-stl-layout-flat-vs-node.jpg",
             caption="Node containers scatter allocations; flat containers stay contiguous and stream from prefetcher.",
             notes=(
                 "Picture is the story. Node-based containers — std::map, "
                 "std::unordered_map, std::list, std::set — allocate each "
                 "element separately and scatter them across the heap. "
                 "Following a pointer means a cache miss. At N=262K, "
                 "the working set doesn't fit in L2; every iteration is "
                 "a memory load.\n\n"
                 "Flat containers — boost::container::flat_map, vector "
                 "with linear scan, std::flat_map in C++23 — keep "
                 "elements contiguous. The hardware prefetcher reads "
                 "ahead. The working set streams in at memory bandwidth, "
                 "limited only by DRAM, not by cache miss latency.\n\n"
                 "The numbers we'll see in Demo 2: at N=262144 on "
                 "iterate-and-sum, flat_map and vector-linear-scan both "
                 "finish in around 900 microseconds. std::unordered_map "
                 "takes 2.3 milliseconds. std::map takes 32 milliseconds. "
                 "Same workload, same hardware. The choice of container "
                 "made a 35× difference."
             )),
        dict(kind="stat-row",
             title="Demo 2 — N=262K iterate-and-sum",
             stats=[
                 ("0.9 ms", "boost::flat_map\n(sorted vector)", C.ACCENT_GREEN),
                 ("0.9 ms", "vector<pair> +\nlinear scan", C.ACCENT_GREEN),
                 ("2.3 ms", "std::unordered_map\n(hash table)", C.ACCENT_ORANGE),
                 ("32 ms", "std::map\n(RB tree)", C.ACCENT_RED),
             ],
             notes=(
                 "Four containers, same workload, four very different "
                 "outcomes. boost::flat_map and vector with linear scan "
                 "are tied — both are contiguous, the hardware prefetcher "
                 "treats them identically. About 900 microseconds for "
                 "262 thousand elements.\n\n"
                 "std::unordered_map is 2.5× slower. The hash table itself "
                 "is fast, but every bucket entry is a separately-allocated "
                 "node. Cache misses on every lookup.\n\n"
                 "std::map is 35× slower than flat_map. The combination "
                 "of node-based allocation AND branch-heavy traversal "
                 "(red-black tree rotations don't help the predictor) "
                 "is the worst case.\n\n"
                 "The flat container wins are bigger under cgroup memory "
                 "pressure — the pressured run has unordered_map at 5.8 ms "
                 "and std::map at 210 ms. The kernel is evicting pages "
                 "the node containers then have to fault back in. "
                 "Flat containers stream from disk if needed and stay "
                 "fast."
             )),
        dict(kind="content",
             title="When to use what",
             body=[
                 heading("Use flat_map / sorted vector when:", color=C.ACCENT_GREEN),
                 bullet("N > a few thousand (working set spans cache levels)"),
                 bullet("Iteration is the dominant operation"),
                 bullet("Inserts are infrequent or in sorted order"),
                 bullet("You can pay O(N) on insert for O(N) cache-friendly iteration"),
                 heading("Use unordered_map when:", color=C.ACCENT_BLUE),
                 bullet("Lookups are dominant, insert/iterate are rare"),
                 bullet("Keys are expensive to compare (e.g., long strings)"),
                 bullet("You have a good hash function"),
                 heading("Use std::map only when:", color=C.ACCENT_ORANGE),
                 bullet("You specifically need ordered iteration AND incremental insert"),
                 bullet("(Otherwise, flat_map with reserve() wins decisively)"),
             ],
             notes=(
                 "Decision rules. Use flat_map or sorted vector when N is "
                 "more than a few thousand — meaning the working set is "
                 "going to span cache levels — and iteration is your "
                 "dominant operation. Insert cost is O(N) because you "
                 "have to shift the tail, but if your insert frequency "
                 "is much lower than iterate frequency, that's a fine "
                 "trade.\n\n"
                 "Use unordered_map when lookups dominate. The hash table "
                 "is fast for point queries; the cache-miss cost only "
                 "shows up when you're iterating across many elements. "
                 "Service with millions of named connections by FD — "
                 "unordered_map. Service iterating across all active "
                 "sessions to compute aggregate state — flat_map.\n\n"
                 "Use std::map only when you specifically need ordered "
                 "iteration combined with incremental insert. If you can "
                 "batch your inserts and reserve, flat_map dominates. The "
                 "case for std::map is narrow."
             )),
        dict(kind="demo-cue",
             demo_num=2,
             demo_name="Demo 2 — STL Layout Under Pressure",
             demo_command="cd examples/demo-02-stl-layout && ./demo.sh",
             demo_description=(
                 "Benchmarks four container designs at four sizes on two operations, run twice — "
                 "unconstrained and under a 128 MB cgroup memory cap. Prints a side-by-side table."
             ),
             demo_url="patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/demo-02-stl-layout/",
             notes=(
                 "Demo 2. First build is 3-5 minutes, subsequent runs about "
                 "30 seconds.\n\n"
                 "Two runs back to back: baseline (no cgroup limit), then "
                 "pressured (--memory=128m). The output is a comparison "
                 "table with all four containers across four sizes, with a "
                 "pressure-ratio column. Watch the pressure-ratio column "
                 "for the node-based containers — that's where you see "
                 "the page-eviction cost compound."
             )),
    ],
},

# ============================================================================
# §7 — Memory management
# ============================================================================
{
    "num": 7,
    "label": "Section 07",
    "title": "Memory management",
    "tagline": "Allocators, huge pages, cgroups v2, OOM — Demo 6",
    "divider_notes": (
        "Memory management. This is the section where most production "
        "C++ services have the most room to improve. The default "
        "allocator is fine until it isn't; PMR opens up arena-style "
        "designs; mimalloc as a drop-in replacement is a real production "
        "default at large shops. We're going to measure all three "
        "against the same allocator-stress workload in Demo 6."
    ),
    "slides": [
        dict(kind="diagram",
             title="The allocator stack",
             diagram=f"{DG}/07-allocator-stack.jpg",
             caption="Three layers — language-level, allocator implementation, kernel boundary. Each one matters.",
             notes=(
                 "Three layers. At the top, language-level: "
                 "std::allocator (the default), std::pmr::polymorphic_allocator "
                 "(the C++17 way to swap allocation strategy without "
                 "changing type signatures), and custom allocators. The "
                 "language layer determines what your data structures "
                 "look like.\n\n"
                 "Middle: the actual malloc implementation. glibc's "
                 "ptmalloc is the default — fine for general workloads, "
                 "lock-heavy under multi-threaded allocation pressure. "
                 "mimalloc is Microsoft's drop-in replacement — "
                 "per-thread heaps, lock-free free-list management, "
                 "aggressive size-class consolidation. jemalloc is "
                 "Facebook's — similar goals, different tuning. tcmalloc "
                 "is Google's.\n\n"
                 "Bottom: the kernel boundary. mmap, brk, the memory "
                 "control group, transparent huge pages. This is where "
                 "memory.max and memory.high live. This is also where "
                 "the OOM killer makes its decisions."
             )),
        dict(kind="stat-row",
             title="Demo 6 — same workload, three allocators",
             stats=[
                 ("4.08 µs", "std::pmr\n(monotonic + sync_pool)\np50", C.ACCENT_GREEN),
                 ("8.66 µs", "std::allocator\n(default glibc malloc)\np50", C.ACCENT_ORANGE),
                 ("9.77 µs", "mimalloc\n(static-linked)\np50", C.ACCENT_BLUE),
                 ("2.1×", "PMR speedup vs\nstd::allocator on this\nbatch workload", C.ACCENT_CYAN),
             ],
             notes=(
                 "Headline results from Demo 6's batch mode. PMR with a "
                 "monotonic_buffer_resource backed by sync_pool wins "
                 "decisively — 4 microseconds versus 8.66 for std::allocator "
                 "and 9.77 for mimalloc. p99 is even more dramatic: 5.6 "
                 "for PMR, 15.3 for std::allocator, 17.2 for mimalloc.\n\n"
                 "Why does PMR win here? The workload is bursty — JSON-like "
                 "parsing with many short-lived small allocations. PMR's "
                 "monotonic_buffer_resource is a bump allocator: every "
                 "allocation is a pointer-bump, every deallocation is a "
                 "no-op, and the whole arena resets in O(1) between "
                 "request cycles. That's a really good fit for this "
                 "workload pattern.\n\n"
                 "Why does mimalloc not win here? Because the workload is "
                 "single-threaded. mimalloc's biggest wins are in "
                 "multi-threaded allocation pressure — per-thread heaps "
                 "eliminate the lock contention that ptmalloc suffers "
                 "from. In a single thread, mimalloc is comparable to "
                 "glibc malloc, sometimes slightly slower because of "
                 "additional bookkeeping.\n\n"
                 "The takeaway: allocator choice is workload-specific. "
                 "Measure your own workload. Don't take Demo 6's numbers "
                 "as universal."
             )),
        dict(kind="content",
             title="cgroups v2: memory.max vs memory.high",
             body=[
                 heading("memory.max — the hard limit", color=C.ACCENT_RED),
                 bullet("OOM killer fires when allocation crosses this line"),
                 bullet("Use for: 'I want a hard stop'; tenant isolation; security"),
                 bullet("Failure mode: pod terminates mid-request, often unfair to the user that triggered it"),
                 dict(text="", size=Pt(6)),
                 heading("memory.high — the soft pressure point", color=C.ACCENT_ORANGE),
                 bullet("Kernel proactively reclaims pages when usage exceeds this"),
                 bullet("Process keeps running, but allocation slows under memory.high pressure"),
                 bullet("Use for: 'I want adaptive backpressure'; well-behaved services"),
                 dict(text="", size=Pt(6)),
                 heading("Best practice", color=C.ACCENT_GREEN),
                 bullet("Set memory.high ~10-15% below memory.max"),
                 bullet("Service code monitors RSS via the LinuxMemoryChecker pattern"),
                 bullet("Trim caches proactively before kernel pressure hits"),
             ],
             notes=(
                 "memory.max is the hard limit — the line where the OOM "
                 "killer fires. Use it for security and tenant isolation: "
                 "you want a hard guarantee that one tenant can't eat "
                 "more than N gigabytes. The failure mode is that your "
                 "pod terminates mid-request, often unfair to the request "
                 "that happened to push usage over the line.\n\n"
                 "memory.high is the soft pressure point. When usage "
                 "exceeds memory.high, the kernel starts proactively "
                 "reclaiming pages — your process keeps running, but "
                 "allocation slows. It's adaptive backpressure rather "
                 "than a cliff.\n\n"
                 "Best practice: set memory.high about 10-15 percent "
                 "below memory.max. The gap gives you headroom to react. "
                 "Your service code monitors its own RSS via the "
                 "LinuxMemoryChecker pattern — when RSS approaches "
                 "memory.high, the service trims caches, calls "
                 "malloc_trim, sheds load. The kernel never has to apply "
                 "pressure because the application got ahead of it.\n\n"
                 "Trino has this; Presto has this. Section 11 has the "
                 "code pattern."
             )),
        dict(kind="demo-cue",
             demo_num=6,
             demo_name="Demo 6 — Memory Management & Allocators",
             demo_command="cd examples/demo-06-memory-and-allocators && ./demo.sh",
             demo_description=(
                 "Three execution modes: batch (no HTTP overhead), serve (HTTP), observe (OTel + LGTM). "
                 "Compares std::allocator vs PMR vs mimalloc on a synthetic JSON-shaped workload."
             ),
             demo_url="patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/demo-06-memory-and-allocators/",
             notes=(
                 "Demo 6 is the meatiest one. First build takes 30-60 "
                 "minutes with OTel enabled because the OTel C++ SDK "
                 "rebuilds from source. We'll use a pre-built image for "
                 "the demo today.\n\n"
                 "Three modes. Batch mode is what gives the cleanest "
                 "signal — the 4.08 microsecond PMR number. Serve mode "
                 "shows what happens under sustained HTTP load — the "
                 "PMR advantage shrinks because the arena buffer evicts "
                 "between requests. Observe mode runs the same workload "
                 "with full OpenTelemetry instrumentation against the "
                 "LGTM stack — you can see the per-allocator latency "
                 "distribution in Grafana."
             )),
    ],
},

# ============================================================================
# §8 — I/O latency
# ============================================================================
{
    "num": 8,
    "label": "Section 08",
    "title": "I/O latency",
    "tagline": "io_uring, async gRPC, SO_REUSEPORT — Demo 3",
    "divider_notes": (
        "I/O. The most consequential Linux change of the past decade. "
        "Where epoll asks 'is this fd ready', io_uring lets you batch "
        "submissions, get completions back asynchronously, and avoid "
        "the per-call syscall cost that dominates traditional async "
        "patterns. We'll measure direct liburing against Asio's "
        "io_uring backend against async gRPC — all three in one binary "
        "in Demo 3."
    ),
    "slides": [
        dict(kind="diagram",
             title="io_uring: submission + completion rings",
             diagram=f"{DG}/08-io-uring-rings.jpg",
             caption="One syscall (io_uring_enter) submits and collects many operations. Per-call syscall cost amortizes to zero.",
             notes=(
                 "The model. Two shared memory ring buffers between "
                 "userspace and kernel. The submission queue: userspace "
                 "writes SQEs (Submission Queue Entries) describing the "
                 "I/O operations to perform. The completion queue: the "
                 "kernel writes CQEs (Completion Queue Entries) once the "
                 "operations finish.\n\n"
                 "The magic is one syscall. io_uring_enter() submits "
                 "whatever's been queued and (optionally) waits for "
                 "completions. With multishot accept and multishot recv, "
                 "you submit one SQE and get a CQE per arrived "
                 "connection or per arrived byte. Per-call syscall cost "
                 "amortizes toward zero.\n\n"
                 "Compare to epoll. epoll_wait returns 'these fds are "
                 "ready', then you call read() or recv() on each — one "
                 "syscall per ready event. io_uring eliminates the "
                 "epoll_wait round trip entirely AND lets you submit the "
                 "next operation in the same syscall. That's where the "
                 "throughput gain comes from."
             )),
        dict(kind="stat-row",
             title="Demo 3 — three servers, same protocol",
             stats=[
                 ("274K req/s", "Direct liburing\n(raw submission ring)\np99: 181 µs", C.ACCENT_GREEN),
                 ("349K req/s", "Asio io_uring\n(executor wrapped)\np99: 110 µs", C.ACCENT_CYAN),
                 ("4.85K req/s", "Async gRPC\n(callback API + framing)\np99: 30.92 ms", C.ACCENT_ORANGE),
                 ("100×", "throughput gap:\nraw TCP echo vs\ngRPC with framing", C.ACCENT_RED),
             ],
             notes=(
                 "Three servers, all in one binary in Demo 3.\n\n"
                 "Direct liburing TCP echo on port 9000: 274,000 requests "
                 "per second, p99 of 181 microseconds. That's a "
                 "hand-rolled state machine — accept, read, write, read "
                 "— using io_uring directly. Minimum userland overhead.\n\n"
                 "Asio io_uring TCP echo on port 9001: 349,000 requests "
                 "per second, p99 of 110 microseconds. Same kernel calls "
                 "underneath, but Asio batches submissions more "
                 "aggressively and uses provided-buffer rings. Same "
                 "protocol, Asio actually wins. The takeaway: 'direct "
                 "always beats wrapped' is not always true. The userland "
                 "strategy matters more than direct-vs-wrapped framing.\n\n"
                 "Async gRPC on port 50051: 4,850 requests per second, "
                 "p99 of 31 milliseconds. Two orders of magnitude slower "
                 "than raw TCP echo. That's the cost of framing, HPACK "
                 "header coding, deadline tracking, the completion-queue "
                 "trampoline, and the deserialization of protobuf "
                 "messages.\n\n"
                 "gRPC isn't slow. TCP echo with no semantics is just "
                 "the floor. The right comparison is gRPC against your "
                 "previous gRPC build, not against a benchmark that does "
                 "nothing."
             )),
        dict(kind="content",
             title="When io_uring is worth the complexity",
             body=[
                 heading("Strong fit", color=C.ACCENT_GREEN),
                 bullet("High connection counts (>10K concurrent)"),
                 bullet("Mixed I/O patterns (sockets + files + timers in one ring)"),
                 bullet("Multishot accept saves epoll churn at the listen socket"),
                 bullet("Provided-buffer rings for variable-size reads"),
                 heading("Weak fit", color=C.ACCENT_ORANGE),
                 bullet("Single connection, low throughput — epoll is fine"),
                 bullet("Older kernels (<6.0) — many features absent"),
                 bullet("Strict seccomp / SELinux setups — needs allowlist work (§9)"),
                 heading("Production wrappers", color=C.ACCENT_BLUE),
                 bullet("standalone-asio (or boost::asio) with ASIO_HAS_IO_URING"),
                 bullet("Liburing for hot loops where overhead matters"),
                 bullet("seastar for the more opinionated all-in-one approach"),
             ],
             notes=(
                 "When io_uring is worth the complexity. Strong fit: high "
                 "connection counts above 10,000 concurrent — multishot "
                 "accept saves epoll churn at the listen socket and you "
                 "get one CQE per arrived connection. Mixed I/O patterns: "
                 "sockets plus files plus timers all in one ring is a big "
                 "win over epoll + posix-aio. Provided-buffer rings: the "
                 "kernel pulls a buffer from a pool you registered, no "
                 "userland-side buffer management.\n\n"
                 "Weak fit: low-throughput single connection — epoll is "
                 "fine and io_uring is overkill. Older kernels below 6.0 — "
                 "many features are absent. Strict seccomp or SELinux "
                 "setups — io_uring needs allowlist work, section 9 "
                 "covers that.\n\n"
                 "Production wrappers: standalone-asio with "
                 "ASIO_HAS_IO_URING is what we used in Demo 3 because "
                 "the Conan build is much simpler than boost::asio. The "
                 "C++ source is identical except for the namespace. "
                 "Direct liburing for hot loops where the wrapper "
                 "overhead matters. seastar is the more opinionated "
                 "all-in-one approach if you're greenfield."
             )),
        dict(kind="demo-cue",
             demo_num=3,
             demo_name="Demo 3 — io_uring + Async gRPC",
             demo_command="cd examples/demo-03-io-uring-grpc && ./demo.sh",
             demo_description=(
                 "Three servers in one binary — direct liburing, Asio io_uring, async gRPC — driven "
                 "by ghz and tcp-loadgen, all wired into the LGTM observability stack."
             ),
             demo_url="patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/demo-03-io-uring-grpc/",
             notes=(
                 "Demo 3. First build is 30-45 minutes because of the "
                 "OTel + gRPC dependency chain — those are big projects. "
                 "Subsequent runs are 2-3 minutes.\n\n"
                 "The script brings up the LGTM stack alongside the "
                 "service, runs ghz against the gRPC endpoint for 10 "
                 "seconds, runs tcp-loadgen against both TCP echo ports, "
                 "and prints the side-by-side summary. Then Grafana at "
                 "127.0.0.1:3000 has the gRPC histogram and counters."
             )),
    ],
},

# ============================================================================
# §9 — Networking & kernel parameters
# ============================================================================
{
    "num": 9,
    "label": "Section 09",
    "title": "Networking & kernel parameters",
    "tagline": "veth vs host networking; sysctl tuning; the kernel knobs that matter",
    "divider_notes": (
        "Still Demo 3 territory but a different angle. Rootless Podman "
        "uses slirp4netns for default networking — a userspace TCP/IP "
        "stack. That's a real cost. Host networking eliminates it but "
        "trades isolation for performance. We'll cover when each is "
        "right, plus the sysctl tuning that matters for low-latency C++ "
        "services."
    ),
    "slides": [
        dict(kind="diagram",
             title="veth pairs vs --network=host",
             diagram=f"{DG}/09-networking-veth-vs-host.jpg",
             caption="Default rootless networking uses slirp4netns. --network=host eliminates the userspace stack at the cost of port-namespace isolation.",
             notes=(
                 "Two networking modes, very different cost profiles.\n\n"
                 "Default rootless: slirp4netns. Userspace TCP/IP stack "
                 "that translates between the container's network "
                 "namespace and the host's. Adds 30-50 microseconds per "
                 "packet on a typical Fedora 44 host. For high-throughput "
                 "services that's measurable; for low-rate services it's "
                 "invisible.\n\n"
                 "--network=host: the container shares the host's "
                 "network namespace. No userspace translation, no veth "
                 "pair. Network performance is identical to running "
                 "directly on the host. The trade: you lose port-"
                 "namespace isolation. Two services in two containers "
                 "can't both bind to port 8080.\n\n"
                 "For our demos: most use default networking because "
                 "the loss is in the noise. Demo 3 measures both modes "
                 "and prints the delta — that's where you can see "
                 "whether your particular workload cares."
             )),
        dict(kind="content-code",
             title="Sysctls that matter for C++ services",
             body=[
                 para("Four kernel parameters that account for most measurable network-side gains:"),
             ],
             code="""# Listen queue depth — default 4096 is fine for most;
# bump for high-rate accept workloads:
net.core.somaxconn = 16384

# Connection-tracking table — bump for high concurrent connections:
net.netfilter.nf_conntrack_max = 524288

# Receive/send buffer auto-tuning — defaults are usually OK,
# raise the upper bound for fat-pipe workloads:
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# TCP SACK and timestamps — leave ON (defaults). Some old guides
# said to disable for perf; that advice was wrong.
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1""",
             notes=(
                 "Four sysctls that account for most network-side gains.\n\n"
                 "net.core.somaxconn — listen queue depth. Default is "
                 "4096; for high-rate accept workloads bump to 16384 or "
                 "32768. The application also has to pass a backlog "
                 "value to listen() that's at least this high or it gets "
                 "clamped.\n\n"
                 "net.netfilter.nf_conntrack_max — the connection-"
                 "tracking table. If your service handles many concurrent "
                 "connections and you're behind a NAT, default 65536 "
                 "fills up and drops. Bump it.\n\n"
                 "net.ipv4.tcp_rmem and tcp_wmem — receive and send "
                 "buffer auto-tuning ranges. Defaults are usually OK; "
                 "raise the upper bound for high-bandwidth-delay-product "
                 "links — fat pipes with long RTTs.\n\n"
                 "TCP SACK and timestamps: leave ON. Some old guides "
                 "said to disable them for performance. That was wrong "
                 "advice — they're cheap, they help recovery from packet "
                 "loss, and modern kernels are tuned for them on."
             )),
        dict(kind="content",
             title="SO_REUSEPORT — parallel listeners on one port",
             body=[
                 heading("What it does", color=C.ACCENT_BLUE),
                 bullet("Multiple processes/threads listen on the same port"),
                 bullet("Kernel distributes incoming connections across them"),
                 bullet("Distribution is by connection 4-tuple hash — sticky per connection"),
                 dict(text="", size=Pt(6)),
                 heading("When it helps", color=C.ACCENT_GREEN),
                 bullet("Single-threaded async services scaling out by process count"),
                 bullet("Avoiding accept() contention on the listen socket"),
                 bullet("Demo 3's TCP echo servers use it — two listeners share :9000"),
                 dict(text="", size=Pt(6)),
                 heading("Caveats", color=C.ACCENT_ORANGE),
                 bullet("Connection load distribution is hash-based, not round-robin"),
                 bullet("Some flows will land on the same worker (cache friendly, sometimes hot)"),
                 bullet("Kernel >= 3.9 required; rootless restrictions on some systems"),
             ],
             notes=(
                 "SO_REUSEPORT. Multiple processes or threads bind to the "
                 "same port; the kernel distributes incoming connections "
                 "across the listeners by hashing the connection 4-tuple. "
                 "Same connection always lands on the same listener — "
                 "cache-friendly, but means load isn't perfectly "
                 "round-robin.\n\n"
                 "When it helps: single-threaded async services scaling "
                 "out by process count. Each worker binds to the same "
                 "port and the kernel handles distribution. Avoids "
                 "accept() contention on a single listen socket — that's "
                 "the thundering herd problem.\n\n"
                 "Demo 3 uses SO_REUSEPORT on both TCP echo ports. You "
                 "can run multiple copies of the demo container and they "
                 "share the listen port; kernel distributes connections.\n\n"
                 "Caveats: load distribution is hash-based, so some flows "
                 "will cluster on the same worker. If a particular flow "
                 "is hot — say, one client sending the bulk of traffic — "
                 "you'll see that worker take the load. Usually fine; "
                 "occasionally surprising."
             )),
    ],
},

# ============================================================================
# §10 — Observability & profiling
# ============================================================================
{
    "num": 10,
    "label": "Section 10",
    "title": "Observability & profiling",
    "tagline": "OTel + Grafana LGTM stack + perf + eBPF — Demo 4",
    "divider_notes": (
        "Observability. Three signals — traces, metrics, logs — from "
        "OpenTelemetry, all going to the Grafana LGTM stack. Plus "
        "host-side observability: perf for CPU sampling, bcc-tools for "
        "off-CPU and syscall analysis, bpftrace for ad-hoc kernel "
        "probes. The application-layer signals tell you 'what'; the "
        "host-layer signals tell you 'why'."
    ),
    "slides": [
        dict(kind="diagram",
             title="The OTel + LGTM data flow",
             diagram=f"{DG}/10-observability-otel-stack.jpg",
             caption="Three OTLP signals from the C++ SDK → grafana/otel-lgtm all-in-one → three datasources in Grafana.",
             notes=(
                 "Three signals, one collector, three backends, one "
                 "Grafana.\n\n"
                 "The C++ service uses opentelemetry-cpp SDK. It emits "
                 "OTLP for all three signals — gRPC by default, HTTP/"
                 "protobuf as an alternative. All three go to one "
                 "endpoint: the collector inside grafana/otel-lgtm.\n\n"
                 "The collector splits the signals: traces go to Tempo, "
                 "metrics go to Mimir (Prometheus-compatible storage), "
                 "logs go to Loki. Grafana has all three as datasources "
                 "and can pivot between them via trace_id — click a span "
                 "in Tempo, jump to the matching log lines in Loki, see "
                 "the metric values at that timestamp in Mimir.\n\n"
                 "The grafana/otel-lgtm image bundles all of this into "
                 "one container. Production deployments would split "
                 "these out — separate Tempo cluster, separate Loki "
                 "cluster, etc. The tutorial setup is the demo-friendly "
                 "version."
             )),
        dict(kind="stat-row",
             title="The OTel Simple→Batch processor decision",
             stats=[
                 ("8.5×", "throughput recovery after switching\nfrom Simple to Batch span processor", C.ACCENT_GREEN),
                 ("Per-span", "Simple processor: one\nsynchronous export per span", C.ACCENT_RED),
                 ("Batched", "Batch processor: accumulate +\nflush every N or every T ms", C.ACCENT_GREEN),
                 ("§14", "Pitfall: shipped Simple\nin a Helm chart, lost 88% throughput", C.ACCENT_ORANGE),
             ],
             notes=(
                 "A real production trap. The OpenTelemetry C++ SDK ships "
                 "with both SimpleSpanProcessor and BatchSpanProcessor. "
                 "Simple is great for debugging — every span goes out "
                 "synchronously, you see it in the backend immediately. "
                 "Batch is what production needs — accumulate spans, "
                 "flush every N or every T ms.\n\n"
                 "If you copy a starter Helm chart that uses Simple and "
                 "ship it to production, you can lose 80-90 percent of "
                 "your throughput. We've seen this happen. The fix is "
                 "literally a one-line change in the OTel init code. "
                 "Section 14 has the runbook entry; Demo 6's observe mode "
                 "shows the measured recovery: 8.5× throughput "
                 "improvement going from Simple to Batch on our test "
                 "workload."
             )),
        dict(kind="content",
             title="Three host-side complements",
             body=[
                 heading("perf — CPU sampling", color=C.ACCENT_BLUE),
                 bullet("perf record -F 99 -g -p $(pidof svc) sleep 30"),
                 bullet("Flame graphs via Brendan Gregg's FlameGraph repo"),
                 bullet("Tells you which functions burn CPU — application-layer doesn't see this"),
                 dict(text="", size=Pt(6)),
                 heading("bcc-tools — off-CPU & syscall analysis", color=C.ACCENT_GREEN),
                 bullet("tcpconnect, tcpaccept, tcpretrans, tcptracer — connection-level events"),
                 bullet("opensnoop, execsnoop — file/process activity"),
                 bullet("syscount — syscall histograms (great for io_uring perf debugging)"),
                 dict(text="", size=Pt(6)),
                 heading("bpftrace — ad-hoc kernel probes", color=C.ACCENT_PURPLE),
                 bullet("One-liners against tracepoints, kprobes, uprobes"),
                 bullet("`bpftrace -e 'tracepoint:sched:sched_switch /pid==1234/ { @[comm] = count(); }'`"),
                 bullet("Catches scheduler-induced p99 spikes that OTel can't see"),
             ],
             notes=(
                 "Three host-side tools that complement OTel because they "
                 "see things the application can't.\n\n"
                 "perf for CPU sampling. Run perf record at 99 Hz against "
                 "your service PID for 30 seconds, get a stack-sampling "
                 "profile. Render as a flame graph using Brendan Gregg's "
                 "FlameGraph repo. Tells you which functions are eating "
                 "CPU — your OTel spans see request boundaries, not "
                 "function-level cost. Perf fills that gap.\n\n"
                 "bcc-tools for off-CPU and syscall analysis. tcpconnect, "
                 "tcpaccept, tcpretrans, tcptracer for connection-level "
                 "events. opensnoop and execsnoop for file and process "
                 "activity. syscount for syscall histograms — that one's "
                 "great for debugging io_uring throughput regressions "
                 "because you can see whether you're actually saving "
                 "syscalls.\n\n"
                 "bpftrace for ad-hoc kernel probes. One-liners against "
                 "tracepoints, kprobes, uprobes. The classic example: "
                 "catch a noisy neighbor by counting sched_switch events "
                 "per process. Application metrics won't show that your "
                 "process is getting preempted; sched_switch shows it "
                 "directly."
             )),
        dict(kind="demo-cue",
             demo_num=4,
             demo_name="Demo 4 — OTel Observability Stack",
             demo_command="cd examples/demo-04-observability && ./demo.sh",
             demo_description=(
                 "Brings up the LGTM stack, instruments a C++ service with OTel traces/metrics/logs, "
                 "drives load, opens Grafana with pre-provisioned dashboards. Optional --bpftrace flag."
             ),
             demo_url="patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/demo-04-observability/",
             notes=(
                 "Demo 4 — the observability foundation that the rest of "
                 "the demos build on. First build is 2-3 minutes; the "
                 "stack comes up in about 30 seconds.\n\n"
                 "What to watch: open Grafana at 127.0.0.1:3000, click "
                 "into the 'Demo overview' dashboard. Three signals "
                 "visible: traces from Tempo (click a span, see the "
                 "waterfall), metrics from Prometheus (RPS, p50/p95/p99 "
                 "histograms), logs from Loki (with trace_id links that "
                 "let you pivot from a slow span back to the log lines "
                 "during it)."
             )),
    ],
},

# ============================================================================
# §11 — Noisy-neighbor isolation
# ============================================================================
{
    "num": 11,
    "label": "Section 11",
    "title": "Noisy-neighbor isolation",
    "tagline": "cgroups v2, CPU pinning, NUMA — Demo 5",
    "divider_notes": (
        "Multi-tenant reality. Most production C++ services share hosts "
        "with other services. The dominant cost on a busy host is "
        "interference, not the CPU work each service performs in "
        "isolation. We're going to measure baseline vs unisolated vs "
        "weighted vs pinned, side-by-side, in Demo 5."
    ),
    "slides": [
        dict(kind="diagram",
             title="cgroup v2 controller tree",
             diagram=f"{DG}/11-isolation-cgroup-tree.jpg",
             caption="Every process is in a cgroup; every cgroup has weight on every resource; the kernel arbitrates.",
             notes=(
                 "The mental model. Every process lives in a cgroup. "
                 "cgroups form a tree. Every cgroup has weights on every "
                 "resource the kernel can arbitrate: CPU, memory, I/O. "
                 "When resources are constrained, the kernel uses those "
                 "weights to decide who gets what.\n\n"
                 "Three controllers we care about for C++ services. "
                 "cpu.weight: from 1 to 10000, default 100. Higher weight "
                 "gets more CPU under contention; below contention, "
                 "weight doesn't matter, processes just run. "
                 "cpuset.cpus: a specific list of CPUs the cgroup is "
                 "allowed to use. Eliminates cross-tenant cache eviction. "
                 "memory.high and memory.max: soft and hard memory "
                 "pressure points covered in section 7.\n\n"
                 "Rootless caveat: by default, only memory and pids are "
                 "delegated to user slices on Fedora. You need to enable "
                 "cpu and cpuset delegation with a systemd drop-in for "
                 "the weighted and pinned demos to work. Demo 5's "
                 "preflight check detects this and points you at the "
                 "helper script."
             )),
        dict(kind="stat-row",
             title="Demo 5 — tenant-a p99 under each scenario",
             stats=[
                 ("2.3 ms", "Baseline\n(tenant-a alone)", C.ACCENT_GREEN),
                 ("24.7 ms", "Unisolated\n(default scheduler)\n10.7× degradation", C.ACCENT_RED),
                 ("9.0 ms", "Weighted\n(cpu.weight=10 for neighbor)\n3.9× degradation", C.ACCENT_ORANGE),
                 ("1.8 ms", "Pinned\n(non-overlapping cpuset)\nFASTER than baseline", C.ACCENT_GREEN),
             ],
             notes=(
                 "Four scenarios, real numbers.\n\n"
                 "Baseline: tenant-a alone, no neighbor. 2.3 ms p99. "
                 "That's the calibration point.\n\n"
                 "Unisolated: tenant-b is a synthetic noisy neighbor that "
                 "pegs CPU. No scheduler tuning. Tenant-a's p99 climbs "
                 "to 24.7 ms — more than 10× the baseline. That's the "
                 "cost of doing nothing.\n\n"
                 "Weighted: cpu.weight=10 for tenant-b, leaving the "
                 "default 100 for tenant-a. Same workload. Tenant-a's "
                 "p99 drops to 9 ms — 3.9× the baseline. Most of the "
                 "damage is gone, the neighbor still gets some CPU when "
                 "it's available, the system is sharing reasonably.\n\n"
                 "Pinned: tenant-a gets cpuset.cpus=0,1; tenant-b gets "
                 "cpuset.cpus=2,3. They cannot run on each other's "
                 "CPUs. p99 drops to 1.8 ms — that's *faster than "
                 "baseline*. Not a typo. When tenant-a gets dedicated "
                 "CPUs the kernel scheduler doesn't migrate it, cache "
                 "stays hot, the p99 actually drops below the "
                 "single-tenant case. This is why latency-sensitive "
                 "production services often pin."
             )),
        dict(kind="content",
             title="Pinning vs weighting — when to use which",
             body=[
                 heading("Use cpu.weight when:", color=C.ACCENT_BLUE),
                 bullet("You want best-effort isolation with elastic CPU sharing"),
                 bullet("Maximum throughput matters as much as p99"),
                 bullet("Workload is bursty — pinning wastes CPU when nobody's busy"),
                 heading("Use cpuset.cpus when:", color=C.ACCENT_GREEN),
                 bullet("p99 is the metric you care about most"),
                 bullet("Cache locality matters (databases, ML inference, RT services)"),
                 bullet("You have enough cores to dedicate some — typically >= 8"),
                 heading("Combine with NUMA when:", color=C.ACCENT_PURPLE),
                 bullet("Host has multiple NUMA nodes (most server hosts)"),
                 bullet("`numactl --membind` pins memory allocation to the same node as CPU"),
                 bullet("Cross-NUMA memory access costs 1.5-3× local"),
             ],
             notes=(
                 "Pinning vs weighting — the decision.\n\n"
                 "Use cpu.weight when you want best-effort isolation with "
                 "elastic sharing. Service A gets more CPU when there's "
                 "contention, but uses the whole machine when idle. Good "
                 "for bursty workloads. Bad if your goal is bounded p99 "
                 "— weighting bounds contention damage but doesn't "
                 "eliminate it.\n\n"
                 "Use cpuset.cpus when p99 is what you optimize for. "
                 "Database engines, ML inference, real-time services. "
                 "You need enough cores to dedicate some — typically 8 "
                 "or more so you can give 2-4 to the critical workload "
                 "and let the rest fight for the others.\n\n"
                 "Combine with NUMA when your host has multiple sockets. "
                 "numactl --membind ties memory allocation to the same "
                 "NUMA node as the CPU set. Cross-NUMA memory access is "
                 "1.5 to 3× slower than local — that overhead defeats "
                 "the locality you got from pinning if you don't pin "
                 "memory too."
             )),
        dict(kind="demo-cue",
             demo_num=5,
             demo_name="Demo 5 — Noisy-Neighbor Isolation",
             demo_command="cd examples/demo-05-isolation && ./demo.sh",
             demo_description=(
                 "Two services side-by-side, four scenarios run sequentially. Prints a comparison "
                 "table of tenant-a p99 under each. Needs cgroup v2 controller delegation."
             ),
             demo_url="patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/demo-05-isolation/",
             notes=(
                 "Demo 5. Prereq is cgroup v2 controller delegation. The "
                 "demo's preflight check will tell you if it's missing "
                 "and point you at scripts/cgroup-delegation.sh.\n\n"
                 "Runtime: 3-5 minutes including the four scenario "
                 "windows. The output is the four-row comparison table. "
                 "Watch the pinned row — that 1.8 ms beating the 2.3 ms "
                 "baseline is the result that most surprises engineers "
                 "the first time they see it."
             )),
    ],
},

# ============================================================================
# §12 — Static analysis & debugging
# ============================================================================
{
    "num": 12,
    "label": "Section 12",
    "title": "Static analysis & debugging",
    "tagline": "cppcheck, clang-tidy, sanitizers, abidiff — Demo 7",
    "divider_notes": (
        "Engineering hygiene. The tools that catch bugs before production "
        "and the patterns that let you debug what slipped through. Demo 7 "
        "is the worked pipeline — cppcheck and clang-tidy as build "
        "stages, gtest as a separate target, sanitizers as build variants, "
        "abidiff as a CI gate, and the ephemeral gdbserver sidecar pattern "
        "for attaching to a running container without putting gdb into "
        "the runtime image."
    ),
    "slides": [
        dict(kind="content",
             title="Static analysis as build stages",
             body=[
                 heading("cppcheck — the lightweight catcher", color=C.ACCENT_BLUE),
                 bullet("Catches: uninit vars, memory leaks, null deref, integer overflow"),
                 bullet("Runs in seconds; output is XML for CI consumption"),
                 bullet("Wire as a Containerfile build stage; fail the build on findings"),
                 dict(text="", size=Pt(6)),
                 heading("clang-tidy — the modernization engine", color=C.ACCENT_GREEN),
                 bullet("100+ checks: modernize-, performance-, bugprone-, cert-"),
                 bullet("Pair with .clang-tidy config + 'compile_commands.json'"),
                 bullet("Modernizes your codebase incrementally — auto-fix where safe"),
                 dict(text="", size=Pt(6)),
                 heading("Demo 7's '--demo-findings' flag", color=C.ACCENT_ORANGE),
                 bullet("Production code is clean — empty cppcheck.txt teaches nothing"),
                 bullet("Flag temporarily appends a deliberately bad function to channel.cpp"),
                 bullet("Runs through analyzer-soft (no gating), shows real findings, restores file"),
             ],
             notes=(
                 "Three subtopics on static analysis.\n\n"
                 "cppcheck is the lightweight catcher. Catches the "
                 "obvious bugs — uninitialized variables, memory leaks, "
                 "null pointer dereferences, integer overflow. Runs in "
                 "seconds even on a large codebase. The output is XML "
                 "so CI can parse it. Wire it as a build stage in your "
                 "Containerfile; fail the build on any finding.\n\n"
                 "clang-tidy is heavier and far more powerful. Over a "
                 "hundred checks across modernize-, performance-, "
                 "bugprone-, cert- categories. The modernize- checks "
                 "auto-fix your codebase to current idioms — "
                 "modernize-use-nullptr replaces NULL with nullptr, "
                 "modernize-loop-convert replaces index loops with "
                 "range-for. The performance- checks catch things like "
                 "unnecessary copies in range-for. Run clang-tidy with a "
                 ".clang-tidy config file plus compile_commands.json — "
                 "CMake exports the latter automatically.\n\n"
                 "Demo 7's --demo-findings flag is a teaching device. "
                 "Real production code is clean, so the clang-tidy.txt "
                 "output is empty — which doesn't teach the reader "
                 "anything. The flag temporarily appends a deliberately "
                 "bad function to channel.cpp, runs through an "
                 "analyzer-soft stage that captures findings without "
                 "gating the build, then restores the file. You see what "
                 "the tools actually report."
             )),
        dict(kind="content-code",
             title="Sanitizers — the slowdown table",
             body=[
                 para("Build variants that catch UB at runtime; slowdown determines what you can ship to staging:"),
             ],
             code="""# Sanitizer  Slowdown   Catches
# =========  =========  ===========================================
# ASan       1.5-3x     heap/stack OOB, use-after-free, leaks
# UBSan      ~1.2x      signed overflow, null deref, bad enum casts
# TSan       5-15x      data races, deadlocks (mutex order)
# MSan       2-3x       uninit memory reads (Clang-only)
# Valgrind   20-50x     same as ASan, no rebuild needed
#
# Production approach:
#  - ASan + UBSan: ALWAYS in CI for every change
#  - TSan: nightly on the multithreaded test suite
#  - MSan: rare; only when chasing uninit-read bugs (rebuild deps)
#  - Valgrind: when you can't rebuild — last resort

# CMake preset for ASan+UBSan
cmake -B build-asan -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined \\
    -fno-omit-frame-pointer -g"
cmake --build build-asan && ASAN_OPTIONS=halt_on_error=1 ./build-asan/svc""",
             notes=(
                 "Slowdown is what determines what you can practically "
                 "ship. ASan plus UBSan is the production-friendly "
                 "combination — 1.5-3× slowdown, catches the majority of "
                 "memory bugs and undefined behavior. Run on every CI "
                 "build. Some teams ship ASan in staging environments "
                 "and live with the slowdown to catch issues earlier.\n\n"
                 "TSan is 5-15× slower because it's instrumenting every "
                 "memory access for happens-before tracking. Run TSan "
                 "nightly against your multithreaded test suite, not on "
                 "every commit. TSan finds the bugs that ASan can't "
                 "catch — data races, deadlock potential — but the "
                 "slowdown means you can't ship it.\n\n"
                 "MSan needs Clang and you need to rebuild your "
                 "dependencies with MSan enabled, or the false positives "
                 "drown you. Use it when you're specifically hunting an "
                 "uninit-read bug.\n\n"
                 "Valgrind is the last resort — when you can't rebuild "
                 "the binary, when you only have the production artifact. "
                 "20-50× slowdown, but it just works on any ELF without "
                 "recompilation. Demo 7 has all five wired up as "
                 "separate build variants you can select with "
                 "--variant=asan etc."
             )),
        dict(kind="diagram",
             title="The gdbserver sidecar pattern",
             diagram=f"{DG}/12-debug-sidecar-pattern.jpg",
             caption="Debug a production container without putting gdb in its image. Sidecar shares the PID namespace, attaches, you connect from your workstation.",
             notes=(
                 "The pattern. You have a production C++ service running "
                 "in ubi-micro — no shell, no debugger, no package "
                 "manager. Something goes wrong. You can't exec into "
                 "the container, there's nothing to exec. You don't want "
                 "to put gdb into the runtime image because it bloats it "
                 "and adds CVE surface.\n\n"
                 "Solution: a sidecar container that shares the same PID "
                 "namespace. Sidecar has gdb, gdbserver, perf, all the "
                 "tools. Service container has just the binary. Sidecar "
                 "attaches gdbserver to the service PID, exposes a "
                 "TCP port. Your workstation runs gdb, connects to that "
                 "port, debugs the running service. When you're done, "
                 "kill the sidecar; service is undisturbed.\n\n"
                 "This is the production pattern. SREs at Stripe, "
                 "Cloudflare, Google all do some variant of this. Demo 7 "
                 "has the exact compose snippet — the sidecar shares "
                 "podman pod, podman pod handles the PID namespace "
                 "sharing automatically."
             )),
        dict(kind="demo-cue",
             demo_num=7,
             demo_name="Demo 7 — Quality Pipeline",
             demo_command="cd examples/demo-07-quality-pipeline && ./demo.sh",
             demo_description=(
                 "Full hygiene pipeline in one demo: cppcheck, clang-tidy, gtest, ASan+UBSan, "
                 "abidiff, hermetic Conan lockfile, and the ephemeral gdbserver sidecar. "
                 "Use --demo-findings to see what the analyzers actually report."
             ),
             demo_url="patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/demo-07-quality-pipeline/",
             notes=(
                 "Demo 7. Five minutes for the full pipeline run. "
                 "Subsequent runs are quick because Conan caches.\n\n"
                 "Three things to watch. First, the static-analysis "
                 "output — with --demo-findings, you'll see real bugs "
                 "detected and the build report them clearly. Second, "
                 "the sanitizer build — ASan+UBSan adds a noticeable "
                 "build-time cost but the runtime cost is bearable. "
                 "Third, the gdbserver sidecar — we'll attach to the "
                 "running service and break in main(), prove the "
                 "production binary is fully debuggable without "
                 "polluting its image."
             )),
    ],
},

# ============================================================================
# §13 — Reproducibility & ABI
# ============================================================================
{
    "num": 13,
    "label": "Section 13",
    "title": "Reproducibility & ABI",
    "tagline": "Conan lockfiles, CMake presets, abidiff — the binary-from-a-commit story",
    "divider_notes": (
        "Still Demo 7. The reproducibility story. Every binary you "
        "ship should be reconstructible byte-for-byte from a commit "
        "and a lockfile, six months later. Conan 2's lockfile mechanism "
        "is what makes that real. abidiff is what catches the silent "
        "ABI breaks that escape from your dependencies and into your "
        "production binary."
    ),
    "slides": [
        dict(kind="diagram",
             title="The Conan + CMake hermetic flow",
             diagram=f"{DG}/13-reproducibility-conan-flow.jpg",
             caption="conan.lock pins exact versions; CMake presets pin compiler flags; the build is reproducible from commit + lockfile.",
             notes=(
                 "Three pinning points along the build flow.\n\n"
                 "First, conan.lock pins every transitive dependency to "
                 "an exact version and recipe revision. If "
                 "fmt/10.1.0:abc123 is in the lockfile, that exact recipe "
                 "revision will be resolved next year too, even if the "
                 "Conan Center package gets updated.\n\n"
                 "Second, CMakePresets.json pins the toolchain, the build "
                 "type, compiler flags, and configuration options. "
                 "Anyone running `cmake --preset release` gets the same "
                 "build configuration.\n\n"
                 "Third, the Containerfile pins the base image. UBI 9 "
                 "with a specific digest hash, not just 'ubi9:latest'. "
                 "If Red Hat ships a new ubi9 image, you don't pick it "
                 "up until you explicitly update the digest.\n\n"
                 "All three together: given a git commit, you can "
                 "rebuild bit-identical binaries six months from now. "
                 "Demo 7 demonstrates this — it builds twice, then "
                 "compares the binaries with `cmp` and shows they're "
                 "byte-identical."
             )),
        dict(kind="content-code",
             title="abidiff — the silent ABI break catcher",
             body=[
                 para("Catches silently-broken ABI between dependency versions. Wire as CI gate."),
             ],
             code="""# A dependency upgrade looks innocent — but did the ABI change?
# Run abidiff against the before/after .so files:

abidiff old-libfoo.so new-libfoo.so

# Output: 'No changes' or a structured report of:
#   - Functions added/removed
#   - Function signatures changed (parameter types, return types)
#   - Struct members added/removed/reordered
#   - Member offsets shifted

# CI integration — fail on incompatible ABI changes:
abidiff --suppressions abi-suppressions.txt \\
    baseline/libfoo.so new/libfoo.so || exit 1

# Common silent ABI break:
# - Header says: void process(MyConfig& cfg);
# - MyConfig added a field. New code passes 24-byte struct;
# - Old caller (built against old header) passes 16-byte struct.
# - Caller passes garbage; either crash or silent corruption.""",
             notes=(
                 "abidiff from libabigail. The use case: you're upgrading "
                 "a dependency from version 1.2.0 to 1.3.0. Maintainers "
                 "say it's a minor version bump, ABI-compatible. abidiff "
                 "tells you whether that's actually true.\n\n"
                 "What it catches: function signature changes (return "
                 "types, parameter types, calling conventions), struct "
                 "member additions and reorderings, member offset shifts, "
                 "removal of public symbols that downstream code might "
                 "use. The structured report tells you exactly what "
                 "changed.\n\n"
                 "The classic silent ABI break: a header file adds a "
                 "field to a public struct. Code that was built against "
                 "the old header passes a 16-byte struct into a function "
                 "that now expects 24 bytes. Compiler doesn't catch it "
                 "because the call site sees the new struct definition "
                 "in its TU and the linker resolves the function symbol. "
                 "But the caller built against the old header passes "
                 "garbage. Either you crash or you silently corrupt "
                 "data.\n\n"
                 "Demo 7 has a `--abi-break` flag that intentionally "
                 "introduces a struct change and shows abidiff catching "
                 "it. The CI integration is one line — `abidiff old new "
                 "|| exit 1`. Run it on every release branch against "
                 "the previous release."
             )),
        dict(kind="content",
             title="What 'hermetic' actually means",
             body=[
                 heading("Hermetic = build is a pure function of its inputs", color=C.ACCENT_BLUE),
                 bullet("Same source + same lockfile → byte-identical binary, on any machine"),
                 bullet("No network access during build (after lockfile resolution)"),
                 bullet("No reliance on /usr/local, /opt, or anything outside the sandbox"),
                 dict(text="", size=Pt(6)),
                 heading("Common leaks (what makes a build NOT hermetic)", color=C.ACCENT_RED),
                 bullet("Build script does `pip install` without a constraints file"),
                 bullet("Compiler reads system headers from /usr/include — host-version-dependent"),
                 bullet("Test data downloaded at build time without a hash check"),
                 bullet("Timestamps embedded in the binary (use SOURCE_DATE_EPOCH)"),
                 dict(text="", size=Pt(6)),
                 heading("Demo 7 demonstrates", color=C.ACCENT_GREEN),
                 bullet("`./demo.sh build && ./demo.sh build && cmp build1.bin build2.bin`"),
                 bullet("Byte-identical output. That's the reproducibility test."),
             ],
             notes=(
                 "Hermetic builds. The principle: the build is a pure "
                 "function of its inputs. Same source plus same lockfile "
                 "yields a byte-identical binary, regardless of which "
                 "machine builds it.\n\n"
                 "What makes a build not hermetic — the leak sources. "
                 "pip install without constraints — picks up new "
                 "transitive deps every time. System headers — your "
                 "binary embeds the layout of structs from the host's "
                 "/usr/include, which differs between Fedora versions. "
                 "Network downloads at build time — unless you "
                 "checksum them, you're trusting a remote server to "
                 "give you the same bits every time. Timestamps — by "
                 "default many compilers embed `__DATE__` macros and "
                 "the build timestamp; set SOURCE_DATE_EPOCH from your "
                 "git commit timestamp to make this deterministic.\n\n"
                 "Demo 7's reproducibility test is a one-liner — build "
                 "twice in a row, `cmp` the binaries. They should be "
                 "byte-identical. If they're not, something in your "
                 "build is non-hermetic, find it and fix it. The "
                 "diff-strings output tells you what differs — often "
                 "it's the timestamp."
             )),
    ],
},

# ============================================================================
# §14 — Pitfalls
# ============================================================================
{
    "num": 14,
    "label": "Section 14",
    "title": "Pitfalls",
    "tagline": "Symptom → root cause → fix. The runbook section.",
    "divider_notes": (
        "Pitfalls. The traps that catch experienced people. Every entry "
        "is structured as symptom-cause-fix because that's how the bug "
        "actually arrives in your inbox. Not 'I read about a class of "
        "bugs' — instead, 'my service is crashing with SIGILL on the "
        "new fleet, what changed'."
    ),
    "slides": [
        dict(kind="diagram",
             title="Pitfall 1: AVX-512 instruction-set mismatch",
             diagram=f"{DG}/14-pitfalls-avx512-mismatch.jpg",
             caption="-march=native at build time + heterogeneous fleet at runtime = SIGILL on the older silicon.",
             notes=(
                 "The most common production C++ container failure that "
                 "I see misdiagnosed.\n\n"
                 "Symptom: service runs fine in dev. Promoted to staging "
                 "fleet, runs fine. Promoted to production fleet, "
                 "immediately crashes with SIGILL — illegal instruction. "
                 "Engineers blame the container runtime, the OS upgrade, "
                 "something exotic. The actual cause is the build "
                 "host.\n\n"
                 "Cause: the build host had a newer CPU than some "
                 "production hosts. -march=native at compile time told "
                 "GCC to use whatever instructions the build host had — "
                 "which included AVX-512. Some production hosts are "
                 "older silicon that doesn't have AVX-512. The first "
                 "AVX-512 instruction the binary tries to execute, the "
                 "CPU raises SIGILL.\n\n"
                 "Fix: never use -march=native for binaries that will "
                 "be promoted across hosts. Use -march=x86-64-v3 (which "
                 "is Haswell-era — AVX2 but not AVX-512) as a "
                 "conservative baseline, or -march=x86-64-v4 if you "
                 "know your entire fleet is Skylake-X or newer. The "
                 "tutorial's Containerfile pins -march=x86-64-v3 "
                 "explicitly for exactly this reason."
             )),
        dict(kind="content",
             title="Pitfalls 2-4: silent overhead, build delays, OTel processor",
             body=[
                 heading("2. The 25%-of-host malloc trap", color=C.ACCENT_RED),
                 bullet("Symptom: pod gets OOMKilled even though service appears to use minimal memory"),
                 bullet("Cause: glibc malloc reads host RAM via /proc/meminfo, ignores cgroup"),
                 bullet("Fix: set MALLOC_ARENA_MAX=2, or switch to mimalloc/jemalloc"),
                 dict(text="", size=Pt(6)),
                 heading("3. Abstraction overhead from misjudged virtuals", color=C.ACCENT_ORANGE),
                 bullet("Symptom: 15-30% throughput regression after a 'clean refactor'"),
                 bullet("Cause: virtual functions on tight inner loops defeat inlining"),
                 bullet("Fix: profile first; templates or CRTP for hot paths; virtuals only for true polymorphism"),
                 dict(text="", size=Pt(6)),
                 heading("4. OTel Simple vs Batch span processor", color=C.ACCENT_PURPLE),
                 bullet("Symptom: shipped OTel to prod, throughput dropped 80%+"),
                 bullet("Cause: SimpleSpanProcessor does synchronous export per span"),
                 bullet("Fix: switch to BatchSpanProcessor; one-line change in init code"),
             ],
             notes=(
                 "Three more pitfalls.\n\n"
                 "Number two: the 25%-of-host malloc trap. Symptom is "
                 "your pod gets OOMKilled but your service appears to be "
                 "using almost no memory. What's happening is glibc "
                 "malloc reads /proc/meminfo, sees the host has 256 GB, "
                 "decides it can claim 25% — 64 GB — of arena space "
                 "without bothering the kernel. Your pod's cgroup limit "
                 "is 2 GB. First time glibc tries to actually touch some "
                 "of that arena, you cross the cgroup limit, kernel OOM "
                 "kills you. Fix: MALLOC_ARENA_MAX=2 caps the arena "
                 "count, or switch allocators entirely.\n\n"
                 "Number three: abstraction overhead. After a "
                 "code-cleanup refactor that introduced an interface "
                 "hierarchy in your hot path, throughput drops 15-30%. "
                 "Cause: every virtual call is an indirect jump, defeats "
                 "inlining, defeats branch prediction at the call site. "
                 "Fix is profile-driven — figure out which call sites "
                 "actually matter, and use templates or CRTP "
                 "(curiously-recurring template pattern) to get "
                 "polymorphism without virtual dispatch.\n\n"
                 "Number four: OTel Simple vs Batch — we covered this in "
                 "section 10. SimpleSpanProcessor is great for "
                 "debugging, fatal for production. The fix is one line."
             )),
        dict(kind="content",
             title="The 'symptom → cause → fix' template",
             body=[
                 para("Why this format works for runbooks:", bold=True),
                 dict(text="", size=Pt(8)),
                 bullet("The bug arrives as a SYMPTOM. The on-call has logs, dashboards, a paging alert."),
                 bullet("The on-call has zero context on the cause space."),
                 bullet("Runbook entries indexed by symptom let the on-call find their bug fast."),
                 bullet("Entries indexed by cause assume knowledge that's exactly what the on-call lacks."),
                 dict(text="", size=Pt(8)),
                 para("Pattern for your own team's runbook:", bold=True),
                 dict(text="", size=Pt(8)),
                 bullet("Symptom: paste the alert text or error message verbatim"),
                 bullet("Cause: one paragraph, plain English, no jargon"),
                 bullet("Fix: literal commands. Not 'check the X' but 'run $ kubectl describe ...'"),
                 bullet("Verify: how do you know the fix worked"),
                 bullet("Prevent: what to change so it doesn't recur"),
             ],
             notes=(
                 "Why I keep coming back to symptom-cause-fix as the "
                 "runbook format. When a bug arrives at 3am, the on-call "
                 "has the symptom — they're looking at the alert, the "
                 "stack trace, the error message. They don't have "
                 "context on the cause; that's exactly what they need "
                 "to figure out. A runbook indexed by cause assumes "
                 "the very knowledge the reader is searching for.\n\n"
                 "So index by symptom. Paste the alert or error message "
                 "literally. Make it grep-able. When the same bug "
                 "appears six months later and a different engineer is "
                 "on-call, they grep the runbook for the error string "
                 "and find the entry.\n\n"
                 "Cause goes in one plain-English paragraph — what's "
                 "actually broken under the hood. Fix is literal "
                 "commands, not abstract guidance. 'Check the cgroup' "
                 "is useless; '$ cat /sys/fs/cgroup/...memory.max' is "
                 "actionable.\n\n"
                 "Verify section: how do you know it worked. Prevent "
                 "section: what to change in code or config so it "
                 "doesn't recur. This last section is what turns "
                 "incidents into permanent improvements."
             )),
    ],
},

# ============================================================================
# §15 — Where to go next
# ============================================================================
{
    "num": 15,
    "label": "Section 15",
    "title": "Where to go next",
    "tagline": "Four reference books + the topics this tutorial deliberately doesn't cover",
    "divider_notes": (
        "Short section. Four books that go deeper on different axes "
        "than this tutorial does, plus an honest list of what we "
        "deliberately don't cover."
    ),
    "slides": [
        dict(kind="content",
             title="Four reference books — pick one based on what you need next",
             body=[
                 heading("Andrist & Sehr — C++ High Performance, 2e", color=C.ACCENT_BLUE),
                 bullet("The single best book on modern C++ performance. C++20 throughout."),
                 bullet("If you read one, read this one. Chapters 4-5 are the most-cited here."),
                 dict(text="", size=Pt(6)),
                 heading("Iglberger — C++ Software Design", color=C.ACCENT_GREEN),
                 bullet("Patterns + anti-patterns for C++ at scale. The abstraction tax chapter."),
                 bullet("Read after Andrist when you're designing libraries, not just optimizing them."),
                 dict(text="", size=Pt(6)),
                 heading("Enberg — Latency", color=C.ACCENT_ORANGE),
                 bullet("Cross-stack latency engineering — application through kernel through hardware."),
                 bullet("Best book on observability-as-measurement. Chapter 8 is the OTel reference."),
                 dict(text="", size=Pt(6)),
                 heading("Ghosh — Building Low Latency Apps with C++", color=C.ACCENT_PURPLE),
                 bullet("Trading-systems-grade latency. Lock-free, NUMA, kernel bypass."),
                 bullet("Read when 'reasonably fast' isn't enough — when single-digit microseconds matter."),
                 dict(text="", size=Pt(6)),
                 para("Full annotated treatment: /bibliography/ on the tutorial site.",
                      italic=True),
             ],
             notes=(
                 "Four books, ordered by accessibility plus how often "
                 "they came up in this tutorial.\n\n"
                 "Andrist and Sehr's C++ High Performance second edition "
                 "is the single best book on modern C++ performance. "
                 "C++20 throughout, real benchmarks, idiomatic code. "
                 "Chapters 4 and 5 — containers and algorithms — are "
                 "what informed section 6 of this tutorial.\n\n"
                 "Iglberger's C++ Software Design is the patterns + "
                 "anti-patterns book. Read it after Andrist if you're "
                 "designing libraries, not just optimizing existing "
                 "code. The abstraction tax chapter is the explicit "
                 "treatment of pitfall number 3 from section 14.\n\n"
                 "Enberg's Latency is unusual — it goes vertically "
                 "through the stack from application through kernel "
                 "through hardware. Best book on observability as a "
                 "measurement discipline. Chapter 8's framing on "
                 "'measuring perturbs the measurement' is what informs "
                 "section 10.\n\n"
                 "Ghosh's Building Low Latency Apps with C++ is "
                 "trading-systems-grade. Lock-free data structures, "
                 "NUMA, kernel bypass with DPDK. Read this when "
                 "single-digit microseconds matter, not 'fast enough'.\n\n"
                 "The /bibliography/ page on the tutorial site has full "
                 "annotated treatment — which chapter of which book "
                 "informs which section of this tutorial, plus a few "
                 "honorable mentions that didn't make the four-book "
                 "cut."
             )),
        dict(kind="content",
             title="What this tutorial doesn't cover",
             body=[
                 heading("Deliberately out of scope", color=C.TEXT_MUTED),
                 dict(text="", size=Pt(6)),
                 bullet("C++ language fundamentals — assumed knowledge"),
                 bullet("Kubernetes operator/Helm/cluster-level concerns (separate tutorial)"),
                 bullet("Coroutines (C++20) — major topic, deserves its own treatment"),
                 bullet("GPU offload / CUDA / OpenCL — different problem space"),
                 bullet("Distributed tracing patterns — touched in §10, not deep"),
                 bullet("Mobile / embedded C++ — different OS constraints"),
                 dict(text="", size=Pt(6)),
                 heading("If you want more on these", color=C.ACCENT_CYAN),
                 bullet("Coroutines: Lewis Baker's lewissbaker.github.io posts, cppcoro library"),
                 bullet("Kubernetes for ops: hummingbird-tutorial (companion project)"),
                 bullet("GPU offload: NVIDIA's HPC SDK docs, Bryce Adelstein Lelbach's talks"),
                 dict(text="", size=Pt(6)),
                 para("This tutorial is opinionated about its scope. We do containerized "
                      "C++ services well; for other axes, the right answer is a different tutorial.",
                      italic=True, color=C.TEXT_MUTED),
             ],
             notes=(
                 "Honest scope statement. We deliberately don't cover "
                 "several things that get asked about.\n\n"
                 "C++ language fundamentals: assumed. We expect "
                 "knowledge of templates, RAII, move semantics, and the "
                 "STL. If you're newer to C++, cppreference and "
                 "Andrist & Sehr are the right starting points.\n\n"
                 "Kubernetes operator concerns, Helm charts, "
                 "cluster-level scheduling: cgroups v2 and Podman pods "
                 "are the deployment mental model here. Translating to "
                 "k8s is mechanical but k8s-specific work deserves its "
                 "own tutorial. The hummingbird-tutorial covers podman-"
                 "to-Kubernetes for completeness.\n\n"
                 "Coroutines: C++20 coroutines are a major topic. They "
                 "deserve their own tutorial; this one would balloon if "
                 "we added them. Lewis Baker's blog at lewissbaker.github.io "
                 "is the canonical introduction. cppcoro is the "
                 "reference library.\n\n"
                 "GPU offload, CUDA, OpenCL: different problem space. "
                 "Different observability stack, different optimization "
                 "concerns. NVIDIA's HPC SDK documentation is where to "
                 "start.\n\n"
                 "Mobile and embedded: different OS constraints, no "
                 "cgroups in the same form, different allocator "
                 "trade-offs. The mental-model section here is partially "
                 "transferable; the specific knobs are not."
             )),
    ],
},

# ============================================================================
# §16 — Appendix A: Conan + UBI 9 perl
# ============================================================================
{
    "num": 16,
    "label": "Section 16",
    "title": "Appendix A — Conan, autotools, UBI 9's minimal perl",
    "tagline": "The survival guide for from-source dependency builds on UBI 9",
    "divider_notes": (
        "Brief appendix. Read this one before you attempt your own Conan "
        "+ UBI 9 + autotools-using-dep build. The tutorial's demo-04 "
        "took six rounds of build failures to converge, and every one "
        "of them was the same underlying issue: UBI 9's minimal perl is "
        "missing modules that autotools' configure scripts assume are "
        "present."
    ),
    "slides": [
        dict(kind="content",
             title="The fifteen perl modules that autotools wants",
             body=[
                 para("UBI 9's perl-interpreter is the minimal subset. Any autotools-based "
                      "Conan build (libcurl, c-ares, openssl, nghttp2, etc.) will fail until "
                      "these are installed:"),
                 dict(text="", size=Pt(8)),
                 heading("Core (always needed)", color=C.ACCENT_BLUE),
                 bullet("perl-Carp  perl-Data-Dumper  perl-Errno  perl-Getopt-Long"),
                 bullet("perl-Pod-Simple  perl-PathTools  perl-File-Path  perl-File-Temp"),
                 dict(text="", size=Pt(6)),
                 heading("Build-script-specific (commonly needed)", color=C.ACCENT_GREEN),
                 bullet("perl-Digest-MD5  perl-Encode  perl-MIME-Base64"),
                 bullet("perl-Scalar-List-Utils  perl-Storable  perl-Text-ParseWords"),
                 bullet("perl-Thread-Queue"),
                 dict(text="", size=Pt(6)),
                 heading("Simplifying alternatives", color=C.ACCENT_ORANGE),
                 bullet("Use ubi9 (not ubi9-minimal) for the builder stage — includes full perl"),
                 bullet("Use a pre-built ConanCenter binary if your platform has one"),
                 bullet("Or maintain a 'fat builder' base image with all 15 modules baked in"),
             ],
             notes=(
                 "Fifteen perl modules. I'll spare you the bug history "
                 "and just give you the list. If you're doing a Conan "
                 "from-source build on UBI 9-minimal of anything that "
                 "uses autotools — libcurl, c-ares, openssl, nghttp2, "
                 "and most C libraries from the 90s — you need these "
                 "fifteen modules.\n\n"
                 "Three simplifying alternatives. First and easiest: "
                 "use the full ubi9 image for the builder stage. The "
                 "runtime image can still be ubi9-minimal or ubi9-micro. "
                 "Multi-stage means the builder bulk doesn't ship to "
                 "production. The perl modules are in the builder "
                 "only.\n\n"
                 "Second: use a pre-built ConanCenter binary if your "
                 "platform has one. Conan resolves prebuilt artifacts "
                 "preferentially; you only fall through to from-source "
                 "if there's no compatible prebuilt.\n\n"
                 "Third: maintain a 'fat builder' base image at your "
                 "organization with all 15 perl modules baked in. "
                 "Internal teams pull from your builder image; "
                 "consistency across teams, no per-team rediscovery."
             )),
        dict(kind="content-code",
             title="Worked example — libcurl from source on UBI 9",
             body=[
                 para("The Containerfile fragment that actually works:"),
             ],
             code="""# Builder stage — full UBI 9 with the 15 perl modules
FROM registry.redhat.io/ubi9:9.4 AS builder

RUN dnf install -y perl-Carp perl-Data-Dumper perl-Errno \\
    perl-Getopt-Long perl-Pod-Simple perl-PathTools \\
    perl-File-Path perl-File-Temp perl-Digest-MD5 \\
    perl-Encode perl-MIME-Base64 perl-Scalar-List-Utils \\
    perl-Storable perl-Text-ParseWords perl-Thread-Queue \\
    gcc-toolset-14 cmake ninja-build python3-pip && \\
    pip install conan==2.* && dnf clean all

WORKDIR /src
COPY . .

# `conan install` works now: perl modules are present
RUN conan install . --build=missing && \\
    cmake --preset release && \\
    cmake --build --preset release

# Runtime: minimal, no perl, no compiler — just the binary
FROM registry.redhat.io/ubi9-micro:9.4
COPY --from=builder /src/build/release/svc /usr/local/bin/svc
ENTRYPOINT ["/usr/local/bin/svc"]""",
             notes=(
                 "The Containerfile fragment that actually works for "
                 "libcurl-from-source on UBI 9. Builder stage installs "
                 "the fifteen perl modules, plus the toolchain and "
                 "Conan 2. Then `conan install --build=missing` works "
                 "because the dependency's configure script can find "
                 "all the perl modules it needs.\n\n"
                 "Runtime stage is ubi9-micro, no perl at all, no "
                 "compiler. Just the binary we copy from the builder. "
                 "Final image is tens of megabytes, not hundreds. "
                 "Builder image is large but only exists in your build "
                 "cache, not in production registries.\n\n"
                 "This appendix exists because every team that goes "
                 "from Ubuntu to UBI 9 hits this. The Ubuntu base "
                 "images include a fuller perl by default; UBI 9 is "
                 "more aggressive about minimization. The first time "
                 "your Conan build fails on a missing perl-Errno "
                 "module is when you realize what's going on. Save "
                 "yourself the rounds."
             )),
    ],
},
]
