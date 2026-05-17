// Demo 7 — a small library with two channel implementations:
//   - VirtualChannel: classic OO with a virtual interface
//   - StaticChannel:  CRTP, no virtual dispatch
//
// The point in §12/§14 is to show that "use polymorphism wherever you'd
// like to swap impls" has a measurable cost on small hot-path objects,
// and that constexpr/CRTP gives you the same flexibility at compile time
// when you don't actually need runtime substitution.

#ifndef DEMO07_CHANNEL_HPP
#define DEMO07_CHANNEL_HPP

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>
#include <vector>

namespace demo07 {

// -- runtime polymorphic version --------------------------------------------
// VirtualChannel is a pure interface — instances are referenced through
// pointer/reference, never copied. We explicitly delete the copy/move
// special members to make slicing impossible at the type level.
// (See cppcoreguidelines-special-member-functions.)
class VirtualChannel {
public:
    VirtualChannel() = default;
    VirtualChannel(const VirtualChannel&) = delete;
    VirtualChannel(VirtualChannel&&) = delete;
    VirtualChannel& operator=(const VirtualChannel&) = delete;
    VirtualChannel& operator=(VirtualChannel&&) = delete;
    virtual ~VirtualChannel() = default;
    virtual std::size_t send(std::span<const std::byte> bytes) = 0;
    virtual std::size_t recv(std::span<std::byte> out) = 0;
};

class MemoryChannel final : public VirtualChannel {
public:
    explicit MemoryChannel(std::size_t capacity);
    std::size_t send(std::span<const std::byte> bytes) override;
    std::size_t recv(std::span<std::byte> out) override;
    [[nodiscard]] std::size_t size() const noexcept { return write_ - read_; }
private:
    std::vector<std::byte> buf_;
    std::size_t read_  = 0;
    std::size_t write_ = 0;
};

// -- CRTP version -----------------------------------------------------------
// Constructor is private and befriends Derived so only the designated
// subclass can construct the base. This prevents accidental substitution
// of the wrong Derived type, which CRTP-with-public-ctor allows by mistake.
// (See bugprone-crtp-constructor-accessibility.)
template <class Derived>
class StaticChannel {
public:
    std::size_t send(std::span<const std::byte> bytes) {
        return static_cast<Derived*>(this)->send_impl(bytes);
    }
    std::size_t recv(std::span<std::byte> out) {
        return static_cast<Derived*>(this)->recv_impl(out);
    }
private:
    StaticChannel() = default;
    friend Derived;
};

class StaticMemoryChannel final : public StaticChannel<StaticMemoryChannel> {
public:
    explicit StaticMemoryChannel(std::size_t capacity);
    std::size_t send_impl(std::span<const std::byte> bytes);
    std::size_t recv_impl(std::span<std::byte> out);
    [[nodiscard]] std::size_t size() const noexcept { return write_ - read_; }
private:
    std::vector<std::byte> buf_;
    std::size_t read_  = 0;
    std::size_t write_ = 0;
};

// -- ABI-stable record (used by the abidiff demo) ---------------------------
// Add a field here, rebuild, run `./demo.sh --abi-only`, and watch
// abidiff complain. That's the point.
//
// std::array<char, N> has the same memory layout as char[N] (it's a struct
// containing the C array), so the position of `version` relative to `text`
// and the total struct size are unchanged. Using std::array satisfies
// cppcoreguidelines-avoid-c-arrays without altering the binary layout.
struct Greeting {
    std::uint32_t version;
    std::array<char, 64> text;
};

std::string_view greet(const Greeting& g);

}  // namespace demo07

#endif  // DEMO07_CHANNEL_HPP
