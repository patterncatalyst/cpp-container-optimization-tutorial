---
title: "Statelessness 03 — PMR request arena"
description: "The runnable companion to compendium Doc 03: the layered monotonic + pool arena, per-request allocation, the bulk-release-vs-per-object asymmetry, and the lifetime trap caught by AddressSanitizer."
order: 203
layout: example
sectionid: examples
permalink: /examples/statelessness-03-pmr/
demo_dir: statelessness/03-pmr
github_path: examples/statelessness/03-pmr
---

> The full source for this example lives in [`examples/statelessness/03-pmr/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/03-pmr) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 03 — PMR and the request arena]({{ '/reference/statelessness/03-pmr/' | relative_url }})

Where [02-raii]({{ '/examples/statelessness-02-raii/' | relative_url }})
showed a `RequestContext` carrying a small arena, this example goes deep
on the arena itself: the layered resource recipe, per-request
allocation, the release-cost asymmetry, and the lifetime trap.

## What it demonstrates

**The layered request arena.** A `monotonic_buffer_resource` for O(1)
bump allocation, layered over an `unsynchronized_pool_resource` that
recycles size-classed blocks, over `new_delete_resource`. The whole
arena releases together when it leaves scope. The type is deliberately
**non-movable** — the monotonic resource holds a pointer into the
arena's own buffer, so moving it would dangle that pointer.

**`mode=arena`** splits the payload into arena-allocated tokens
(`std::pmr::vector<std::pmr::string>`) and counts them in a
`std::pmr::unordered_map`, all freed in bulk at scope end.

**`mode=bench`** times allocating + releasing N objects through the
arena versus N individual `new`/`delete` pairs, returning both numbers.
Read them as context, not a scoreboard: Doc 03 is explicit that PMR's
reliable win is bounded, predictable per-request memory and shrunken
tail-latency variance — *not* mean throughput. glibc's allocator is
fast, so at modest N the heap can match or beat the arena's wall clock.
The architectural reason is the point; the numbers are confirmation when
they confirm.

**The lifetime trap** is a standalone AddressSanitizer binary,
`pmr-trap`. It stores a `std::string_view` into arena memory in a
process-scoped cache, lets the arena die, then reads the cache — ASan
reports `heap-use-after-free`. The nonzero exit is the point: without
ASan the bug is silent until the freed memory is reused, the kind of
"random" production failure that's miserable to chase. It lives in its
own binary because you cannot safely host a use-after-free inside a
long-lived service. The fix is in
[Doc 07]({{ '/reference/statelessness/07-state-externalization/' | relative_url }}).

## Running it

```bash
cd examples/statelessness/03-pmr
./demo.sh            # build + arena + bench + the ASan trap
./demo.sh --clean    # tear down
```

CI verification: `scripts/test-stateless-demo-03-pmr.sh`.

A note on ASan in containers: the demo runs `pmr-trap` directly, and on
most kernels ASan maps its shadow memory fine. If you hit
`Shadow memory range interleaves` at startup (high ASLR entropy on newer
kernels), the in-container `setarch -R` fix doesn't apply — the
`personality` syscall it needs is blocked by seccomp — so apply a
host-side mitigation: `sudo sysctl vm.mmap_rnd_bits=28` or
`--security-opt seccomp=unconfined`. The trap itself is real either way.
For what shadow memory is and the full set of failure modes, see
[§12 Analysis &amp; debugging]({{ '/docs/12-analysis-debugging/' | relative_url }}).

## Where it sits in the compendium

PMR builds directly on the RAII request scope from
[Doc 02]({{ '/examples/statelessness-02-raii/' | relative_url }}); the
threading rules behind the `unsynchronized` choice are in
[Doc 05]({{ '/reference/statelessness/05-threading/' | relative_url }}),
and the cache fix for the lifetime trap is in
[Doc 07]({{ '/reference/statelessness/07-state-externalization/' | relative_url }}).
