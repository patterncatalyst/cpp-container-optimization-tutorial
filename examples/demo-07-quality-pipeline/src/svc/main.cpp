// Demo 6 — service that exercises the library at runtime.
// Used by the gdbserver sidecar example.

#include "demo06/channel.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <print>
#include <span>
#include <thread>

namespace {
std::atomic<bool> g_stop{false};
void on_sig(int) { g_stop = true; }
}

int main() {
    std::signal(SIGTERM, on_sig);
    std::signal(SIGINT,  on_sig);

    demo06::Greeting g{};
    g.version = 1;
    std::strncpy(g.text, "hello from demo-07", sizeof(g.text) - 1);
    std::print("{}\n", demo06::greet(g));

    demo06::MemoryChannel mc(64 * 1024);
    demo06::StaticMemoryChannel sc(64 * 1024);

    std::array<std::byte, 1024> payload{};
    for (std::size_t i = 0; i < payload.size(); ++i) {
        payload[i] = static_cast<std::byte>(i & 0xFF);
    }

    while (!g_stop.load(std::memory_order_relaxed)) {
        // A perfectly normal pair of calls. Set a breakpoint on `send`
        // from gdb; recv loops back into the same buffers.
        mc.send(payload);
        sc.send(payload);

        std::array<std::byte, 1024> out{};
        mc.recv(out);
        sc.recv(out);

        std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }
    return 0;
}
