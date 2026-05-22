"""
sections_statelessness.py — slide content for the STATELESSNESS COMPENDIUM deck.

Companion deck to the main "Optimizing Modern C++ with Containers" deck,
focused on the statelessness compendium (Docs 01–11). Same schema, same
renderer (build-pptx.py builders), same length target (~70 slides).

Each section dict:
  - num, label, title, tagline, divider_notes, slides[]
Slide kinds: content | content-code | diagram | stat-row | demo-cue
Diagrams come from diagrams/statelessness/*.svg, converted to
/tmp/diagrams-png/<name>.jpg by build-statelessness-deck.sh.

Human-edited prose; build-statelessness-pptx.py is the renderer.
"""
from pptx.dml.color import RGBColor
from pptx.util import Pt
from pptx.enum.text import PP_ALIGN


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


DG = "/tmp/diagrams-png"  # converted PNGs/JPGs live here


def para(text, size=Pt(16), bold=False, italic=False,
         color=C.TEXT_DARK, bullet=False, align=PP_ALIGN.LEFT):
    return dict(text=text, size=size, bold=bold, italic=italic,
                color=color, bullet=bullet, align=align)


def bullet(text, size=Pt(15)):
    return dict(text=text, size=size, bold=False, color=C.TEXT_DARK,
                bullet=True)


def heading(text, size=Pt(18), color=None):
    return dict(text=text, size=size, bold=True, color=color or C.TEXT_DARK)


def dg(name):
    return f"{DG}/{name}.jpg"


SECTIONS = [

# ============================================================================
# §1 — Deployment posture
# ============================================================================
{
    "num": 1,
    "label": "§1",
    "title": "Statelessness as deployment posture",
    "tagline": "Statelessness is not a code property — it's what the orchestrator can assume.",
    "divider_notes": (
        "This compendium is the architectural spine under the performance "
        "talk. The thesis here sets the vocabulary for everything that "
        "follows: statelessness isn't something you can read off a source "
        "file. The same C++ binary can be stateless or stateful depending on "
        "what state it holds and where. What makes a service 'stateless' is a "
        "property the orchestrator relies on — that it can kill, restart, and "
        "scale a replica without coordination."),
    "slides": [
        {
            "kind": "stat-row",
            "title": "Why statelessness is the load-bearing property",
            "stats": [
                ("3", "scopes of state — request, process, deploy-time —\nand only one of them may hold authoritative data",
                 C.ACCENT_BLUE),
                ("0", "coordination needed to kill or restart a replica\nwhen nothing authoritative lives in-process",
                 C.ACCENT_GREEN),
                ("02\u201311", "compendium examples, each a runnable Podman\ndemo, host-verified end to end on Fedora 44",
                 C.ACCENT_CYAN),
                ("1", "binary — stateless or stateful depending only on\nwhere it keeps state, not on its code",
                 C.ACCENT_PURPLE),
            ],
            "notes": (
                "Four numbers to frame the whole deck. Three scopes of state, "
                "and the discipline is that only deploy-time scope holds "
                "authoritative data. Zero coordination to kill a replica — "
                "that's the operational payoff. The whole compendium is "
                "runnable, not just described. And the punchline: it's one "
                "binary; statelessness is about where state lives, not how the "
                "code is written."),
        },
        {
            "kind": "content",
            "title": "Three scopes of state",
            "body": [
                heading("The same binary, three kinds of state", color=C.ACCENT_BLUE),
                bullet("Request scope — lives for one RPC; born and dies inside the handler"),
                bullet("Process scope — lives for the process; pools, caches, channels, config"),
                bullet("Deploy-time scope — lives outside the process; the database, the queue, the cache tier"),
                para("Statelessness means: nothing the orchestrator can't "
                     "recreate lives in process scope. Kill a replica and "
                     "nothing authoritative is lost.",
                     size=Pt(15), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("01-deployment-posture"),
            "notes": (
                "The three-scope vocabulary is used in every later document, "
                "so it's worth fixing now. Request scope is the per-RPC "
                "lifetime — RAII makes this concrete (the RAII section). Process scope is "
                "the process lifetime — pools, channels, parsed config, owned "
                "in main() (process scope). Deploy-time scope is everything outside the "
                "process — the externalized authoritative state (state externalization).\n\n"
                "The litmus test for statelessness: if you SIGKILL a replica, "
                "is anything authoritative lost? If the answer is no, the "
                "service is stateless regardless of how much process-scoped "
                "state it holds for performance."),
        },
        {
            "kind": "content",
            "title": "Six monolith intuitions that mislead",
            "body": [
                heading("What bare-metal habits get wrong under containers",
                        color=C.ACCENT_RED),
                bullet("\"The box has N cores\" — the cgroup quota does not equal nproc"),
                bullet("\"Memory is the machine's RAM\" — memory.max is the real ceiling"),
                bullet("\"The filesystem persists\" — the rootfs is ephemeral (ephemeral filesystem)"),
                bullet("\"My thread pool should match the CPU count\" — it should match the cgroup (threading)"),
                bullet("\"Local cache is free\" — it desyncs across replicas (state externalization)"),
                bullet("\"Restart is exceptional\" — under orchestration it's routine (health & shutdown)"),
            ],
            "notes": (
                "Each of these intuitions is correct on a dedicated box and "
                "wrong under an orchestrator. The thread-pool one is the most "
                "expensive: hardware_concurrency() reports the host's core "
                "count, not the cgroup quota, so a naive pool oversubscribes "
                "and the CFS scheduler throttles it — wrecking tail latency. "
                "Demo 11 makes that gap visible. We'll return to each of these "
                "as we go."),
        },
        {
            "kind": "content",
            "title": "The State Architecture Table",
            "body": [
                heading("Decide, per piece of state, where it lives", color=C.ACCENT_GREEN),
                bullet("Session / auth context → externalized (cache tier), never in-process"),
                bullet("Counters, sequences → the database, atomic; not a process-local int"),
                bullet("Durable workflow → the database or a workflow engine"),
                bullet("Connection pools, channels, parsed config → process scope, owned in main()"),
                bullet("Per-request scratch → request scope, the PMR arena"),
                para("The table is the design exercise: enumerate every piece "
                     "of state and assign it a scope on purpose.",
                     size=Pt(15), italic=True, color=C.TEXT_MUTED),
            ],
            "notes": (
                "The State Architecture Table is the practical heart of the process-scope section, "
                "introduced here. The exercise is mechanical and clarifying: "
                "list every piece of state your service touches, and for each "
                "one decide its scope deliberately. Anything authoritative goes "
                "to deploy-time scope. Anything that's pure performance "
                "infrastructure — pools, caches, channels — is process scope, "
                "bounded and owned in main(). Anything per-request is request "
                "scope. Get this table right and statelessness falls out."),
        },
    ],
},

# ============================================================================
# §2 — RAII
# ============================================================================
{
    "num": 2,
    "label": "§2",
    "title": "RAII as the foundation",
    "tagline": "Bind resource lifetime to scope; the destructor is the contract.",
    "divider_notes": (
        "RAII is the mechanism that makes request scope concrete. If request "
        "scope is the idea, RAII is the C++ feature that enforces it: resource "
        "lifetime bound to object lifetime, cleanup guaranteed at scope exit on "
        "every path — normal return, early return, or exception."),
    "slides": [
        {
            "kind": "content",
            "title": "The RequestContext pattern",
            "body": [
                heading("One RAII type bundles per-request state", color=C.ACCENT_BLUE),
                bullet("Constructed at the top of the handler; destroyed on return"),
                bullet("Bundles the deadline, correlation id, a per-request arena, the span scope"),
                bullet("Members destruct in reverse declaration order — cleanup ordering for free"),
                bullet("The three exception-safety guarantees: basic, strong, nothrow"),
                para("All cleanup is RAII; the handler's try/catch is for "
                     "error-to-status translation, not resource management.",
                     size=Pt(15), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("02-raii"),
            "notes": (
                "The RequestContext is the single most reused pattern in the "
                "compendium — it shows up again in the PMR doc (the arena lives "
                "in it), the threading doc (the span scope is TLS-bound to it), "
                "and the capstone (the handler builds one per call). The key "
                "discipline: the destructor is the contract. You never write "
                "cleanup code in the handler body; you let scope exit run it."),
        },
        {
            "kind": "content-code",
            "title": "Common RAII mistakes",
            "body": [
                heading("What breaks the guarantee", color=C.ACCENT_RED),
                bullet("Throwing destructors — terminate() during stack unwind"),
                bullet("Raw owning pointers — leak on the exception path"),
                bullet("Manual try/catch cleanup — misses paths RAII wouldn't"),
                bullet("Missing noexcept moves — silent pessimization or UB"),
                bullet("Locks held across co_await — UB after suspension (the threading section)"),
            ],
            "code": (
                "// The shape that always cleans up:\n"
                "grpc::Status Handler(ServerContext* ctx,\n"
                "                     const Req* req, Resp* resp) {\n"
                "  try {\n"
                "    RequestContext rc{*ctx, req->correlation_id()};\n"
                "    // ... work; may throw grpc::Status or std::exception\n"
                "    return grpc::Status::OK;       // rc destructs here\n"
                "  } catch (const grpc::Status& s) {  // ...and here\n"
                "    return s;                        // ...and here\n"
                "  }\n"
                "}  // destructor runs on EVERY path"
            ),
            "notes": (
                "The throwing-destructor one is the killer: if a destructor "
                "throws during stack unwinding from another exception, the "
                "runtime calls terminate(). Destructors are noexcept by "
                "default in C++11 onward for exactly this reason — don't fight "
                "it. The locks-across-co_await trap is subtle and gets its own "
                "treatment in the threading doc."),
        },
        {
            "kind": "content",
            "title": "The three exception-safety guarantees",
            "body": [
                heading("What a function promises when it throws", color=C.ACCENT_GREEN),
                bullet("Nothrow — never throws (destructors, swap, moves); the strongest"),
                bullet("Strong — throws → state unchanged, as if the call never happened"),
                bullet("Basic — throws → invariants hold, no leaks, but state may have moved"),
                para("RAII gives you the basic guarantee for free; the strong "
                     "guarantee is a design choice (copy-and-swap, build-then-commit).",
                     size=Pt(15), italic=True, color=C.TEXT_MUTED),
            ],
            "notes": (
                "These three guarantees are the vocabulary for reasoning about "
                "what happens on the throw path. RAII hands you the basic "
                "guarantee automatically — destructors run, nothing leaks, "
                "invariants survive. The strong guarantee — state rolls back as "
                "if nothing happened — is a deliberate design, usually "
                "copy-and-swap or build-the-new-state-then-commit. Nothrow is "
                "what destructors and move operations must be; mark your moves "
                "noexcept or the standard library silently falls back to copies."),
        },
        {
            "kind": "content",
            "title": "Construction cost on the hot path",
            "body": [
                heading("RAII is free; what you put in it may not be", color=C.ACCENT_ORANGE),
                bullet("The RequestContext itself is near-zero — members init in place"),
                bullet("A std::string member under 15 bytes (libstdc++ SBO) costs no allocation"),
                bullet("A std::map member allocates a node per insert; prefer flat/pmr"),
                bullet("Measure the constructor: it runs on every request, in the latency path"),
            ],
            "notes": (
                "RAII has no inherent cost — it's just scope-bound destruction. "
                "But the per-request object runs its constructor on every "
                "request, so what you put in it matters. A short std::string "
                "member fits in the small-string buffer and costs nothing; a "
                "std::map member allocates per node. This is where the PMR "
                "arena (next section) earns its keep — the per-request "
                "containers allocate from a buffer that's already there."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 2,
            "demo_name": "Demo — RequestContext RAII",
            "demo_command": "cd examples/statelessness/02-raii && ./demo.sh",
            "demo_description": (
                "A gRPC handler builds a RequestContext on entry, then takes "
                "one of three exit paths — normal return, early return, and "
                "throw. Logging in the destructor proves it fires on all "
                "three. RAII cleanup made visible."),
            "demo_url": "patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/statelessness-02-raii/",
            "notes": (
                "Watch the destructor log line appear once per request "
                "regardless of which exit path the handler took. The point "
                "isn't that RAII is clever — it's that the cleanup is "
                "path-independent, which is exactly the property a "
                "request-scoped resource needs."),
        },
    ],
},

# ============================================================================
# §3 — PMR
# ============================================================================
{
    "num": 3,
    "label": "§3",
    "title": "PMR: request brings its own memory",
    "tagline": "monotonic_buffer_resource as architectural statelessness.",
    "divider_notes": (
        "PMR — polymorphic memory resources — is the in-language realization "
        "of 'the request brings its own memory and releases it all together.' "
        "It's request scope expressed in the allocator."),
    "slides": [
        {
            "kind": "content",
            "title": "The layered arena recipe",
            "body": [
                heading("monotonic buffer + pool resource", color=C.ACCENT_BLUE),
                bullet("A fixed on-stack/in-object buffer fronts a monotonic_buffer_resource"),
                bullet("An unsynchronized_pool_resource layers on top for varied block sizes"),
                bullet("Per-request pmr::vector / pmr::string allocate from the arena"),
                bullet("Destruction asymmetry: individual frees are no-ops; the whole arena is reclaimed at once"),
            ],
            "diagram": dg("03-pmr"),
            "notes": (
                "The recipe is canonical: monotonic_buffer_resource for the "
                "bump-allocation, unsynchronized_pool_resource on top so "
                "differently-sized allocations don't waste the buffer. The win "
                "is the destruction asymmetry — destroying a pmr::vector built "
                "in the arena is essentially free because do_deallocate is a "
                "no-op; only the arena's own destruction reclaims memory, and "
                "that's a single pointer reset."),
        },
        {
            "kind": "content",
            "title": "The lifetime trap",
            "body": [
                heading("The one rule PMR makes easy to break", color=C.ACCENT_RED),
                bullet("A pmr container must not outlive its memory_resource"),
                bullet("Return a pmr::string built in a request arena → dangling after the arena dies"),
                bullet("Caught immediately under AddressSanitizer (the dev profile)"),
                para("Fix: return owning std:: types across the scope "
                     "boundary, or keep the value inside the arena's lifetime.",
                     size=Pt(15), italic=True, color=C.TEXT_MUTED),
            ],
            "notes": (
                "This is the counterexample the doc dwells on because it's the "
                "one mistake PMR makes easy. The arena is on the stack or in "
                "the RequestContext; if you hand a pmr::string built in it back "
                "to a caller that outlives the request, you've got a "
                "use-after-free. ASan catches it on the first run — which is "
                "why the dev profile wires ASan in by default."),
        },
        {
            "kind": "content",
            "title": "Which container, on PMR?",
            "body": [
                heading("std:: containers that take a memory_resource", color=C.ACCENT_GREEN),
                bullet("pmr::vector — the workhorse; contiguous, arena-allocated"),
                bullet("pmr::string — short ids and scratch text without the global allocator"),
                bullet("pmr::unordered_map — per-request lookups; nodes in the arena"),
                bullet("pmr::flat_map (C++23) — sorted, cache-friendly, fewer allocations"),
                para("Same familiar std:: types; the allocator is just plumbed "
                     "to the request arena via the polymorphic resource.",
                     size=Pt(15), italic=True, color=C.TEXT_MUTED),
            ],
            "notes": (
                "PMR isn't a separate container library — it's the same std:: "
                "containers with a runtime-polymorphic allocator. You pass the "
                "arena's memory_resource to the container's constructor and "
                "every allocation it makes comes from the arena. pmr::vector is "
                "the one you'll reach for most; pmr::flat_map in C++23 gives you "
                "a sorted, contiguous map that allocates rarely — ideal for the "
                "small per-request maps a handler builds."),
        },
        {
            "kind": "content",
            "title": "Why the asymmetry is the whole point",
            "body": [
                heading("Allocation vs. deallocation cost", color=C.ACCENT_BLUE),
                bullet("Allocation: a pointer bump in the monotonic buffer — a few instructions"),
                bullet("Per-object deallocation: a NO-OP (monotonic do_deallocate does nothing)"),
                bullet("Reclamation: one buffer reset when the RequestContext destructs"),
                bullet("Net: thousands of tiny per-request frees collapse into a single reset"),
            ],
            "notes": (
                "This is the performance argument for the arena. In a "
                "general-purpose allocator, every allocation has a matching "
                "free, and frees are not cheap — they touch free lists, "
                "coalesce, lock. In a monotonic arena, allocation is a pointer "
                "bump and individual deallocation does literally nothing; the "
                "memory comes back all at once when the arena dies. For a "
                "request that builds and tears down many small objects, that "
                "asymmetry is a real latency win on the destruction side."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 3,
            "demo_name": "Demo — PMR request arena",
            "demo_command": "cd examples/statelessness/03-pmr && ./demo.sh",
            "demo_description": (
                "The layered monotonic + pool arena in action: per-request "
                "allocation freed in bulk, the release-cost asymmetry measured, "
                "and the lifetime trap caught live by AddressSanitizer."),
            "demo_url": "patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/statelessness-03-pmr/",
            "notes": (
                "Two things to watch: the timing difference between "
                "per-element free and bulk arena reclamation, and then the "
                "deliberate lifetime bug — the demo builds it, runs under ASan, "
                "and ASan prints the use-after-free with a stack trace. That's "
                "the safety net the dev profile gives you for free."),
        },
    ],
},

# ============================================================================
# §4 — Process-scoped state
# ============================================================================
{
    "num": 4,
    "label": "§4",
    "title": "Process-scoped state, owned in main()",
    "tagline": "Some state legitimately lives for the process — own it explicitly.",
    "divider_notes": (
        "Not all state is request-scoped. Connection pools, gRPC channels, "
        "parsed config, in-process caches — these legitimately live for the "
        "process lifetime. The discipline is to own them explicitly in main() "
        "and inject them by reference, not reach for them as singletons."),
    "slides": [
        {
            "kind": "content",
            "title": "The composition root",
            "body": [
                heading("main() constructs everything by name", color=C.ACCENT_BLUE),
                bullet("Parsed config, pools, channel cache, caches — built once, in order"),
                bullet("Injected into services by reference; no global singletons"),
                bullet("Reverse-order destruction at scope exit — teardown for free from RAII"),
                bullet("The State Architecture Table: what's process-scoped vs externalized"),
            ],
            "diagram": dg("04-process-scoped-state"),
            "notes": (
                "The composition-root pattern (Iglberger's dependency-injection "
                "chapter is the underpinning) keeps ownership legible: you can "
                "read main() top to bottom and see the entire lifetime graph. "
                "Reverse-order destruction falls out of declaration order, so "
                "the teardown sequence is correct without any explicit shutdown "
                "code — the channels close after the services that use them, "
                "the pools after the channels, and so on."),
        },
        {
            "kind": "content",
            "title": "Size process-scoped state from the budget",
            "body": [
                heading("The cgroup is the budget", color=C.ACCENT_ORANGE),
                bullet("Bounded caches sized against memory.max, not host RAM"),
                bullet("An unbounded cache is a slow OOM under a memory cgroup"),
                bullet("Pool sizes and arena counts scale from the CPU quota (threading)"),
                bullet("Bounded structures everywhere: LRU caps, pool maxima, queue limits"),
            ],
            "notes": (
                "The recurring theme: the container's resource limits are the "
                "sizing budget for process-scoped state. An unbounded "
                "in-process cache that's fine on a 256 GB box becomes a slow "
                "OOMKill under a 512 MB memory cgroup. Everything process-scoped "
                "should be bounded and sized against the cgroup, which means "
                "reading the cgroup — the helper we ship in the build-tooling section."),
        },
        {
            "kind": "content-code",
            "title": "Dependency injection over singletons",
            "body": [
                heading("Inject by reference; don't reach for a singleton", color=C.ACCENT_PURPLE),
                bullet("The Meyers singleton hides ownership and lifetime"),
                bullet("Pass collaborators in by const& or &; the service owns nothing global"),
                bullet("Testable: substitute a fake pool or channel at the seam"),
                bullet("Iglberger's DI chapter is the architectural underpinning"),
            ],
            "code": (
                "int main() {\n"
                "  const Config cfg = parse_config();\n"
                "  PgPool       pg{cfg.pg_conninfo, cfg.pg_pool_size};\n"
                "  ChannelCache channels{};\n"
                "  // dependencies injected by reference, owned here:\n"
                "  PricingService svc{cfg, pg, channels};\n"
                "  // ... serve ...\n"
                "}  // svc, channels, pg, cfg destruct in REVERSE order"
            ),
            "notes": (
                "The composition root constructs everything and injects it by "
                "reference. No service reaches for a global; each takes its "
                "collaborators as constructor arguments. That's what makes the "
                "lifetime graph legible and the service testable — at the seam "
                "you can hand it a fake pool. And because the objects are "
                "locals in main(), they destruct in reverse construction order "
                "automatically, which is exactly the teardown order you want."),
        },
        {
            "kind": "content",
            "title": "Bounded by construction",
            "body": [
                heading("Every process-scoped structure has a ceiling", color=C.ACCENT_RED),
                bullet("LRU caches: a max entry count sized from memory.max"),
                bullet("Connection pools: a hard maximum, with a checkout timeout"),
                bullet("Queues: bounded, with a backpressure policy when full"),
                bullet("Prepared-statement caches: capped, evicting least-recently-used"),
                para("Unbounded + a memory cgroup = a slow, surprising OOMKill "
                     "under load. Bound everything.",
                     size=Pt(15), italic=True, color=C.TEXT_MUTED),
            ],
            "notes": (
                "The discipline that prevents the most common container OOM: "
                "every process-scoped structure that can grow must have a "
                "ceiling, and the ceiling should be derived from the cgroup "
                "memory budget. An unbounded cache doesn't fail fast — it grows "
                "until the cgroup OOMKiller reaps the process, usually under "
                "peak load, which is the worst time. Bounding by construction "
                "turns that into a predictable eviction instead."),
        },
    ],
},

# ============================================================================
# §5 — Threading
# ============================================================================
{
    "num": 5,
    "label": "§5",
    "title": "Threading under a CPU quota",
    "tagline": "hardware_concurrency() lies; the cgroup tells the truth.",
    "divider_notes": (
        "Threading is the cross-cutting concern that interacts with "
        "statelessness in the least obvious way. The headline: under a CPU "
        "cgroup quota, hardware_concurrency() reports the host's cores, not "
        "your budget — and sizing a pool to it throttles you."),
    "slides": [
        {
            "kind": "content",
            "title": "CFS quota and the throttling trap",
            "body": [
                heading("Oversubscription buys nothing and costs tail latency",
                        color=C.ACCENT_RED),
                bullet("CFS gives the cgroup quota microseconds per period"),
                bullet("A pool sized to nproc under --cpus=2 runs out of quota and is throttled"),
                bullet("Throttling shows up as p99 latency spikes, not lower throughput"),
                bullet("Fix: size pools to the cgroup quota; read it with the cgroup helper"),
            ],
            "diagram": dg("05-threading"),
            "notes": (
                "CFS — the completely fair scheduler — enforces the cgroup CPU "
                "quota by handing the cgroup a slice of microseconds per "
                "period. If your thread pool has more runnable threads than the "
                "quota allows, the kernel throttles the whole cgroup: it stops "
                "scheduling your threads until the next period. The symptom "
                "isn't lower average throughput — it's vicious p99 spikes as "
                "requests stall waiting for the next quota refill."),
        },
        {
            "kind": "content",
            "title": "TLS, coroutines, and the co_await gotcha",
            "body": [
                heading("Concurrency models and where state hides", color=C.ACCENT_BLUE),
                bullet("TLS is process-scoped, per-thread — the CorrelationGuard pattern"),
                bullet("OS threads, C++20 stackless coroutines, Boost.Fiber stackful"),
                bullet("The trap: a value relied on via TLS after co_await may resume on another thread"),
                bullet("Capture request context into the coroutine frame, not TLS"),
            ],
            "notes": (
                "Thread-local storage is process-scoped but per-thread, which "
                "makes it a natural home for things like the active span — until "
                "coroutines. After a co_await, the coroutine may resume on a "
                "different thread, so anything you stashed in TLS before the "
                "suspension is gone. The fix is to capture request-scoped "
                "context into the coroutine frame. This is why the capstone's "
                "RequestContext holds the span scope as a member rather than "
                "relying on TLS."),
        },
        {
            "kind": "content",
            "title": "The gRPC sync-server ResourceQuota trap",
            "body": [
                heading("Thread count is not request concurrency", color=C.ACCENT_RED),
                bullet("Sync gRPC server: each in-flight RPC holds a thread for its duration"),
                bullet("Set NUM_CQS, MIN/MAX_POLLERS, and a ResourceQuota max-threads from the budget"),
                bullet("A blocking handler under-provisioned on threads serializes silently"),
                bullet("Size the server thread pool from the cgroup quota, with headroom"),
            ],
            "notes": (
                "The gRPC sync server is convenient but has a configuration "
                "trap: a blocking handler occupies a thread for its whole "
                "duration, so the server's thread pool size caps your "
                "concurrency. The ResourceQuota max-threads and the poller "
                "settings need to be sized from the CPU budget — too few and "
                "you serialize, too many and you throttle. The capstone shows "
                "the configuration; this is the knob people miss."),
        },
        {
            "kind": "content",
            "title": "Allocator arenas under a quota",
            "body": [
                heading("Even malloc cares about the CPU count", color=C.ACCENT_ORANGE),
                bullet("jemalloc / tcmalloc shard arenas per-CPU to reduce contention"),
                bullet("Default arena count keys off the host cores, not the cgroup"),
                bullet("Over-arena'd under a small quota wastes memory; size from the budget"),
                bullet("MALLOC_CONF narenas (jemalloc) tuned from cpu_limit_cores()"),
            ],
            "notes": (
                "The cgroup-vs-host-count problem isn't only about thread "
                "pools — it reaches into the allocator. jemalloc and tcmalloc "
                "create per-CPU arenas to cut lock contention, and they size "
                "that count from the host's core count by default. Under a "
                "small CPU quota that's wasted memory. If you tune it, derive "
                "the arena count from the same cgroup reading the thread pool "
                "uses."),
        },
        {
            "kind": "content",
            "title": "Cooperative cancellation with stop_token",
            "body": [
                heading("std::jthread + std::stop_token (C++20)", color=C.ACCENT_GREEN),
                bullet("Background workers take a stop_token; loop while !stop_requested()"),
                bullet("std::jthread joins on destruction — no detached threads outliving main()"),
                bullet("Shutdown requests stop, the worker drains, the jthread joins cleanly"),
                bullet("Ties directly into the graceful-shutdown sequence (health & shutdown)"),
            ],
            "notes": (
                "std::jthread and std::stop_token are the C++20 tools for clean "
                "worker lifecycle. A jthread joins automatically when it goes "
                "out of scope, so you can't accidentally leak a thread past "
                "main(); and the stop_token gives cooperative cancellation — "
                "the worker checks stop_requested() and exits its loop. The "
                "the health-and-shutdown sequence uses exactly this to drain the "
                "outbox relay and other background work."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 5,
            "demo_name": "Demo — Threading & CPU budget",
            "demo_command": "cd examples/statelessness/05-threading && ./demo.sh",
            "demo_description": (
                "A cgroup-aware probe and a pool-size sweep under --cpus=2 show "
                "that oversubscription buys no throughput and wrecks tail "
                "latency through CFS throttling."),
            "demo_url": "patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/statelessness-05-threading/",
            "notes": (
                "The sweep runs the same workload with progressively larger "
                "pools under a 2-core quota. Watch throughput plateau while p99 "
                "climbs — that's throttling, not contention. The cgroup-aware "
                "pool size is the knee of that curve."),
        },
    ],
},

# ============================================================================
# §6 — Twelve-factor
# ============================================================================
{
    "num": 6,
    "label": "§6",
    "title": "12-Factor adapted to C++",
    "tagline": "Most factors map directly; three collide with C++ idioms.",
    "divider_notes": (
        "The twelve-factor app methodology was written for interpreted, "
        "garbage-collected services. Most factors map onto C++ cleanly; three "
        "collide with C++ idioms and are worth dwelling on: Config, Processes, "
        "and Disposability."),
    "slides": [
        {
            "kind": "content",
            "title": "Config: four binding times",
            "body": [
                heading("Where a value gets fixed matters", color=C.ACCENT_BLUE),
                bullet("Compile-time — constexpr, template params; zero runtime cost, needs a rebuild"),
                bullet("Link-time — which libraries, which ABI"),
                bullet("Env-time — parsed once in main() from the environment (12-factor's Config)"),
                bullet("Runtime — reloadable policy; rare, and the most expensive"),
                para("Parse env-time config once into an immutable struct; "
                     "pass it by const reference. No getenv scattered around.",
                     size=Pt(15), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("06-twelve-factor"),
            "notes": (
                "C++ has a richer set of binding times than the languages "
                "12-factor assumed, and choosing the right one is a design "
                "decision. A feature flag that never changes after deploy "
                "should be compile-time (constexpr) — free at runtime. The "
                "12-factor 'Config' factor is specifically env-time: read once "
                "in main(), into an immutable Config struct, passed by const "
                "reference everywhere. The Config struct shows up in every "
                "service in the compendium."),
        },
        {
            "kind": "content",
            "title": "Processes & Disposability",
            "body": [
                heading("Singletons and the startup tax", color=C.ACCENT_ORANGE),
                bullet("Processes: the Meyers singleton hides ownership — inject instead"),
                bullet("Disposability: fast startup and clean shutdown are features under orchestration"),
                bullet("The C++ startup tax — static initialization order, constinit to tame it"),
                bullet("Staged startup: NOT_SERVING → warm → SERVING (health & shutdown)"),
            ],
            "notes": (
                "The Processes factor collides with the Meyers singleton — the "
                "function-local-static pattern so common in C++. It works, but "
                "it hides ownership and lifetime, which is exactly what the "
                "composition root makes explicit. Disposability is where the "
                "C++ startup tax bites: static initialization runs before "
                "main(), and a slow cold start hurts under an orchestrator that "
                "restarts replicas routinely. constinit moves what it can to "
                "compile time."),
        },
        {
            "kind": "content-code",
            "title": "Taming the startup tax with constinit",
            "body": [
                heading("Static init order is a latency and correctness risk", color=C.ACCENT_RED),
                bullet("Non-trivial globals run constructors before main() — the startup tax"),
                bullet("The static initialization order fiasco: cross-TU ordering is undefined"),
                bullet("constinit forces compile-time init — no runtime constructor, defined order"),
                bullet("Prefer locals in main() over globals; constinit for the unavoidable ones"),
            ],
            "code": (
                "// Forced to be initialized at compile time — zero startup cost,\n"
                "// no ordering fiasco:\n"
                "constinit std::string_view kBuildVersion = \"1.4.2\";\n\n"
                "// Better still: own it in main() and inject it.\n"
                "// Worst: a non-trivial global that runs a constructor\n"
                "//        before main() in an undefined cross-TU order."
            ),
            "notes": (
                "The startup tax is real under orchestration: every non-trivial "
                "global runs its constructor before main(), adding to cold-start "
                "latency, and the cross-translation-unit ordering is undefined — "
                "the classic static initialization order fiasco. constinit fixes "
                "the subset that can be initialized at compile time: it's a "
                "guarantee, checked by the compiler, that there's no runtime "
                "constructor. The better fix for most state is to not make it "
                "global at all — own it in main()."),
        },
        {
            "kind": "content",
            "title": "The other factors, briefly",
            "body": [
                heading("Most of 12-factor maps cleanly", color=C.ACCENT_BLUE),
                bullet("Logs → stdout, the collector owns persistence (ephemeral filesystem)"),
                bullet("Backing services → attached resources, swappable by config (state externalization)"),
                bullet("Build/release/run → the multi-stage Containerfile + a lockfile (build tooling)"),
                bullet("Port binding, concurrency, dev/prod parity → natural fits for a C++ service"),
            ],
            "notes": (
                "The remaining factors map onto a C++ service without friction. "
                "Logs to stdout is the one that bites people because of the "
                "spdlog file-default trap, which gets its own doc. Backing "
                "services as attached resources is the externalization story. "
                "Build/release/run separation is the hermetic Conan build plus "
                "the multi-stage image. The rest — port binding, concurrency, "
                "parity — are things a well-structured service does anyway."),
        },
    ],
},

# ============================================================================
# §7 — State externalization
# ============================================================================
{
    "num": 7,
    "label": "§7",
    "title": "State externalization",
    "tagline": "What goes outside the process, and how to reach it safely.",
    "divider_notes": (
        "If process scope can't hold authoritative state, it has to live "
        "outside — the database, the cache tier, the queue. This document is "
        "about reaching that external state safely: connection pools as "
        "process-scoped infrastructure, idempotency, deadline propagation, and "
        "the outbox pattern for atomic write-plus-emit."),
    "slides": [
        {
            "kind": "content",
            "title": "Pools, RAII checkout, idempotency",
            "body": [
                heading("Backing services done right", color=C.ACCENT_BLUE),
                bullet("Connection pool = process-scoped infra; per-handler RAII checkout"),
                bullet("ScopedConnection returns the connection on scope exit; invalidate() on broken"),
                bullet("Idempotency keys + ON CONFLICT DO NOTHING = DB-authoritative dedup"),
                bullet("Deadlines propagate to the backing service (statement_timeout from the budget)"),
            ],
            "diagram": dg("07-state-externalization"),
            "notes": (
                "The pool is process-scoped (built in main()); the checkout is "
                "request-scoped (RAII, returned on scope exit). That pairing is "
                "the whole pattern. Idempotency is enforced at the database "
                "with a unique key and ON CONFLICT DO NOTHING, so a client "
                "retry is safe even across replicas — there's no in-process "
                "state to desync. Deadlines propagate all the way to the "
                "database via statement_timeout computed from the remaining "
                "request budget."),
        },
        {
            "kind": "content",
            "title": "The outbox pattern",
            "body": [
                heading("Atomic DB write + event emission", color=C.ACCENT_PURPLE),
                bullet("Write the row and an outbox event in ONE transaction"),
                bullet("A relay polls the outbox with FOR UPDATE SKIP LOCKED, publishes to Kafka"),
                bullet("An idempotent consumer applies events with ON CONFLICT DO NOTHING"),
                bullet("At-least-once delivery + idempotent apply = exactly-once effect"),
            ],
            "notes": (
                "The outbox solves the dual-write problem: you can't atomically "
                "write to the database AND publish to Kafka, so instead you "
                "write the event into the same database transaction as the "
                "business row. A separate relay then publishes it. Because the "
                "relay re-publishes after a crash (at-least-once) and the "
                "consumer applies idempotently, the end-to-end effect is "
                "exactly-once — without distributed transactions."),
        },
        {
            "kind": "content-code",
            "title": "Deadlines propagate all the way down",
            "body": [
                heading("One budget, enforced at every hop", color=C.ACCENT_BLUE),
                bullet("The request deadline comes from the gRPC ServerContext"),
                bullet("Compute remaining budget; set it as the DB statement_timeout"),
                bullet("Pass the same deadline to outbound gRPC ClientContext"),
                bullet("A blown budget surfaces as DEADLINE_EXCEEDED, not a hung handler"),
            ],
            "code": (
                "auto remaining = deadline - now();\n"
                "if (remaining <= 0ms)\n"
                "  throw grpc::Status{DEADLINE_EXCEEDED, \"...\"};\n"
                "// DB: SET statement_timeout = <remaining ms>\n"
                "// gRPC: client_ctx.set_deadline(rc.deadline());"
            ),
            "notes": (
                "Deadline propagation is what keeps a slow dependency from "
                "turning into a pile-up. The request arrives with a deadline; "
                "every downstream call budgets against the same clock. The "
                "database gets a statement_timeout computed from the remaining "
                "time; the outbound gRPC call gets the same absolute deadline. "
                "If the budget is already blown, you fail fast with "
                "DEADLINE_EXCEEDED instead of starting work that can't finish "
                "in time."),
        },
        {
            "kind": "content",
            "title": "Retry-with-backoff vs. fail-fast",
            "body": [
                heading("When to retry and when to give up", color=C.ACCENT_ORANGE),
                bullet("Idempotent + transient failure → retry with capped exponential backoff + jitter"),
                bullet("Non-idempotent without a key → do NOT blindly retry"),
                bullet("Budget-aware: never retry past the request deadline"),
                bullet("invalidate() a broken pooled connection so it isn't reused"),
            ],
            "notes": (
                "Retry policy is where idempotency pays off. If an operation is "
                "idempotent — guaranteed by the client key and ON CONFLICT — a "
                "transient failure can be retried safely with backoff and "
                "jitter to avoid thundering herds. Without idempotency, a blind "
                "retry can double-apply. And every retry must respect the "
                "remaining deadline; retrying past the budget just wastes work. "
                "Broken connections get invalidated so the pool doesn't hand "
                "them out again."),
        },
        {
            "kind": "content",
            "title": "The cache counterexample, fixed",
            "body": [
                heading("Why the local-cache counterexample was the bug", color=C.ACCENT_RED),
                bullet("An in-process cache of authoritative data desyncs across replicas"),
                bullet("Replica A updates; replica B serves a stale read — non-deterministic"),
                bullet("Fix: the cache tier is deploy-time scope, shared and authoritative"),
                bullet("In-process caches are fine ONLY for derived/immutable data"),
            ],
            "notes": (
                "This closes the loop on the earlier cache counterexample. A local "
                "in-process cache of authoritative data is the classic "
                "statelessness violation: two replicas hold divergent views, "
                "and which answer you get depends on which replica you hit. The "
                "fix is to move the cache to deploy-time scope — a shared cache "
                "tier — so it's authoritative and consistent across replicas. "
                "In-process caching is only safe for data that's immutable or "
                "purely derived and cheap to rebuild."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 7,
            "demo_name": "Demo — State externalization + outbox",
            "demo_command": "cd examples/statelessness/07-outbox-pattern && ./demo.sh",
            "demo_description": (
                "An order and its event written in one transaction; a relay "
                "publishes the outbox to Kafka with FOR UPDATE SKIP LOCKED; an "
                "idempotent consumer applies it. A crash mid-publish still "
                "yields an exactly-once effect."),
            "demo_url": "patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/statelessness-07-outbox-pattern/",
            "notes": (
                "The companion uses libpq (not libpqxx — its bundled CMake "
                "breaks the toolchain), librdkafka's C API, and a single-node "
                "Strimzi Kafka. Watch the relay pick up the outbox row, publish "
                "it, and the consumer dedupe a replayed event. There's a "
                "sibling demo, 07-state-externalization, for the pool and "
                "idempotency pieces in isolation."),
        },
    ],
},

# ============================================================================
# §8 — Ephemeral filesystem
# ============================================================================
{
    "num": 8,
    "label": "§8",
    "title": "The ephemeral filesystem",
    "tagline": "The container rootfs is scratch space — treat it that way.",
    "divider_notes": (
        "The container filesystem is ephemeral: the writable overlay layer is "
        "discarded when the container dies. read_only: true turns that "
        "implicit truth into an enforced one, and surfaces every place your "
        "code assumed it could write."),
    "slides": [
        {
            "kind": "content",
            "title": "read_only: true as a forcing function",
            "body": [
                heading("Make ephemerality explicit", color=C.ACCENT_BLUE),
                bullet("rootfs read-only; /tmp on an explicit tmpfs; volumes for what must survive"),
                bullet("Logs go to stdout — the collector owns persistence, not the container"),
                bullet("C++ traps: spdlog's basic_logger_mt opens a file → EROFS on a read-only rootfs"),
                bullet("Fix: the stdout sink; never the default file logger in a container"),
            ],
            "diagram": dg("08-ephemeral-filesystem"),
            "notes": (
                "read_only: true is a forcing function — it converts 'the "
                "filesystem is ephemeral' from a fact you might forget into an "
                "error you can't ignore. The classic C++ trap is spdlog: the "
                "convenient basic_logger_mt opens a log file, which fails with "
                "EROFS on a read-only rootfs. The fix is to log to stdout and "
                "let the platform's collector handle persistence — which is "
                "also what 12-factor's Logs factor wants. Other traps: crash "
                "dumps, ML model caches, coverage data, prometheus textfiles."),
        },
        {
            "kind": "content",
            "title": "What goes where",
            "body": [
                heading("A place for every write", color=C.ACCENT_BLUE),
                bullet("rootfs → read-only; the binary, libs, certs, nothing writable"),
                bullet("/tmp → an explicit tmpfs with a size cap; scratch only"),
                bullet("Persistent data → a volume (PVC), and only what must truly survive"),
                bullet("Config → env vars / mounted configmap, read-only"),
                bullet("Logs → stdout; never a file the container owns"),
            ],
            "notes": (
                "The mental model is a place for every kind of write. The "
                "rootfs is read-only and holds only immutable artifacts. "
                "Scratch goes to an explicit, size-capped tmpfs at /tmp — "
                "explicit so you've thought about the size, because a tmpfs "
                "counts against memory. Anything that must survive a restart "
                "goes to a real volume, and you should be able to count those "
                "things on one hand. Config is mounted read-only; logs go to "
                "stdout."),
        },
        {
            "kind": "content",
            "title": "Restart semantics as a feature",
            "body": [
                heading("Ephemerality is the point, not a limitation", color=C.ACCENT_GREEN),
                bullet("A crash + restart returns a known-clean filesystem state"),
                bullet("No accreted local state to corrupt, fill the disk, or drift"),
                bullet("rootless Podman's UID mapping: writes you DID allow land correctly"),
                bullet("Kubernetes ephemeral-storage budgets cap the tmpfs + writable layers"),
            ],
            "notes": (
                "The flip side of the ephemeral-filesystem constraint is that "
                "it's a feature. Because nothing local accretes, a restart "
                "always returns you to a known-clean state — no half-written "
                "files, no disk slowly filling with logs, no drift between "
                "replicas. Rootless Podman adds a UID-mapping wrinkle for the "
                "writes you do allow, and Kubernetes lets you budget "
                "ephemeral-storage so a runaway tmpfs can't take the node down."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 8,
            "demo_name": "Demo — Ephemeral filesystem",
            "demo_command": "cd examples/statelessness/08-ephemeral-filesystem && ./demo.sh",
            "demo_description": (
                "A read-only rootfs as the forcing function: the spdlog EROFS "
                "trap and the stdout-sink fix, ephemerality demonstrated across "
                "container restarts, and why scratch belongs on an explicit "
                "tmpfs."),
            "demo_url": "patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/statelessness-08-ephemeral-filesystem/",
            "notes": (
                "The demo first shows the EROFS failure with the default file "
                "logger, then the same service logging cleanly to stdout. Then "
                "it writes to /tmp, restarts the container, and shows the file "
                "is gone — ephemerality as a feature, not a surprise."),
        },
    ],
},

# ============================================================================
# §9 — Health checks
# ============================================================================
{
    "num": 9,
    "label": "§9",
    "title": "Health checks & graceful shutdown",
    "tagline": "Three probes, the gRPC health protocol, graceful shutdown.",
    "divider_notes": (
        "Health checks are the orchestrator's API into your service — how it "
        "decides whether to route traffic, restart, or wait. Three probes, "
        "each answering a different question, plus the graceful-shutdown "
        "sequence that ties together everything we've built."),
    "slides": [
        {
            "kind": "content",
            "title": "Startup, liveness, readiness",
            "body": [
                heading("Three probes, three questions", color=C.ACCENT_BLUE),
                bullet("Startup — \"has it finished initializing?\" (permissive, gates the others)"),
                bullet("Liveness — \"is it deadlocked?\" (narrow; failure means restart)"),
                bullet("Readiness — \"should it get traffic?\" (fine-grained; failure means drain)"),
                bullet("gRPC standard health protocol via HealthCheckServiceInterface"),
            ],
            "diagram": dg("09-health-checks"),
            "notes": (
                "The three probes are not interchangeable. Liveness failing "
                "means 'restart me' — make it narrow, because a flaky liveness "
                "probe causes restart storms. Readiness failing means 'stop "
                "sending traffic but don't kill me' — that's the one that "
                "handles transient dependency outages and graceful drain. "
                "Startup is permissive and covers the cold-start window so "
                "liveness doesn't fire during initialization."),
        },
        {
            "kind": "content",
            "title": "The graceful-shutdown sequence",
            "body": [
                heading("SIGTERM to clean exit, in order", color=C.ACCENT_ORANGE),
                bullet("Signal handler sets a flag only (async-signal-safe)"),
                bullet("A control thread flips readiness NOT_SERVING — the LB drains us"),
                bullet("server->Shutdown(deadline) lets in-flight RPCs finish"),
                bullet("Reverse-order destruction in main() — pools, channels, config"),
                bullet("std::stop_token cancels background workers cleanly (the threading section)"),
            ],
            "notes": (
                "The shutdown sequence ties together stop_token from the "
                "threading doc, pool draining from the externalization doc, and "
                "reverse-order destruction from the process-scope doc. The "
                "signal-safety detail matters: a SIGTERM handler must only set "
                "a flag — it can't call into gRPC or take a lock, because "
                "almost nothing is async-signal-safe. A dedicated control "
                "thread watches the flag and does the real work."),
        },
        {
            "kind": "content",
            "title": "Separate port vs. same port",
            "body": [
                heading("Where the probes listen", color=C.ACCENT_BLUE),
                bullet("Same port: the gRPC health service rides the main port — simplest"),
                bullet("Separate port: an HTTP /healthz for liveness, isolated from app load"),
                bullet("Hybrid (the 09 companion): HTTP liveness, gRPC readiness"),
                bullet("Separate-port liveness keeps answering even when the app pool is saturated"),
            ],
            "notes": (
                "The trade-off between probe placement: same-port is simplest "
                "and the gRPC standard health service makes it trivial, but if "
                "the application thread pool saturates, the probe can't answer "
                "and you get spurious restarts. A separate, lightweight HTTP "
                "liveness endpoint keeps answering independently of app load. "
                "The 09 companion uses the hybrid: HTTP for liveness, the gRPC "
                "health service for readiness."),
        },
        {
            "kind": "content",
            "title": "Health-check anti-patterns",
            "body": [
                heading("How probes cause the outages they should prevent", color=C.ACCENT_RED),
                bullet("Liveness that checks dependencies → a DB blip restarts every replica"),
                bullet("Readiness that's too coarse → flapping in and out of rotation"),
                bullet("A probe heavier than a real request → the probe is the load"),
                bullet("No startup probe → liveness fires during a slow cold start, restart loop"),
            ],
            "notes": (
                "Health checks cause more outages than they prevent when done "
                "wrong. The cardinal sin is a liveness probe that checks "
                "downstream dependencies: a transient database blip then "
                "trips liveness on every replica simultaneously, and the "
                "orchestrator restarts your entire fleet at once — turning a "
                "blip into an outage. Liveness should check only 'is this "
                "process wedged'; dependency health belongs in readiness, "
                "which drains rather than kills."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 9,
            "demo_name": "Demo — Health checks & shutdown",
            "demo_command": "cd examples/statelessness/09-health-checks && ./demo.sh",
            "demo_description": (
                "Staged startup (NOT_SERVING → SERVING), liveness vs readiness "
                "on separate ports, a SIGUSR1 readiness toggle, and the "
                "signal-safe graceful-shutdown sequence to a clean exit."),
            "demo_url": "patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/statelessness-09-health-checks/",
            "notes": (
                "Three acts: staged startup with liveness answering 200 while "
                "readiness is still NOT_SERVING during init; a SIGUSR1 toggle "
                "flipping readiness while liveness stays green; then a SIGTERM "
                "showing the ordered drain and clean exit 0. The companion uses "
                "the bool SetServingStatus overload and a signal-flag + "
                "control-thread design."),
        },
    ],
},

# ============================================================================
# §10 — gRPC capstone
# ============================================================================
{
    "num": 10,
    "label": "§10",
    "title": "The gRPC capstone",
    "tagline": "Every pattern composed in one order-pricing service.",
    "divider_notes": (
        "The integration document. The previous nine established patterns in "
        "isolation; this one composes them into a single realistic gRPC "
        "service — an order-pricing service that calls a second tax service "
        "over gRPC — so the way the pieces fit together is visible end to end."),
    "slides": [
        {
            "kind": "content",
            "title": "What composes",
            "body": [
                heading("Every prior section, in one main()", color=C.ACCENT_BLUE),
                bullet("Config parsed once (12-factor config); process-scoped pool + channel cache (process scope)"),
                bullet("RequestContext with a PMR arena per call (RAII + PMR)"),
                bullet("Handler throws grpc::Status; RAII cleans up; boundary translates (the RAII section)"),
                bullet("Deadline-propagated PostgreSQL + outbound gRPC tax call (threading + externalization)"),
                bullet("Idempotency on the client key; staged health + graceful shutdown (externalization + health)"),
            ],
            "diagram": dg("10-grpc-microservices"),
            "notes": (
                "Twelve numbered steps in main(), every one mapping back to a "
                "prior document. The point of the capstone isn't new ideas — "
                "it's showing that the patterns compose without friction. The "
                "handler reads a customer and product prices from Postgres, "
                "calls the tax service over gRPC with the request deadline "
                "propagated, and returns a priced order — idempotent on the "
                "client's key."),
        },
        {
            "kind": "content",
            "title": "Faithful in architecture, lean in dependencies",
            "body": [
                heading("What the runnable companion realizes vs. designs",
                        color=C.ACCENT_ORANGE),
                bullet("PostgreSQL via libpq, not libpqxx (its bundled CMake breaks the toolchain)"),
                bullet("Price lookup straight to PostgreSQL; Redis cache-aside marked as a seam"),
                bullet("OpenTelemetry is a documented seam — the companion emits NO spans"),
                bullet("Sync gRPC API, not callback; composition identical, migration mechanical"),
                para("The architecture and composition are faithful to the "
                     "doc; the realized backends stay on the verified stack.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "notes": (
                "Honesty slide. The compendium document presents the full "
                "design including the OpenTelemetry tracing pipeline. The "
                "runnable companion stays on the verified gRPC trio and so "
                "represents some of that design as documented seams rather than "
                "built dependencies — most importantly, it emits no spans, so "
                "nothing reaches Tempo. The composition it DOES prove is the "
                "real value: request, process, and external scope fitting "
                "together with deadline propagation and idempotency."),
        },
        {
            "kind": "content-code",
            "title": "main() in twelve numbered steps",
            "body": [
                heading("The wiring is mechanical and reusable", color=C.ACCENT_BLUE),
                bullet("Parse config → detect CPU budget → size pools"),
                bullet("Construct process-scoped state: pool, channel cache, service"),
                bullet("Build the server, health NOT_SERVING, warm, flip to SERVING"),
                bullet("Install the signal handler, start workers, Wait(), drain, exit 0"),
            ],
            "code": (
                "const Config cfg = parse_config();        // 1\n"
                "const double cpu = cgroup_cpu().value_or(  // 2\n"
                "    hardware_concurrency());\n"
                "PgPool pg{cfg.pg_conninfo, cfg.pool};      // 3\n"
                "ChannelCache channels{};                   // 4\n"
                "PricingService svc{cfg, pg, channels};     // 5\n"
                "auto server = build_server(svc, cfg);      // 6\n"
                "health->Set(\"\", NOT_SERVING); warm(pg);    // 7-8\n"
                "health->Set(\"\", SERVING);                  // 9\n"
                "install_signal_handler(...);               // 10\n"
                "server->Wait();                            // 11\n"
                "return 0;  // reverse-order teardown       // 12"
            ),
            "notes": (
                "The capstone's main() is twelve steps and every one maps to a "
                "prior document — config from 12-factor, CPU budget from threading, "
                "pools from externalization, the composition root from process scope, the staged "
                "health flip and signal handling from health & shutdown. The shape is the "
                "same for any gRPC service in this stack; only the specific "
                "subsystems change. That reusability is the payoff of building "
                "the patterns in isolation first."),
        },
        {
            "kind": "content",
            "title": "Error translation at the boundary",
            "body": [
                heading("Helpers throw; the handler translates", color=C.ACCENT_ORANGE),
                bullet("Helpers throw grpc::Status for protocol errors (deadline, unavailable, not-found)"),
                bullet("Helpers throw std::exception for bugs"),
                bullet("The handler's single try/catch maps both to the wire status"),
                bullet("RAII runs all cleanup regardless of which exception propagates"),
            ],
            "notes": (
                "The error model keeps the handler clean: helper functions "
                "throw grpc::Status for things the client should see — "
                "DEADLINE_EXCEEDED, UNAVAILABLE, NOT_FOUND — and std::exception "
                "for programming errors. One try/catch at the handler boundary "
                "translates both into the right wire status. Crucially, the "
                "try/catch is only for translation; every resource is cleaned "
                "up by RAII no matter which path the exception takes."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 10,
            "demo_name": "Demo — gRPC capstone",
            "demo_command": "cd examples/statelessness/10-grpc-microservices && ./demo.sh",
            "demo_description": (
                "An order-pricing service composing every prior pattern, "
                "calling a tax service over gRPC. Three acts: a taxable order, "
                "a tax-exempt short-circuit, and an idempotent replay returning "
                "the identical order id."),
            "demo_url": "patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/statelessness-10-grpc-microservices/",
            "notes": (
                "Act 1 prices a taxable order for alice — full path: Postgres "
                "lookups plus the outbound tax gRPC call. Act 2 prices for "
                "tax-exempt carol, where compute_tax short-circuits and never "
                "calls the tax service. Act 3 replays act 1's idempotency key "
                "and gets back the IDENTICAL order id — proof the stored result "
                "came back, not a recomputation."),
        },
    ],
},

# ============================================================================
# §11 — Build tooling
# ============================================================================
{
    "num": 11,
    "label": "§11",
    "title": "Build tooling & vendored helpers",
    "tagline": "Conan, CMake, the toolchain — and the helpers made runnable.",
    "divider_notes": (
        "The appendix: the build setup that everything else assumed. Conan 2.x "
        "with pinned versions and a lockfile, CMake with Ninja and Conan "
        "presets, GCC 14 for C++23 breadth, multi-stage Containerfiles — and "
        "full source for the small vendored helpers earlier docs referenced."),
    "slides": [
        {
            "kind": "content",
            "title": "The build stack",
            "body": [
                heading("Hermetic, pinned, reproducible", color=C.ACCENT_BLUE),
                bullet("Conan 2.x — explicit version pins, dev + release profiles, a lockfile"),
                bullet("CMake 3.27+ with Ninja; Conan-generated presets wire the toolchain"),
                bullet("GCC 14 / libstdc++ for C++23 breadth (Clang 18 + libc++ equivalent)"),
                bullet("Multi-stage Containerfile: full toolchain builder, minimal runtime"),
                bullet("Dev profile wires AddressSanitizer — catches the PMR arena trap early"),
            ],
            "diagram": dg("11-build-tooling"),
            "notes": (
                "The build-tooling choices are stable even as the toolchain "
                "landscape moves. The one gotcha worth memorizing: protobuf and "
                "gRPC versions must match across Conan dependencies, or you get "
                "duplicate-symbol linker errors. The dev/release profile split "
                "is the high-value habit — ASan and UBSan in dev catch the "
                "arena lifetime bugs, the locks-across-co_await UB, and most "
                "resource leaks before they reach production."),
        },
        {
            "kind": "content",
            "title": "The cgroup helper, in one line",
            "body": [
                heading("Why the vendored helper exists", color=C.ACCENT_RED),
                bullet("hardware_concurrency() reports host cores — wrong under a cgroup"),
                bullet("cpu_limit_cores() reads cgroup v2 cpu.max → the real budget"),
                bullet("Under --cpus=0.5: helper reads 0.5 while hardware_concurrency() still says 22"),
                bullet("That gap is the whole reason to read the cgroup — and Demo 11 makes it visible"),
            ],
            "notes": (
                "This is the punchline of the whole threading story, made "
                "concrete in a 30-line helper. The demo runs the same binary "
                "under different --cpus caps; cpu_limit_cores() tracks the cap "
                "exactly — 1.5, then 0.5 — while hardware_concurrency() keeps "
                "reporting the host's 22 cores. A naive pool would oversubscribe "
                "22-to-1 against half a core and get throttled into the ground. "
                "Read the cgroup."),
        },
        {
            "kind": "content",
            "title": "C++23 feature support is a version question",
            "body": [
                heading("The toolchain decides what you can use", color=C.ACCENT_BLUE),
                bullet("std::expected — GCC 12+, Clang 16+"),
                bullet("<stacktrace> — GCC 14+ (link libstdc++_libbacktrace), Clang 18+"),
                bullet("std::flat_map / flat_set — GCC 15+; not in libc++ yet (use absl::btree_map)"),
                bullet("std::print / println — GCC 14+, Clang 18+ (partial)"),
                para("GCC 14 + libstdc++ on glibc 2.35+ is the recommended 2026 baseline.",
                     size=Pt(15), italic=True, color=C.TEXT_MUTED),
            ],
            "notes": (
                "Which C++23 features you can use is a function of the compiler "
                "version, and it moves fast. The ones that bite: std::flat_map "
                "isn't in libstdc++ until GCC 15, so until then absl::btree_map "
                "is the fallback; <stacktrace> on GCC 14 needs an explicit link "
                "flag for libstdc++_libbacktrace. The recommended baseline is "
                "GCC 14 with libstdc++ on a glibc 2.35-or-newer host, which is "
                "what every example in this tutorial builds against."),
        },
        {
            "kind": "content",
            "title": "Build-tooling gotchas worth memorizing",
            "body": [
                heading("The traps that cost an afternoon", color=C.ACCENT_RED),
                bullet("protobuf and gRPC versions MUST match across Conan deps → else duplicate symbols"),
                bullet("Always compiler.libcxx=libstdc++11 (the post-GCC-5 ABI); mixing crashes"),
                bullet("Run CMake via the Conan preset/toolchain or find_package can't see deps"),
                bullet("libpqxx's bundled CMake breaks this toolchain → use libpq (G-67)"),
            ],
            "notes": (
                "A short list of traps from the real build experience of this "
                "tutorial. The protobuf/gRPC version match is the most common — "
                "two libraries pulling different protobuf versions transitively "
                "gives you duplicate-symbol linker errors. The libstdc++11 ABI "
                "setting is non-negotiable; mixing the old and new ABI produces "
                "crashes that look like memory corruption. And the libpqxx one "
                "is ours specifically: its bundled CMake breaks the toolchain, "
                "which is why every example here reaches PostgreSQL via libpq."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 11,
            "demo_name": "Demo — Vendored helpers",
            "demo_command": "cd examples/statelessness/11-build-tooling && ./demo.sh",
            "demo_description": (
                "cgroup_helper and psi_reader built as static libraries, "
                "unit-tested with GoogleTest over their pure parsers, and a "
                "binary swept under --cpus / --memory caps so cpu_limit_cores() "
                "is shown tracking the cgroup while hardware_concurrency() does "
                "not."),
            "demo_url": "patterncatalyst.github.io/cpp-container-optimization-tutorial/examples/statelessness-11-build-tooling/",
            "notes": (
                "Act 1 runs the gtest suite green inside the container. Then the "
                "cap sweep: unconstrained, --cpus=1.5, --cpus=0.5 --memory=256m. "
                "Watch cpu_limit_cores() report 1.5 then 0.5, memory report "
                "256 MiB, while hardware_concurrency() stays at the host count "
                "throughout. That contrast is the entire lesson."),
        },
    ],
},

]
