// Demo 3 — async gRPC server with SO_REUSEPORT.
//
// Uses gRPC's completion-queue (CompletionQueue) API rather than the
// callback API, because the CQ flavor makes the lifecycle of each call
// explicit and easier to read in a tutorial setting. Each worker thread
// pins one CQ. SO_REUSEPORT is enabled by binding to the address with
// EnableLocalIpv4 and the appropriate channel argument before Build().
//
// Build via the Containerfile; expects gRPC >= 1.60 (we use the post-
// CallbackServer, post-async-v3 stable surface).

#include <grpcpp/grpcpp.h>
#include <grpcpp/server_builder.h>
#include <grpcpp/security/server_credentials.h>

#include "echo.grpc.pb.h"

#include <atomic>
#include <csignal>
#include <memory>
#include <print>
#include <string>
#include <thread>
#include <vector>

namespace {

std::atomic<bool> g_stop{false};
void on_sigterm(int) { g_stop = true; }

// One in-flight call. Owns its own ServerContext and writer; re-arms
// itself via Proceed(). Standard gRPC async pattern.
class EchoCall {
public:
    EchoCall(echo::EchoService::AsyncService* svc,
             grpc::ServerCompletionQueue* cq)
        : svc_(svc), cq_(cq), responder_(&ctx_), state_(State::kCreate) {
        Proceed();
    }

    void Proceed() {
        if (state_ == State::kCreate) {
            state_ = State::kProcess;
            svc_->RequestEcho(&ctx_, &req_, &responder_, cq_, cq_, this);
        } else if (state_ == State::kProcess) {
            // Re-arm so the next call can be accepted while we handle this one.
            new EchoCall(svc_, cq_);
            echo::EchoReply rep;
            rep.set_message(req_.message());
            state_ = State::kFinish;
            responder_.Finish(rep, grpc::Status::OK, this);
        } else {
            delete this;
        }
    }

private:
    enum class State { kCreate, kProcess, kFinish };
    echo::EchoService::AsyncService*         svc_;
    grpc::ServerCompletionQueue*             cq_;
    grpc::ServerContext                      ctx_;
    echo::EchoRequest                        req_;
    grpc::ServerAsyncResponseWriter<echo::EchoReply> responder_;
    State                                    state_;
};

void worker_loop(grpc::ServerCompletionQueue* cq) {
    void* tag = nullptr;
    bool  ok  = false;
    while (cq->Next(&tag, &ok)) {
        if (!ok) {
            delete static_cast<EchoCall*>(tag);
            continue;
        }
        static_cast<EchoCall*>(tag)->Proceed();
        if (g_stop.load(std::memory_order_relaxed)) break;
    }
}

}  // namespace

int main(int argc, char** argv) {
    std::signal(SIGTERM, on_sigterm);
    std::signal(SIGINT,  on_sigterm);

    const std::string addr = "0.0.0.0:50051";
    const int n_workers = (argc > 1) ? std::atoi(argv[1])
                                     : static_cast<int>(std::thread::hardware_concurrency());

    echo::EchoService::AsyncService svc;
    grpc::ServerBuilder builder;
    // SO_REUSEPORT: setting this channel arg makes gRPC bind with the
    // option set, which lets us run multiple worker processes against
    // the same port and have the kernel hash incoming SYNs across them.
    builder.AddChannelArgument("grpc.so_reuseport", 1);
    builder.AddListeningPort(addr, grpc::InsecureServerCredentials());
    builder.RegisterService(&svc);

    std::vector<std::unique_ptr<grpc::ServerCompletionQueue>> cqs;
    for (int i = 0; i < n_workers; ++i) cqs.emplace_back(builder.AddCompletionQueue());

    auto server = builder.BuildAndStart();
    std::print("async gRPC echo on {} with {} CQ workers\n", addr, n_workers);

    // Prime each CQ with one in-flight call.
    for (auto& cq : cqs) new EchoCall(&svc, cq.get());

    std::vector<std::jthread> threads;
    threads.reserve(cqs.size());
    for (auto& cq : cqs) threads.emplace_back(worker_loop, cq.get());

    while (!g_stop.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    server->Shutdown();
    for (auto& cq : cqs) cq->Shutdown();
    return 0;
}
