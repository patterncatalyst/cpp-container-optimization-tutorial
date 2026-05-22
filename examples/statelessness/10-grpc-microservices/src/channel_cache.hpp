// channel_cache.hpp — process-scoped gRPC channel cache (Doc 04, Doc 10).
//
// gRPC channels are expensive to create (DNS, connection, HTTP/2, TLS) and
// cheap to reuse; stubs built off a channel are cheap. So channels are
// PROCESS-scoped state — constructed once, shared across all request
// threads — exactly the ownership story of Doc 04. This cache hands out a
// shared channel per target, creating it on first use under a mutex. For a
// service with a small fixed set of upstreams known at startup (here, just
// the tax service), the map is tiny and reads are effectively uncontended.

#pragma once

#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>

#include <grpcpp/grpcpp.h>

namespace pricing {

class ChannelCache {
public:
    explicit ChannelCache(grpc::ChannelArguments args = {})
        : args_(std::move(args)) {}

    ChannelCache(const ChannelCache&) = delete;
    ChannelCache& operator=(const ChannelCache&) = delete;

    // Returns a process-scoped channel for the target, creating and caching
    // it on first use. Reused across RPCs thereafter.
    std::shared_ptr<grpc::Channel> get_channel(std::string_view target) {
        std::lock_guard<std::mutex> lk(mtx_);
        auto key = std::string(target);
        auto it = channels_.find(key);
        if (it != channels_.end()) return it->second;
        auto ch = grpc::CreateCustomChannel(
            key, grpc::InsecureChannelCredentials(), args_);
        channels_.emplace(key, ch);
        return ch;
    }

private:
    grpc::ChannelArguments args_;
    std::mutex mtx_;
    std::unordered_map<std::string, std::shared_ptr<grpc::Channel>> channels_;
};

}  // namespace pricing
