#!/usr/bin/env python3
"""
build-new-diagrams.py — author the six new concept diagrams (r181) and write
each as a paired <name>.svg + <name>.excalidraw via tools/diagramgen.py.

  diagrams/11-cfs-throttling-timeline        (main §11 + statelessness 05)
  diagrams/08-deadline-budget-flow           (main §8 + statelessness 07/10)
  diagrams/13-abi-break-taxonomy             (main §13)
  diagrams/11-numa-local-remote              (main §11)
  diagrams/statelessness/07-outbox-sequence  (statelessness 07-outbox)
  diagrams/statelessness/09-probe-states-shutdown (statelessness 09)

Run from the repo root: python3 tools/build-new-diagrams.py
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from diagramgen import Diagram  # noqa: E402

random.seed(11)  # deterministic ids across rebuilds
ROOT = Path(__file__).resolve().parent.parent
DG = ROOT / "diagrams"


# ===========================================================================
# 1. CFS throttling timeline
# ===========================================================================
def cfs_throttling():
    d = Diagram(
        "11-cfs-throttling-timeline", 900, 520,
        "CFS quota throttling — why oversubscription wrecks tail latency",
        "A timeline comparison of two thread-pool sizes under the same cgroup "
        "CPU quota of two cores (cpu.max 200000 100000 = 200ms of CPU time per "
        "100ms period). The top lane, a pool sized to the quota with two "
        "threads, spends its budget evenly and completes work every period with "
        "steady low p99. The bottom lane, an oversubscribed pool of eight "
        "threads, burns the whole quota in the first quarter of each period and "
        "is then throttled — the kernel deschedules the entire cgroup until the "
        "next period boundary — so a request arriving during the throttle "
        "window waits up to a full period, spiking p99. The fix is to size the "
        "pool to cpu_limit_cores(), not hardware_concurrency().")
    d.text(450, 50, "cpu.max = \"200000 100000\"  →  200 ms CPU per 100 ms "
           "period = 2 cores", "sec", "middle")

    x0, pw, n = 150, 120, 5
    # period grid + axis labels for both lanes
    for lane_y in (95, 250):
        for i in range(n + 1):
            x = x0 + i * pw
            d.line(x, lane_y, x, lane_y + 95, color="#cdbfa6", sw=0.8, dashed=True)
        for i in range(n):
            d.text(x0 + i * pw + pw / 2, lane_y - 6,
                   f"period {i+1}", "mono-sm", "middle")

    # Lane A — right-sized
    d.text(20, 120, "Right-sized", "ttl", "start")
    d.text(20, 136, "2 threads", "mono-sm", "start")
    d.text(20, 150, "--cpus=2", "mono-sm", "start")
    for i in range(n):
        x = x0 + i * pw + 6
        d.rect(x, 100, pw - 12, 56, fill="#d8e8df", stroke="#5a8870", sw=1.2)
        d.text(x0 + i * pw + pw / 2, 132, "work fits quota", "mono-sm", "middle")
    d.text(x0 + n * pw + 12, 128, "steady p99", "accent-l", "start")
    d.line(x0, 165, x0 + n * pw, 165, color="#5a8870", sw=1.2)

    # Lane B — oversubscribed
    d.text(20, 275, "Oversubscribed", "ttl", "start")
    d.text(20, 291, "8 threads", "mono-sm", "start")
    d.text(20, 305, "--cpus=2", "mono-sm", "start")
    burst = int((pw - 12) * 0.32)
    for i in range(n):
        x = x0 + i * pw + 6
        d.rect(x, 255, burst, 56, fill="#f0e8d8", stroke="#b89540", sw=1.2)
        d.rect(x + burst, 255, (pw - 12) - burst, 56,
               fill="#f4d7cf", stroke="#c0392b", sw=1.5)
    d.text(x0 + pw * 0.5, 287, "quota", "mono-sm", "middle")
    d.text(x0 + pw * 2 + pw * 0.55, 280, "THROTTLED", "accent-t", "middle")
    d.text(x0 + pw * 2 + pw * 0.55, 298, "cgroup descheduled", "accent-l", "middle")
    d.line(x0, 320, x0 + n * pw, 320, color="#c0392b", sw=1.2)

    # a request arriving mid-throttle waits to the boundary
    rq_x = x0 + pw * 3 + burst + 14
    d.arrow(rq_x, 360, rq_x, 322, "arrow-r")
    d.arrow(rq_x, 340, x0 + pw * 4, 340, "arrow-r",
            label="waits ~ up to one full period (≈100 ms)",
            label_cls="accent-l", label_dy=-6)
    d.text(rq_x, 374, "request arrives during throttle", "mono-sm", "middle")

    d.band(120, 410, 660, 70, "red",
           title="Throughput barely moves; the tail falls off a cliff",
           sub="More threads than quota cannot run in parallel — they take "
               "turns, and the kernel enforces the turns by stalling the whole cgroup.",
           lines=[("Fix: size the pool to cpu_limit_cores() (reads cpu.max), "
                   "not std::thread::hardware_concurrency() (reports host cores).",
                   "accent-l")])
    return d


# ===========================================================================
# 2. Deadline-budget propagation
# ===========================================================================
def deadline_budget():
    d = Diagram(
        "08-deadline-budget-flow", 900, 480,
        "Deadline budget propagation — one clock, every hop",
        "A request arrives with a 100 ms deadline. The budget is a single bar "
        "that every hop spends against the same clock: a little to inbound "
        "network, a slice to the service plus its PostgreSQL query whose "
        "statement_timeout is set from the time remaining, a slice to the "
        "outbound gRPC call which carries the same absolute deadline, and the "
        "rest is slack before the response returns. The rule beneath it: before "
        "any downstream call, if the remaining budget is at or below zero the "
        "service throws DEADLINE_EXCEEDED and fails fast instead of starting "
        "work that cannot finish in time.")
    d.text(450, 50, "inbound deadline = 100 ms  ·  every downstream call "
           "budgets against the same clock", "sec", "middle")

    bx, bw = 80, 740  # 740px == 100ms
    per_ms = bw / 100.0
    segs = [
        (0, 3,  "blue",  "network in"),
        (3, 45, "gold",  "service + Postgres  (statement_timeout = remaining)"),
        (45, 70, "green", "outbound gRPC tax call  (same deadline)"),
        (70, 80, "purple", "assemble reply"),
        (80, 100, "paper", "slack"),
    ]
    by = 95
    for a, b, var, lbl in segs:
        fill, stroke, sw = {
            "blue": ("#e8f0fb", "#4a73b8"), "gold": ("#f0e8d8", "#b89540"),
            "green": ("#d8e8df", "#5a8870"), "purple": ("#ece4f0", "#8a5fb0"),
            "paper": ("#f4efe4", "#cdbfa6"),
        }[var] + (1.2,)
        d.rect(bx + a * per_ms, by, (b - a) * per_ms, 46, fill=fill,
               stroke=stroke, sw=sw)
    # tick marks 0..100ms
    for ms in range(0, 101, 10):
        x = bx + ms * per_ms
        d.line(x, by + 46, x, by + 54, color="#9a9183", sw=0.8)
        d.text(x, by + 66, f"{ms}", "mono-sm", "middle")
    d.text(bx + bw / 2, by + 80, "milliseconds of the request budget", "sec", "middle")
    # segment captions (alternating above)
    d.text(bx + 24 * per_ms, by + 28, "service + PG query", "mono-sm", "middle")
    d.text(bx + 57 * per_ms, by + 28, "tax gRPC", "mono-sm", "middle")
    d.text(bx + 90 * per_ms, by + 28, "slack", "mono-sm", "middle")

    # hop boxes with remaining budget each receives
    hops = [
        (90,  "Client", "sets deadline", "100 ms"),
        (300, "Pricing service", "remaining on entry", "≈ 97 ms"),
        (520, "PostgreSQL", "statement_timeout", "= remaining"),
        (720, "Tax service", "ClientContext deadline", "≈ 55 ms"),
    ]
    hy = 230
    for hx, name, role, val in hops:
        d.band(hx, hy, 165, 70, "blue", title=name,
               lines=[(role, "mono-sm"), (val, "accent-l")])
    for i in range(len(hops) - 1):
        x1 = hops[i][0] + 165
        x2 = hops[i + 1][0]
        d.arrow(x1, hy + 35, x2, hy + 35, "arrow", label="deadline", label_dy=-6)

    d.band(120, 350, 660, 78, "red",
           title="Fail fast when the budget is gone",
           sub="A slow dependency must not outlive the client's patience.",
           lines=[("auto left = deadline - now();  if (left <= 0ms) "
                   "throw grpc::Status{DEADLINE_EXCEEDED};", "mono"),
                  ("Never start a downstream call you can't finish in time.",
                   "accent-l")])
    return d


# ===========================================================================
# 3. ABI-break taxonomy
# ===========================================================================
def abi_taxonomy():
    d = Diagram(
        "13-abi-break-taxonomy", 900, 560,
        "ABI compatibility — what is safe to change and what breaks the ABI",
        "Two columns contrast changes that preserve the binary interface "
        "against changes that break it. ABI-safe changes include adding a "
        "non-virtual member function, adding static data members, appending an "
        "enumerator, and changing a function body. ABI-breaking changes include "
        "adding, removing, or reordering data members, which changes struct "
        "layout; adding, removing, or reordering virtual functions, which "
        "changes the vtable; changing a base class; changing a member's type or "
        "size; and changing a function signature, which changes the mangled "
        "name. The consequence of shipping a break under the same SONAME is "
        "silent crashes or undefined behavior at load time; abidiff detects "
        "these and the fix is to bump the SONAME.")
    d.text(450, 50, "Recompiling isn't enough — a library swapped at runtime "
           "must keep the same binary contract", "sec", "middle")

    safe = [
        "Add a non-virtual member function",
        "Add static data members / constants",
        "Append an enumerator at the end",
        "Change a function body (same signature)",
        "Add a new exported free function",
        "Add a new class / type",
    ]
    brk = [
        "Add / remove / reorder data members  → layout",
        "Add / remove / reorder virtual fns  → vtable",
        "Change or add/remove a base class",
        "Change a member's type or size",
        "Change a function signature  → mangled name",
        "Change inline fn semantics across TUs  → ODR",
    ]
    # Safe column
    d.band(60, 90, 360, 40, "green", title="ABI-SAFE — same SONAME is fine",
           title_cls="ttl")
    y = 145
    for s in safe:
        d.rect(60, y, 360, 34, fill="#eef5f0", stroke="#5a8870", sw=1.0)
        d.text(76, y + 22, s, "mono-sm", "start")
        y += 42
    # Breaking column
    d.band(480, 90, 360, 40, "red", title="ABI-BREAKING — must bump SONAME",
           title_cls="ttl")
    y = 145
    for s in brk:
        d.rect(480, y, 360, 34, fill="#f6dfd8", stroke="#c0392b", sw=1.2)
        d.text(496, y + 22, s, "mono-sm", "start")
        y += 42

    d.band(120, 420, 660, 96, "paper",
           title="Why it matters under containers",
           sub="A base image update can swap a shared library beneath your "
               "binary without a recompile.",
           lines=[("Same SONAME + ABI break  →  silent crashes / UB at load time.",
                   "accent-l"),
                  ("Catch it: abidiff (libabigail) in CI compares the old and new "
                   ".so for layout / vtable / symbol changes.", "mono-sm"),
                  ("Static-link or pin the exact runtime to sidestep the swap "
                   "entirely (the multi-stage image's job).", "mono-sm")])
    return d


# ===========================================================================
# 4. NUMA local-vs-remote
# ===========================================================================
def numa_local_remote():
    d = Diagram(
        "11-numa-local-remote", 900, 470,
        "NUMA — local versus remote memory access latency",
        "Two NUMA nodes, each with a set of CPU cores and its own attached "
        "local memory, joined by a cross-node interconnect. A core reading its "
        "local node's memory is fast, around 100 nanoseconds. The same core "
        "reading the other node's memory must cross the interconnect and is "
        "roughly one and a half to two times slower. The takeaway, tied to the "
        "cgroup cpuset controller, is to pin a latency-sensitive workload to a "
        "single node with cpuset.cpus and cpuset.mems so its memory accesses "
        "stay local.")
    d.text(450, 50, "Not all memory is equally far — the node a core sits on "
           "decides its memory latency", "sec", "middle")

    # Node 0
    d.band(60, 90, 360, 250, "blue", title="NUMA node 0", title_cls="ttl",
           anchor="middle")
    d.rect(90, 130, 300, 60, fill="#fdfbf7", stroke="#4a73b8", sw=1.0)
    d.text(240, 158, "cores 0–10", "lbl", "middle")
    d.text(240, 176, "cpuset.cpus = 0-10", "mono-sm", "middle")
    d.band(90, 240, 300, 70, "green", title="local memory (Mem0)",
           lines=[("cpuset.mems = 0", "mono-sm")])
    # Node 1
    d.band(480, 90, 360, 250, "brown", title="NUMA node 1", title_cls="ttl",
           anchor="middle")
    d.rect(510, 130, 300, 60, fill="#fdfbf7", stroke="#b86742", sw=1.0)
    d.text(660, 158, "cores 11–21", "lbl", "middle")
    d.text(660, 176, "cpuset.cpus = 11-21", "mono-sm", "middle")
    d.band(510, 240, 300, 70, "green", title="local memory (Mem1)",
           lines=[("cpuset.mems = 1", "mono-sm")])

    # local access (fast, green) within node 0
    d.arrow(240, 190, 240, 240, "arrow-g", label="local ≈ 100 ns",
            label_cls="mono-sm", label_dx=70)
    # remote access (slow, red) core0 -> Mem1 across interconnect
    d.arrow(390, 160, 510, 275, "arrow-r")
    d.text(450, 205, "remote", "accent-t", "middle")
    d.text(450, 221, "≈1.5–2× slower", "accent-l", "middle")
    # interconnect
    d.line(420, 215, 480, 215, color="#8a5fb0", sw=2.0)
    d.text(450, 130, "interconnect", "mono-sm", "middle")

    d.band(120, 370, 660, 70, "red",
           title="Pin latency-sensitive work to one node",
           sub="Crossing the interconnect adds latency and contends with other "
               "tenants' traffic.",
           lines=[("cpuset.cpus + cpuset.mems on the same node keeps a hot path's "
                   "memory local (see the cgroup isolation diagram).", "accent-l")])
    return d


# ===========================================================================
# 5. Outbox sequence (statelessness)
# ===========================================================================
def outbox_sequence():
    d = Diagram(
        "statelessness/07-outbox-sequence", 980, 620,
        "Outbox pattern — atomic write, relay, idempotent consumer",
        "A downward sequence across five lifelines: client, order service, "
        "PostgreSQL, a relay, Kafka, and a consumer. In phase one the order "
        "service writes both the order row and an outbox event row inside a "
        "single PostgreSQL transaction, so there is no moment where the order "
        "exists but the event was lost. In phase two a relay selects unpublished "
        "outbox rows with FOR UPDATE SKIP LOCKED, produces each event to Kafka, "
        "waits for the broker acknowledgement, then marks the row published and "
        "commits; a crash before that commit re-publishes on the next pass, "
        "giving at-least-once delivery. In phase three the consumer applies each "
        "event with INSERT ON CONFLICT DO NOTHING and commits the Kafka offset "
        "only after the database write, so a duplicate delivery is a no-op and "
        "the end-to-end effect is exactly-once.")
    lanes = [(90, "Client"), (250, "Order service"), (430, "PostgreSQL"),
             (590, "Relay"), (720, "Kafka"), (850, "Consumer")]
    for lx, name in lanes:
        d.band(lx - 62, 64, 124, 34, "blue", title=name, title_cls="ttl-sub")
        d.line(lx, 98, lx, 560, color="#cdbfa6", sw=1.0, dashed=True)

    def lane(i):
        return lanes[i][0]

    # phase backgrounds
    d.rect(40, 120, 900, 120, fill="#fbf6ee", stroke="#cdbfa6", sw=0.8, dashed=True)
    d.text(52, 138, "1 · atomic write", "accent-t", "start")
    d.rect(40, 255, 900, 175, fill="#fbf6ee", stroke="#cdbfa6", sw=0.8, dashed=True)
    d.text(52, 273, "2 · relay (at-least-once)", "accent-t", "start")
    d.rect(40, 445, 900, 120, fill="#fbf6ee", stroke="#cdbfa6", sw=0.8, dashed=True)
    d.text(52, 463, "3 · idempotent consumer", "accent-t", "start")

    # phase 1
    d.arrow(lane(0), 160, lane(1), 160, "arrow",
            label="CreateOrder(key)", label_dy=-6)
    d.rect(lane(2) - 95, 178, 190, 48, fill="#f4d7cf", stroke="#c0392b", sw=1.5)
    d.text(lane(2), 196, "BEGIN  ·  one txn", "accent-t", "middle")
    d.text(lane(2), 212, "INSERT order + INSERT outbox", "mono-sm", "middle")
    d.arrow(lane(1), 200, lane(2) - 95, 200, "arrow")
    d.text(lane(2), 240, "COMMIT  → no lost-event window", "accent-l", "middle")

    # phase 2
    d.arrow(lane(3), 300, lane(2), 300, "arrow",
            label="SELECT … FOR UPDATE SKIP LOCKED", label_dy=-6)
    d.arrow(lane(3), 340, lane(4), 340, "arrow",
            label="produce(event) · flush (ack)", label_dy=-6)
    d.arrow(lane(3), 392, lane(2), 392, "arrow",
            label="mark published · COMMIT", label_dy=-6)
    d.text(lane(3), 416, "crash before COMMIT → re-publish next pass", "accent-l", "middle")

    # phase 3
    d.arrow(lane(4), 484, lane(5), 484, "arrow",
            label="deliver event", label_dy=-6)
    d.rect(lane(5) - 70, 496, 130, 32, fill="#f4d7cf", stroke="#c0392b", sw=1.2)
    d.text(lane(5) - 5, 516, "ON CONFLICT", "mono-sm", "middle")
    d.arrow(lane(5), 548, lane(4), 548, "arrow",
            label="commit offset AFTER db write", label_cls="mono-sm", label_dy=-6)

    d.band(180, 578, 620, 36, "green", title="at-least-once delivery + "
           "idempotent apply = exactly-once effect", title_cls="ttl-sub")
    return d


# ===========================================================================
# 6. Health-probe state machine + shutdown (statelessness)
# ===========================================================================
def probe_states_shutdown():
    d = Diagram(
        "statelessness/09-probe-states-shutdown", 920, 590,
        "Health states and the graceful-shutdown sequence",
        "The top half is a state machine. The service starts in Starting, where "
        "liveness already answers 200 but readiness reports NOT_SERVING during "
        "initialization; when init completes it transitions to Serving. From "
        "Serving a SIGUSR1 toggles readiness to and from NotReady without "
        "restarting the replica, because liveness stays green the whole time. A "
        "SIGTERM moves the service to Draining and then to Stopped with exit "
        "zero. The bottom half is the ordered shutdown sequence the SIGTERM "
        "triggers: the handler only sets a flag, then a control thread flips "
        "readiness to NOT_SERVING, requests the background workers to stop, "
        "calls server Shutdown with a deadline to drain in-flight RPCs, runs the "
        "reverse-order teardown of process-scoped state, and exits zero. "
        "Liveness fails only for what a restart fixes; readiness drains.")
    # state machine
    d.text(60, 80, "State machine", "ttl", "start")
    d.band(60, 95, 175, 64, "gold", title="Starting",
           lines=[("live: 200", "mono-sm"), ("ready: NOT_SERVING", "mono-sm")])
    d.band(330, 95, 175, 64, "green", title="Serving",
           lines=[("live: 200", "mono-sm"), ("ready: SERVING", "mono-sm")])
    d.band(330, 195, 175, 64, "blue", title="NotReady",
           lines=[("live: 200 (not restarted)", "mono-sm"),
                  ("ready: NOT_SERVING", "mono-sm")])
    d.band(600, 95, 150, 64, "brown", title="Draining",
           lines=[("drain in-flight", "mono-sm")])
    d.band(790, 95, 110, 64, "red", title="Stopped",
           lines=[("exit 0", "accent-l")])
    d.arrow(235, 127, 330, 127, "arrow", label="init done", label_dy=-6)
    d.arrow(417, 159, 417, 195, "arrow-g", label="SIGUSR1", label_cls="mono-sm",
            label_dx=46)
    d.arrow(400, 195, 400, 159, "arrow-g", label="SIGUSR1", label_cls="mono-sm",
            label_dx=-46)
    d.arrow(505, 127, 600, 127, "arrow-r", label="SIGTERM", label_dy=-6)
    d.arrow(750, 127, 790, 127, "arrow")

    # shutdown sequence
    d.text(60, 320, "Graceful-shutdown sequence (SIGTERM)", "ttl", "start")
    steps = [
        "signal handler: set volatile sig_atomic_t flag  (async-signal-safe only)",
        "control thread: readiness → NOT_SERVING   (LB stops sending traffic)",
        "request_stop() background workers   (std::stop_token, cooperative)",
        "server->Shutdown(deadline)   (drain in-flight RPCs)",
        "reverse-order teardown of process-scoped state   (pools, channels, config)",
        "exit 0",
    ]
    y = 340
    for i, s in enumerate(steps):
        var = "red" if i == len(steps) - 1 else "paper"
        d.rect(60, y, 700, 30,
               fill="#f4d7cf" if var == "red" else "#f4efe4",
               stroke="#c0392b" if var == "red" else "#cdbfa6",
               sw=1.2 if var == "red" else 1.0)
        d.text(74, y + 20, f"{i+1}.  {s}",
               "accent-l" if var == "red" else "mono-sm", "start")
        if i < len(steps) - 1:
            d.arrow(410, y + 30, 410, y + 38, "arrow")
        y += 38

    d.band(790, 340, 110, 90, "green",
           title="liveness", lines=[("fails ONLY for", "mono-sm"),
                                     ("what a restart", "mono-sm"),
                                     ("fixes", "mono-sm"),
                                     ("readiness drains", "accent-l")])
    return d


def main():
    builders = [cfs_throttling, deadline_budget, abi_taxonomy, numa_local_remote,
                outbox_sequence, probe_states_shutdown]
    for b in builders:
        d = b()
        base = d.write(DG)
        rel = base.relative_to(ROOT)
        print(f"  wrote {rel}.svg + {rel}.excalidraw")
    print(f"\n{len(builders)} diagrams written.")


if __name__ == "__main__":
    main()
