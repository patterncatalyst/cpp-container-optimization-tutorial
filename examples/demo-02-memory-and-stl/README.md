# Demo 2 — Memory layout and allocator choices

Tutorial sections: §5 (STL containers and layout), §6 (Memory management)

## What this demo shows

A microbench harness, packaged as a container, that runs three pairs of
comparisons and prints a single comparison table at the end:

1. **Lookup-heavy workload** — `std::set<int>` vs `std::flat_set<int>` over
   the same key distribution. (`flat_set` is C++23; the example feature-tests
   for it and falls back to a vendored `boost::container::flat_set` if the
   stdlib build doesn't have it.)

2. **Allocator-bound workload** — many short-lived small allocations,
   compared across:
   - default `new`/`delete` (system glibc malloc)
   - mimalloc, preloaded with `LD_PRELOAD`
   - PMR with a `std::pmr::monotonic_buffer_resource` carved out per request

3. **Page-size sensitivity** — a large random-access workload run with and
   without transparent huge pages enabled, plus a run where the cgroup's
   `memory.high` is set tight enough to force reclaim during the workload.

The point isn't "X is faster than Y in the abstract." The point is to give
the audience a concrete moment of "the allocator/container choice matters
about *this much* on *this kind of workload*," and to show how to reproduce
the measurement in their own environment.

## Run it

```bash
./demo.sh
./demo.sh --quick    # smaller iteration counts, ~30s instead of ~3min
./demo.sh --clean
```

## What you'll see

A table on stdout, plus three CSVs under `results/` for each comparison.
The CSVs are intentionally small and human-readable so you can paste them
into the deck or graph them with whatever you like.

## What you'll need

- Podman 5.x rootless (see §1)
- `hey`, `jq`, `bc` on the host
- For the THP comparison: ability to read `/sys/kernel/mm/transparent_hugepage/enabled`
  (read-only is fine; the demo does not toggle THP — it just reports the host setting
  and runs the workload twice with `MALLOC_CONF` tuned differently)

## Limitations and notes

- Rootless cgroups v2 must allow `memory.high`. On Fedora 44 this is the default,
  but on some distros you need to enable `cgroup.controllers` delegation. The
  demo prints a clear error if it can't write `memory.high` and continues without
  that comparison rather than failing.
- mimalloc is fetched as a binary release on first run; pinned version in `demo.sh`.
