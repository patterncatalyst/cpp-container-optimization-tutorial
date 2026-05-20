// request_arena.hpp — the layered request arena (compendium Doc 03).
//
// The canonical recipe from Doc 03: a monotonic_buffer_resource for
// bump-pointer speed, layered on top of an unsynchronized_pool_resource
// that serves the monotonic resource's refills. The monotonic resource
// uses an inline heap buffer first, falling back to the pool (and
// ultimately new_delete) only when that buffer is exhausted.
//
//   request scratch  ──uses──▶  monotonic_buffer_resource (bump pointer)
//                                     │ refills come from
//                                     ▼
//                               unsynchronized_pool_resource (size classes)
//                                     │ upstream
//                                     ▼
//                               new_delete_resource (heap)
//
// Why layered rather than a bare monotonic resource: a pure monotonic
// resource never reuses freed blocks within its lifetime, so a handler
// that churns many short-lived node-based containers (maps, lists) can
// grow its arena without bound. The pool underneath recycles
// size-classed blocks, bounding peak arena memory while keeping the
// monotonic resource's O(1) bump-allocate on the hot path. All of it is
// released together when RequestArena is destroyed — O(1), with no
// per-object destructor walk for trivially-destructible contents.
//
// The arena is unsynchronized: it belongs to exactly one request on one
// thread (request scope). Never share a RequestArena across threads —
// that's why it uses unsynchronized_pool_resource, not the synchronized
// variant (see Doc 05 for the threading rules).

#pragma once

#include <cstddef>
#include <memory_resource>
#include <vector>

namespace statelesspmr {

class RequestArena {
public:
    // inline_bytes: the heap buffer the monotonic resource bump-
    // allocates from first, before refilling from the pool. Sized to
    // the typical request's scratch so the common case is one
    // allocation up front and O(1) bumps thereafter.
    explicit RequestArena(std::size_t inline_bytes = 16 * 1024)
        : inline_buffer_(inline_bytes),
          pool_(std::pmr::new_delete_resource()),
          monotonic_(inline_buffer_.data(), inline_buffer_.size(), &pool_) {}

    // Non-copyable, non-movable: the monotonic resource holds a pointer
    // into inline_buffer_, so moving the arena would dangle it. Request
    // arenas live and die in one scope; there's never a reason to move
    // one. (Contrast with RequestContext in 02-raii, which is movable
    // because it holds no self-referential pointer.)
    RequestArena(const RequestArena&) = delete;
    RequestArena& operator=(const RequestArena&) = delete;
    RequestArena(RequestArena&&) = delete;
    RequestArena& operator=(RequestArena&&) = delete;

    // The resource handlers allocate request scratch from.
    std::pmr::memory_resource* resource() noexcept { return &monotonic_; }

private:
    // Declaration order matters: inline_buffer_ must be constructed
    // before monotonic_, which points into it. Members are initialized
    // in declaration order regardless of the ctor init-list order.
    std::vector<std::byte> inline_buffer_;
    std::pmr::unsynchronized_pool_resource pool_;
    std::pmr::monotonic_buffer_resource monotonic_;
};

}  // namespace statelesspmr
