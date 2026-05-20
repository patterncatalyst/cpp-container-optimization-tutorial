// pmr_trap.cpp — the lifetime trap from compendium Doc 03, isolated in
// a standalone binary built with AddressSanitizer.
//
// This program contains a DELIBERATE bug. It is not part of the
// service; it exists to make the trap's failure mode visible and
// catchable. The mental rule it violates:
//
//   Anything stored in process-scoped state must own its memory or
//   have a documented lifetime at least as long as that state. An
//   arena-allocated string is owned by the arena; storing a view into
//   it past the arena's death is a bug.
//
// Run under ASan, this aborts with a heap-use-after-free at the
// dangling read. Without ASan the bug is silent until the freed memory
// is reused, at which point cache reads go inconsistent under load —
// exactly the kind of "random" production bug that's miserable to
// chase. Seeing ASan catch it deterministically is the lesson.
//
// The fix is in compendium Doc 07 (state externalization): the cache
// must own its entries (copy into a std::string, or intern into a
// process-scoped arena), never borrow from a request arena.

#include <iostream>
#include <memory_resource>
#include <string>
#include <string_view>
#include <vector>

namespace {

// A process-scoped "cache" that WRONGLY stores views borrowed from
// per-request arenas. This is the bug: the cache outlives the arenas
// whose memory it points into.
std::vector<std::string_view> g_cache;

void handle_request(int n) {
    // Per-request arena, heap-backed via new_delete upstream.
    std::pmr::monotonic_buffer_resource arena{std::pmr::new_delete_resource()};

    // Build a request-scoped string in the arena.
    std::pmr::string scratch(&arena);
    scratch = "pricing-context-for-order-" + std::to_string(n);

    // THE BUG: stash a view into arena memory in process-scoped state.
    // The view will dangle the moment this arena is destroyed at the
    // end of the function.
    g_cache.emplace_back(scratch.data(), scratch.size());

    std::cout << "[handler " << n << "] cached view (valid here): "
              << g_cache.back() << "\n";
}  // arena destroyed → its heap blocks return to new_delete_resource

}  // namespace

int main() {
    std::cout << "pmr-trap: demonstrating the arena-view lifetime trap.\n"
              << "Each handler stashes a std::string_view into its request\n"
              << "arena's memory in a process-scoped cache, then returns —\n"
              << "destroying the arena. The cached views now dangle.\n\n";

    for (int i = 1; i <= 3; ++i) {
        handle_request(i);
    }

    std::cout << "\nNow reading the cache after the arenas are gone.\n"
              << "Under AddressSanitizer this aborts with heap-use-after-free:\n";

    // Use-after-free: every entry points into an arena that's been
    // destroyed. ASan reports the first dangling read.
    for (std::size_t i = 0; i < g_cache.size(); ++i) {
        std::cout << "  cache[" << i << "] = " << g_cache[i] << "\n";
    }

    std::cout << "\n(If you reached this line, ASan was not enabled — the\n"
              << "bug was silent. That is exactly why it is dangerous.)\n";
    return 0;
}
