// Demo 6 — a small library with two channel implementations:
//   - VirtualChannel: classic OO with a virtual interface
//   - StaticChannel:  CRTP, no virtual dispatch
//
// The point in §11/§13 is to show that "use polymorphism wherever you'd
// like to swap impls" has a measurable cost on small hot-path objects,
// and that constexpr/CRTP gives you the same flexibility at compile time
// when you don't actually need runtime substitution.

#ifndef DEMO06_CHANNEL_HPP
#define DEMO06_CHANNEL_HPP

#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>
#include <vector>

namespace demo06 {

// -- runtime polymorphic version --------------------------------------------
class VirtualChannel {
public:
    virtual ~VirtualChannel() = default;
    virtual std::size_t send(std::span<const std::byte> bytes) = 0;
    virtual std::size_t recv(std::span<std::byte> out) = 0;
};

class MemoryChannel final : public VirtualChannel {
public:
    explicit MemoryChannel(std::size_t capacity);
    std::size_t send(std::span<const std::byte> bytes) override;
    std::size_t recv(std::span<std::byte> out) override;
    std::size_t size() const noexcept { return write_ - read_; }
private:
    std::vector<std::byte> buf_;
    std::size_t read_  = 0;
    std::size_t write_ = 0;
};

// -- CRTP version -----------------------------------------------------------
template <class Derived>
class StaticChannel {
public:
    std::size_t send(std::span<const std::byte> bytes) {
        return static_cast<Derived*>(this)->send_impl(bytes);
    }
    std::size_t recv(std::span<std::byte> out) {
        return static_cast<Derived*>(this)->recv_impl(out);
    }
};

class StaticMemoryChannel final : public StaticChannel<StaticMemoryChannel> {
public:
    explicit StaticMemoryChannel(std::size_t capacity);
    std::size_t send_impl(std::span<const std::byte> bytes);
    std::size_t recv_impl(std::span<std::byte> out);
    std::size_t size() const noexcept { return write_ - read_; }
private:
    std::vector<std::byte> buf_;
    std::size_t read_  = 0;
    std::size_t write_ = 0;
};

// -- ABI-stable record (used by the abidiff demo) ---------------------------
// Add a field here, rebuild, run `./demo.sh --abi-only`, and watch
// abidiff complain. That's the point.
struct Greeting {
    std::uint32_t version;
    char text[64];
};

std::string_view greet(const Greeting& g);

}  // namespace demo06

#endif  // DEMO06_CHANNEL_HPP
