// Demo 7 — service that exercises the library at runtime.
// Used by the gdbserver sidecar example.

#include "demo07/channel.hpp"

#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <iostream>
#include <print>
#include <span>
#include <thread>

namespace {

// g_stop intentionally has static storage duration: a signal handler
// can only safely touch std::atomic_int / std::atomic<bool> + sig_atomic_t
// objects at namespace scope. There's no clean way to express this
// without a globally accessible flag. clang-tidy's
// cppcoreguidelines-avoid-non-const-global-variables flags the
// pattern; we acknowledge it here.
// NOLINTNEXTLINE(cppcoreguidelines-avoid-non-const-global-variables)
std::atomic<bool> g_stop{false};

void on_sig(int /*signum*/) { g_stop = true; }

}  // namespace

namespace {

constexpr std::size_t kBufferBytes = 64UZ * 1024;  // 64 KiB
constexpr std::size_t kPayloadBytes = 1024;
constexpr auto        kTickDelay    = std::chrono::milliseconds{250};

int run() {
    // Cast signal()'s return to void: we don't care what the previous
    // handler was, and cert-err33-c complains if we silently drop it.
    (void)std::signal(SIGTERM, on_sig);
    (void)std::signal(SIGINT,  on_sig);

    demo07::Greeting g{};
    g.version = 1;
    std::strncpy(g.text.data(), "hello from demo-07", g.text.size() - 1);
    std::print("{}\n", demo07::greet(g));

    demo07::MemoryChannel       mc(kBufferBytes);
    demo07::StaticMemoryChannel sc(kBufferBytes);

    std::array<std::byte, kPayloadBytes> payload{};
    {
        std::size_t i = 0;
        for (auto& b : payload) {
            b = static_cast<std::byte>(i++ & 0xFFU);
        }
    }

    while (!g_stop.load(std::memory_order_relaxed)) {
        // A perfectly normal pair of calls. Set a breakpoint on `send`
        // from gdb; recv loops back into the same buffers.
        mc.send(payload);
        sc.send(payload);

        std::array<std::byte, kPayloadBytes> out{};
        mc.recv(out);
        sc.recv(out);

        std::this_thread::sleep_for(kTickDelay);
    }
    return 0;
}

}  // namespace

int main() {
    try {
        return run();
    } catch (const std::exception& e) {
        std::cerr << "fatal: " << e.what() << '\n';
        return 1;
    } catch (...) {
        std::cerr << "fatal: unknown exception\n";
        return 1;
    }
}
