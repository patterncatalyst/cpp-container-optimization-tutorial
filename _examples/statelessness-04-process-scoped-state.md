---
title: "Statelessness 04 — Process-scoped state"
description: "The runnable companion to compendium Doc 04: the composition root in main(), dependency injection by reference, a bounded LRU cache sized against the cgroup budget, and correct reverse-order teardown for free from RAII."
order: 204
card_eyebrow: "Compendium · <strong>Doc 04</strong>"
card_title: "Process-scoped state"
card_blurb: "The composition root in main(), dependency injection by reference, a bounded LRU cache sized against the cgroup budget, and correct reverse-order teardown for free from RAII."
layout: example
sectionid: examples
permalink: /examples/statelessness-04-process-scoped-state/
demo_dir: statelessness/04-process-scoped-state
github_path: examples/statelessness/04-process-scoped-state
---

> The full source for this example lives in [`examples/statelessness/04-process-scoped-state/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/04-process-scoped-state) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 04 — Process-scoped state and the State Architecture Table]({{ '/reference/statelessness/04-process-scoped-state/' | relative_url }})

Not all state is request-scoped. A service holds a parsed config, a
metrics registry, a connection pool, an in-process cache — built once
and shared across every request. Doc 04 calls this *process-scoped*
state and argues for wiring it in `main()` rather than reaching for
singletons. This example makes that wiring, and the correct-teardown
property that falls out of it, visible.

## What it demonstrates

**The composition root.** `main()` constructs every piece of
process-scoped state by name, in dependency order, and injects it into
the service by reference:

```
config → metrics → cache → service → server
```

Each object logs on construction, so the startup output shows the build
order. No Meyers singletons, no hidden construction order.

**Dependency injection, not global lookup.** The service receives
`const ServiceConfig&`, `MetricsRegistry&`, and `BoundedCache&` as
constructor parameters. `main()` owns them; the service borrows them.

**Correct teardown for free.** Dependencies are constructed before their
users, so RAII destroys them in the exact reverse order at exit —
`server → service → cache → metrics → config` — which is also the
correct shutdown order (server stops first, then the state it relied on).
No manual choreography; each destructor logs, so the order is visible
when you stop the container.

**Bounded state.** The cache is an LRU with a hard capacity
(`CACHE_CAPACITY`, default 4). Look up more distinct keys than it holds
and it evicts the least-recently-used entry rather than growing — the
sizing discipline Doc 04 stresses. An unbounded map keyed on request
input is the classic "works in test, OOM-killed in prod" bug.

**Thread-safe shared state** (foreshadows Doc 05): the shared cache takes
a mutex, the metrics are atomic, the immutable config needs neither.

## Running it

```bash
cd examples/statelessness/04-process-scoped-state
./demo.sh            # composition root + eviction + teardown
./demo.sh --clean    # tear down
```

CI verification: `scripts/test-stateless-demo-04-process-scoped-state.sh`.

## The State Architecture Table, made concrete

| Column | In this example |
|--------|-----------------|
| Process-scoped | `ServiceConfig`, `MetricsRegistry`, `BoundedCache` — built in `main()` |
| Request-scoped | per-`Lookup` locals (see [02-raii]({{ '/examples/statelessness-02-raii/' | relative_url }}) and [03-pmr]({{ '/examples/statelessness-03-pmr/' | relative_url }})) |
| External | the cache-miss path stands in for a DB/Redis fetch — the real thing is [Doc 07]({{ '/reference/statelessness/07-state-externalization/' | relative_url }}) |
