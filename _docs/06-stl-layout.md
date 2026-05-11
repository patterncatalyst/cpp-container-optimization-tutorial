---
title: "STL, Layout, and C++20/23 Containers"
order: 6
description: Why `std::vector` is almost always the answer, when C++23 `flat_map` and `flat_set` win, and the silent memory overheads that betray "obvious" choices.
duration: 15 minutes
---

## Learning objectives

By the end of this section you can:

- Predict the cache behaviour of `std::vector`, `std::deque`,
  `std::list`, `std::map`, and `std::unordered_map` on a hot loop.
- Pick between `std::map`, `std::unordered_map`, `std::flat_map`
  (C++23), and a sorted `std::vector` of pairs based on access
  pattern.
- Identify "silent overhead" — `std::function`, `std::shared_ptr`
  refcounts, `std::any`, `std::optional` of small types, virtual
  dispatch on a hot path — and decide whether each is worth what
  it costs you.
- Use `std::span` (C++20) and `std::mdspan` (C++23) to pass views
  without sharing ownership.

## Diagram

{% include excalidraw.html name="06-stl-layout-flat-vs-node" caption="Cache-line footprint: `vector<T>` vs `flat_set<T>` vs `unordered_map<K,V>`" %}

## Planned content

- The "default to `std::vector`" rule, and the four cases where
  it's wrong (huge, frequently-resized in the middle, requires
  stable iterators, very tiny on a small-buffer-optimized type).
- `std::flat_map` / `std::flat_set` (C++23): what they are
  (sorted-vector adapters), what they cost (linear insert), what
  they buy (cache-friendly lookup, lower per-element overhead).
- `std::unordered_map` reality check: bucket pointers, load factor,
  hash quality. What `boost::unordered_flat_map` does differently.
- The over-abstraction trap: each `std::function`, `std::any`,
  `std::variant<...>` adds bytes and indirection that don't show
  up in the type system. Two cases studied; one stays, one goes.
- `std::span` for pass-by-view: what changes in API design when
  you stop passing `const std::vector<T>&`.
- C++23 `std::mdspan`: when a multi-dimensional view earns its
  keep over a hand-rolled stride.

## Demo

[`examples/demo-02-stl-layout/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-02-stl-layout)
benchmarks the same hot loop with `std::map`, `std::unordered_map`,
sorted `std::vector`, and `std::flat_map`, on representative key
distributions. The output is a CSV; the demo's
`scripts/test-demo-02-*.sh` validates the ordering of the result.

## For deeper coverage

- Andrist & Sehr, *C++ High Performance*, ch. 4 (containers and
  iterators) and ch. 5 (algorithms with cache-awareness)
- Iglberger, *C++ Software Design*, ch. 4 (the abstraction tax),
  ch. 9 (type erasure trade-offs)

## What's next

§6 keeps the workload but changes the allocator under it.
