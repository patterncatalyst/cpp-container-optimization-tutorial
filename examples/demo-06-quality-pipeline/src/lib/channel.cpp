#include "demo06/channel.hpp"

#include <algorithm>
#include <cstring>

namespace demo06 {

namespace {
inline std::size_t copy_in(std::vector<std::byte>& buf, std::size_t& w,
                           std::span<const std::byte> bytes) {
    const std::size_t n = std::min(bytes.size(), buf.size() - w);
    std::memcpy(buf.data() + w, bytes.data(), n);
    w += n;
    return n;
}

inline std::size_t copy_out(const std::vector<std::byte>& buf, std::size_t& r,
                            std::size_t w, std::span<std::byte> out) {
    const std::size_t available = w - r;
    const std::size_t n = std::min(out.size(), available);
    std::memcpy(out.data(), buf.data() + r, n);
    r += n;
    return n;
}
}  // namespace

// ---- MemoryChannel (virtual) ----
MemoryChannel::MemoryChannel(std::size_t capacity) : buf_(capacity) {}

std::size_t MemoryChannel::send(std::span<const std::byte> bytes) {
    return copy_in(buf_, write_, bytes);
}
std::size_t MemoryChannel::recv(std::span<std::byte> out) {
    return copy_out(buf_, read_, write_, out);
}

// ---- StaticMemoryChannel (CRTP) ----
StaticMemoryChannel::StaticMemoryChannel(std::size_t capacity) : buf_(capacity) {}

std::size_t StaticMemoryChannel::send_impl(std::span<const std::byte> bytes) {
    return copy_in(buf_, write_, bytes);
}
std::size_t StaticMemoryChannel::recv_impl(std::span<std::byte> out) {
    return copy_out(buf_, read_, write_, out);
}

// ---- ABI sample ----
std::string_view greet(const Greeting& g) {
    return {g.text};
}

}  // namespace demo06
