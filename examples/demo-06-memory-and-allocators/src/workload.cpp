// Demo-06 — workload implementation.
//
// build_tree and walk_tree are implemented twice (once for std::,
// once for std::pmr::) because the type system can't unify them
// without templates that would obscure the demo's didactic point.
// The logic is identical; only the container types and the alloc
// hookup differ.

#include "workload.hpp"

#include <algorithm>
#include <cstdint>
#include <random>

namespace demo06 {

namespace {

// ── Deterministic PRNG helpers ────────────────────────────────────────
// std::mt19937_64 is overkill for randomness quality but is the
// idiomatic C++ choice for "give me reproducible numbers from a seed."
// We thread the engine through build_tree's recursion so every node
// gets fresh values without re-seeding.

std::uint8_t pick_branch(std::mt19937_64& rng, int max_children, int depth, int max_depth) {
    if (depth >= max_depth) return 0;
    // Bias toward fewer children at deeper levels — produces realistic
    // tapering rather than uniform fan-out at every depth.
    int cap = std::max(0, max_children - (depth / 2));
    std::uniform_int_distribution<int> d(0, cap);
    return static_cast<std::uint8_t>(d(rng));
}

int pick_value_count(std::mt19937_64& rng, int max_values) {
    std::uniform_int_distribution<int> d(0, max_values);
    return d(rng);
}

int pick_label_len(std::mt19937_64& rng, int lo, int hi) {
    std::uniform_int_distribution<int> d(lo, hi);
    return d(rng);
}

void fill_label(std::mt19937_64& rng, std::string& out, int len) {
    // 64 distinct chars; an arbitrary printable set. We don't care
    // what the bytes look like, only that the allocations happen.
    static constexpr char kCharset[] =
        "abcdefghijklmnopqrstuvwxyz"
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "0123456789-_";
    constexpr int kCharsetSize = sizeof(kCharset) - 1;
    out.resize(static_cast<std::size_t>(len));
    std::uniform_int_distribution<int> d(0, kCharsetSize - 1);
    for (int i = 0; i < len; ++i) out[static_cast<std::size_t>(i)] = kCharset[d(rng)];
}

void fill_label_pmr(std::mt19937_64& rng, std::pmr::string& out, int len) {
    static constexpr char kCharset[] =
        "abcdefghijklmnopqrstuvwxyz"
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "0123456789-_";
    constexpr int kCharsetSize = sizeof(kCharset) - 1;
    out.resize(static_cast<std::size_t>(len));
    std::uniform_int_distribution<int> d(0, kCharsetSize - 1);
    for (int i = 0; i < len; ++i) out[static_cast<std::size_t>(i)] = kCharset[d(rng)];
}

// ── std-allocator tree build ──────────────────────────────────────────

void build_node(std::mt19937_64& rng, Node& out,
                const WorkloadParams& p, int depth) {
    int len = pick_label_len(rng, p.label_chars_min, p.label_chars_max);
    fill_label(rng, out.label, len);

    int nvalues = pick_value_count(rng, p.values_max);
    out.values.reserve(static_cast<std::size_t>(nvalues));
    for (int i = 0; i < nvalues; ++i) {
        out.values.push_back(static_cast<int>(rng() & 0xffff));
    }

    int nchildren = pick_branch(rng, p.branch_factor_max, depth, p.max_depth);
    out.children.reserve(static_cast<std::size_t>(nchildren));
    for (int i = 0; i < nchildren; ++i) {
        out.children.emplace_back();
        build_node(rng, out.children.back(), p, depth + 1);
    }
}

// ── PMR tree build ────────────────────────────────────────────────────

void build_node_pmr(std::mt19937_64& rng, PmrNode& out,
                    const WorkloadParams& p, int depth,
                    std::pmr::memory_resource* mr) {
    int len = pick_label_len(rng, p.label_chars_min, p.label_chars_max);
    fill_label_pmr(rng, out.label, len);

    int nvalues = pick_value_count(rng, p.values_max);
    out.values.reserve(static_cast<std::size_t>(nvalues));
    for (int i = 0; i < nvalues; ++i) {
        out.values.push_back(static_cast<int>(rng() & 0xffff));
    }

    int nchildren = pick_branch(rng, p.branch_factor_max, depth, p.max_depth);
    out.children.reserve(static_cast<std::size_t>(nchildren));
    for (int i = 0; i < nchildren; ++i) {
        // Use mr as the upstream for child node's allocators.
        out.children.emplace_back(mr);
        build_node_pmr(rng, out.children.back(), p, depth + 1, mr);
    }
}

// ── Hash helpers (FNV-1a 64-bit) ──────────────────────────────────────
// FNV-1a is overkill for our anti-DCE need but is small, dependency-
// free, well-known, and the produced hash values are identical
// between std and pmr variants — useful as a cross-allocator sanity
// check (allocator-correctness is supposed to be invisible to results).

constexpr std::uint64_t kFnvOffset = 0xcbf29ce484222325ULL;
constexpr std::uint64_t kFnvPrime  = 0x100000001b3ULL;

void hash_bytes(std::uint64_t& h, const char* data, std::size_t n) {
    for (std::size_t i = 0; i < n; ++i) {
        h ^= static_cast<std::uint8_t>(data[i]);
        h *= kFnvPrime;
    }
}

void hash_int(std::uint64_t& h, int v) {
    auto bytes = reinterpret_cast<const char*>(&v);
    hash_bytes(h, bytes, sizeof(int));
}

void walk_node(const Node& n, std::uint64_t& h) {
    hash_bytes(h, n.label.data(), n.label.size());
    for (int v : n.values) hash_int(h, v);
    for (const auto& c : n.children) walk_node(c, h);
}

void walk_node_pmr(const PmrNode& n, std::uint64_t& h) {
    hash_bytes(h, n.label.data(), n.label.size());
    for (int v : n.values) hash_int(h, v);
    for (const auto& c : n.children) walk_node_pmr(c, h);
}

}  // namespace

// ── Public API ────────────────────────────────────────────────────────

Node build_tree(const WorkloadParams& params) {
    std::mt19937_64 rng(params.seed);
    Node root;
    build_node(rng, root, params, 0);
    return root;
}

std::uint64_t walk_tree(const Node& root) {
    std::uint64_t h = kFnvOffset;
    walk_node(root, h);
    return h;
}

PmrNode build_tree_pmr(const WorkloadParams& params,
                       std::pmr::memory_resource* mr) {
    std::mt19937_64 rng(params.seed);
    PmrNode root(mr);
    build_node_pmr(rng, root, params, 0, mr);
    return root;
}

std::uint64_t walk_tree_pmr(const PmrNode& root) {
    std::uint64_t h = kFnvOffset;
    walk_node_pmr(root, h);
    return h;
}

}  // namespace demo06
