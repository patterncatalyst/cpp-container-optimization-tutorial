// client.cpp — drives the MemoryProcessor.
//
// Usage:
//   pmr-client <address> <mode:arena|bench> [payload-or-iterations]
//   pmr-client 127.0.0.1:50051 arena order-42-pricing-context
//   pmr-client 127.0.0.1:50051 bench 50000
//
// Exit code 0 on grpc OK.

#include <iostream>
#include <string>

#include <grpcpp/grpcpp.h>

#include "processor.grpc.pb.h"

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "usage: " << argv[0]
                  << " <address> <mode:arena|bench> [payload-or-iterations]\n";
        return 2;
    }
    const std::string address = argv[1];
    const std::string mode = argv[2];
    const std::string arg = (argc > 3) ? argv[3] : "";

    auto channel =
        grpc::CreateChannel(address, grpc::InsecureChannelCredentials());
    auto stub = statelesspmr::MemoryProcessor::NewStub(channel);

    statelesspmr::ProcessRequest req;
    req.set_mode(mode);
    if (mode == "bench") {
        req.set_iterations(arg.empty() ? 10000 : std::stoi(arg));
    } else {
        req.set_payload(arg.empty() ? "order-42-pricing-context-token" : arg);
    }

    statelesspmr::ProcessResponse resp;
    grpc::ClientContext ctx;
    grpc::Status status = stub->Process(&ctx, req, &resp);

    if (!status.ok()) {
        std::cout << "mode=" << mode << " grpc_code=" << status.error_code()
                  << " message=\"" << status.error_message() << "\"\n";
        return 1;
    }

    std::cout << "mode=" << mode
              << " request_id=" << resp.request_id()
              << " result=\"" << resp.result() << "\""
              << " handler_us=" << resp.handler_duration_micros();
    if (mode == "bench") {
        std::cout << " arena_us=" << resp.arena_micros()
                  << " perobject_us=" << resp.perobject_micros();
    }
    std::cout << std::endl;
    return 0;
}
