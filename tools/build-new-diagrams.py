#!/usr/bin/env python3
"""
build-new-diagrams.py — author the main-tutorial concept diagrams and write
each as a paired <name>.svg + <name>.excalidraw via tools/diagramgen.py.

  diagrams/13-abi-break-taxonomy             (main §13)
  diagrams/11-numa-local-remote              (main §11)

Run from the repo root: python3 tools/build-new-diagrams.py

(The statelessness-compendium diagrams this script once also built were moved
to the standalone cpp-statelessness project and removed from this repo.)
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
# 1. ABI-break taxonomy
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
# 2. NUMA local-vs-remote
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


def main():
    builders = [abi_taxonomy, numa_local_remote]
    for b in builders:
        d = b()
        base = d.write(DG)
        rel = base.relative_to(ROOT)
        print(f"  wrote {rel}.svg + {rel}.excalidraw")
    print(f"\n{len(builders)} diagrams written.")


if __name__ == "__main__":
    main()
