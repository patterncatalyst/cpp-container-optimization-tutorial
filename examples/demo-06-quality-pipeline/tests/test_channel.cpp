// Demo 6 — gtest+gmock for the channel library, including a tiny
// micro-benchmark for the virtual-vs-CRTP comparison.

#include "demo06/channel.hpp"

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <array>
#include <chrono>
#include <cstddef>
#include <print>
#include <vector>

using namespace demo06;
using ::testing::ElementsAreArray;

namespace {

std::vector<std::byte> make_payload(std::size_t n) {
    std::vector<std::byte> p(n);
    for (std::size_t i = 0; i < n; ++i) p[i] = static_cast<std::byte>(i & 0xFF);
    return p;
}

TEST(MemoryChannelTest, SendThenRecvRoundTrips) {
    MemoryChannel mc(1024);
    auto payload = make_payload(256);
    EXPECT_EQ(mc.send(payload), 256u);
    std::vector<std::byte> out(256);
    EXPECT_EQ(mc.recv(out), 256u);
    EXPECT_THAT(out, ElementsAreArray(payload));
}

TEST(StaticMemoryChannelTest, SendThenRecvRoundTrips) {
    StaticMemoryChannel sc(1024);
    auto payload = make_payload(256);
    EXPECT_EQ(sc.send(payload), 256u);
    std::vector<std::byte> out(256);
    EXPECT_EQ(sc.recv(out), 256u);
    EXPECT_THAT(out, ElementsAreArray(payload));
}

TEST(MemoryChannelTest, RespectsCapacity) {
    MemoryChannel mc(128);
    auto payload = make_payload(256);
    EXPECT_EQ(mc.send(payload), 128u);
}

// gmock example: verify a caller correctly drives the VirtualChannel API.
class MockChannel : public VirtualChannel {
public:
    MOCK_METHOD(std::size_t, send, (std::span<const std::byte>), (override));
    MOCK_METHOD(std::size_t, recv, (std::span<std::byte>),       (override));
};

void echo_once(VirtualChannel& chan, std::span<const std::byte> in,
               std::span<std::byte> out) {
    chan.send(in);
    chan.recv(out);
}

TEST(VirtualChannelTest, EchoCallsSendThenRecv) {
    using ::testing::_;
    using ::testing::Return;
    MockChannel m;
    EXPECT_CALL(m, send(_)).WillOnce(Return(256));
    EXPECT_CALL(m, recv(_)).WillOnce(Return(256));
    auto p = make_payload(256);
    std::vector<std::byte> out(256);
    echo_once(m, p, out);
}

// Microbench: virtual dispatch vs CRTP, same workload.
// Not a failing test; just prints numbers to stdout.
TEST(BenchmarkComparison, VirtualVsCrtp) {
    constexpr std::size_t kIters    = 100'000;
    constexpr std::size_t kCapacity = 1u << 20;
    auto payload = make_payload(64);

    auto run_virtual = [&] {
        MemoryChannel mc(kCapacity);
        std::vector<std::byte> out(64);
        auto t0 = std::chrono::steady_clock::now();
        for (std::size_t i = 0; i < kIters; ++i) {
            mc.send(payload);
            mc.recv(out);
        }
        return std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - t0).count();
    };

    auto run_crtp = [&] {
        StaticMemoryChannel sc(kCapacity);
        std::vector<std::byte> out(64);
        auto t0 = std::chrono::steady_clock::now();
        for (std::size_t i = 0; i < kIters; ++i) {
            sc.send(payload);
            sc.recv(out);
        }
        return std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - t0).count();
    };

    auto v_us = run_virtual();
    auto c_us = run_crtp();
    std::print("\n[bench] virtual={}us  crtp={}us  ratio={:.2f}x\n",
               v_us, c_us, static_cast<double>(v_us) / static_cast<double>(c_us));
    SUCCEED();
}

}  // namespace
