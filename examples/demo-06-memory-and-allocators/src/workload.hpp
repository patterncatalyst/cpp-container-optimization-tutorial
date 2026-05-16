// Demo-06 — synthetic JSON-shaped allocator stress workload.
//
// The "request" workload builds and walks a tree that mimics the
// allocation pattern of parsing a JSON document into typed nodes:
//
//   - Many small string allocations (16-32 bytes for "labels")
//   - Many small vector allocations (0-3 children per node,
//     0-8 ints per node "values" array)
//   - Mixed depths — recursion produces deep tails alongside flat
//     siblings
//   - Strictly per-request lifetime: everything dies at scope exit
//
// This is the allocation pattern that the C++ ecosystem has wrestled
// with for decades — small, frequent, request-scoped allocations are
// where PMR's bump-pointer arena, mimalloc's segment heaps, and
// jemalloc's per-arena strategy diverge meaningfully from
// std::allocator's glibc-malloc baseline.
//
// We DO NOT use a real JSON library (rapidjson, simdjson, etc.)
// because that introduces non-allocator variables. The workload is
// deliberately synthetic and reproducible: same seed → same tree
// shape across all allocator variants.

#pragma once

#include <cstdint>
#include <string>
#include <vector>
#include <memory_resource>

namespace demo06 {

// Workload parameters. Defaults are calibrated for a per-request
// allocation count in the low thousands, which is realistic for
// JSON parsing of small-to-medium documents.
struct WorkloadParams {
    int max_depth         = 6;     // recursion ceiling
    int branch_factor_max = 4;     // 0..N children at each non-leaf
    int values_max        = 8;     // 0..N ints in each node's values[]
    int label_chars_min   = 12;    // string length range
    int label_chars_max   = 28;
    std::uint64_t seed    = 0xC0FFEE'BA5E'F00DULL;
};

// ── Variants 1 & 3: std::allocator-based node ────────────────────────
// Used by demo06-svc-std (default glibc malloc) and demo06-svc-mimalloc
// (mimalloc replaces global new/delete via static-link). The source
// code is identical across these two variants; the allocator
// difference is purely linkage-driven.

struct Node {
    std::string         label;
    std::vector<int>    values;
    std::vector<Node>   children;
};

// Build a random tree using the params + a deterministic PRNG seeded
// from params.seed. Same params → same tree shape, byte-for-byte.
Node build_tree(const WorkloadParams& params);

// Walk the tree, accumulate a hash from all labels + values. The
// hash is anti-DCE: prevents the optimizer from realizing the tree
// is unobserved and eliding the workload. Returns 64-bit hash.
std::uint64_t walk_tree(const Node& root);

// ── Variant 2: PMR-based node ────────────────────────────────────────
// Used by demo06-svc-pmr only. Same tree shape, same hash, but every
// allocation routes through a polymorphic_allocator that the caller
// supplies. The caller picks the upstream memory_resource — typically
// a monotonic_buffer_resource backed by a stack buffer, which
// converts per-request frees into a single arena-reset at scope exit.

struct PmrNode {
    using allocator_type = std::pmr::polymorphic_allocator<std::byte>;

    std::pmr::string                   label;
    std::pmr::vector<int>              values;
    std::pmr::vector<PmrNode>          children;

    // ── The three allocator-extended constructors PMR requires ─────────
    //
    // For a type to be properly allocator-aware (so std::pmr containers
    // can copy/move it during resize while propagating the right
    // allocator), it needs all three of:
    //
    //   1. `PmrNode(allocator_type)`            — default-construct with allocator
    //   2. `PmrNode(const PmrNode&, allocator_type)` — copy with allocator
    //   3. `PmrNode(PmrNode&&,      allocator_type)` — move with allocator
    //
    // `uses_allocator_construction_args` (the machinery std::pmr
    // containers use internally) calls whichever one matches the
    // emplace/insert/reserve operation in flight. Without #2 and #3,
    // `reserve()` after `emplace_back()` fails to compile because the
    // vector can't reallocate its buffer (it can't move the existing
    // elements into the new storage with the right allocator).

    explicit PmrNode(allocator_type alloc)
        : label(alloc), values(alloc), children(alloc) {}

    PmrNode(const PmrNode& other, allocator_type alloc)
        : label(other.label, alloc),
          values(other.values, alloc),
          children(other.children, alloc) {}

    PmrNode(PmrNode&& other, allocator_type alloc) noexcept
        : label(std::move(other.label), alloc),
          values(std::move(other.values), alloc),
          children(std::move(other.children), alloc) {}
};

PmrNode build_tree_pmr(const WorkloadParams&  params,
                       std::pmr::memory_resource* mr);

std::uint64_t walk_tree_pmr(const PmrNode& root);

// ── Stats reported per-variant by main() ─────────────────────────────
struct RunStats {
    double         total_seconds;
    std::uint64_t  iterations;
    double         min_us;       // per-iter min
    double         p50_us;
    double         p99_us;
    double         max_us;
    std::uint64_t  result_hash;  // sanity check — must match across allocators
};

}  // namespace demo06
