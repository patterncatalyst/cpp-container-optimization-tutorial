// request_context.hpp — the per-request RAII bundle (Doc 02, Doc 03, Doc 10).
//
// One of these is constructed at the top of each handler and destroyed when
// the handler returns. It bundles the request-scoped state:
//
//   - a PMR arena (Doc 03): a fixed on-stack buffer fronted by a monotonic
//     resource and a pool resource. Per-request pmr::vector / pmr::string
//     allocate from here; their individual destructors are essentially
//     free (monotonic do_deallocate is a no-op), and the whole arena is
//     reclaimed at once when the RequestContext destructs. This is the
//     verified pattern from the 03-pmr example.
//   - the request DEADLINE, read from the gRPC server context, so every
//     downstream call (PG statement_timeout, outbound gRPC) can budget
//     against the same clock (Doc 07, Doc 10).
//   - the correlation id, propagated to downstream calls and logs.
//
// OTEL SEAM (diverges from Doc 10): the doc's RequestContext also owns an
// OpenTelemetry span and a Scope (the TLS active-span guard). This example
// carries no opentelemetry-cpp dependency — every example in this tutorial
// deliberately stays on the verified gRPC trio — so the span/scope members
// are represented here as a documented seam, not built. Where the doc would
// start a span in the constructor and let the Scope restore the prior span
// on destruction, this type exposes correlation_id()/deadline() and leaves
// a clear insertion point. The RAII shape (construct-on-entry, release-on-
// exit, members destroyed in reverse declaration order) is identical, which
// is the teaching point; wiring a real TracerProvider is a mechanical add.

#pragma once

#include <array>
#include <chrono>
#include <cstddef>
#include <memory_resource>
#include <string>

#include <grpcpp/grpcpp.h>

namespace pricing {

class RequestContext {
public:
    RequestContext(grpc::ServerContext& grpc_ctx, std::string correlation_id)
        : grpc_ctx_(grpc_ctx),
          correlation_id_(std::move(correlation_id)),
          deadline_(grpc_ctx.deadline()),
          monotonic_(arena_buffer_.data(), arena_buffer_.size()),
          pool_(pool_options(), &monotonic_) {}
        // OTEL SEAM: a real impl would, after these members, construct
        //   span_  = tracer().StartSpan("PriceOrder", {{"correlation_id", ...}})
        //   scope_ = tracer().WithActiveSpan(span_)
        // and they would destruct first (reverse order), ending the span.

    RequestContext(const RequestContext&) = delete;
    RequestContext& operator=(const RequestContext&) = delete;
    RequestContext(RequestContext&&) = delete;
    RequestContext& operator=(RequestContext&&) = delete;
    ~RequestContext() = default;

    std::pmr::memory_resource* arena() noexcept { return &pool_; }

    std::chrono::system_clock::time_point deadline() const noexcept {
        return deadline_;
    }
    const std::string& correlation_id() const noexcept {
        return correlation_id_;
    }
    bool cancelled() const noexcept { return grpc_ctx_.IsCancelled(); }

private:
    static std::pmr::pool_options pool_options() noexcept {
        std::pmr::pool_options o;
        o.max_blocks_per_chunk = 0;
        o.largest_required_pool_block = 512;
        return o;
    }

    grpc::ServerContext&                   grpc_ctx_;
    std::string                            correlation_id_;
    std::chrono::system_clock::time_point  deadline_;
    std::array<std::byte, 64 * 1024>       arena_buffer_;
    std::pmr::monotonic_buffer_resource    monotonic_;
    std::pmr::unsynchronized_pool_resource pool_;
};

}  // namespace pricing
