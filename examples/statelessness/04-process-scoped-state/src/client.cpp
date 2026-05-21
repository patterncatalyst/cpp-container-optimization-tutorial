// client.cpp — drives the StateService.
//
// Usage:
//   state-client <address> lookup <key>
//   state-client <address> stats
//
// Exit code 0 on grpc OK.

#include <iostream>
#include <string>

#include <grpcpp/grpcpp.h>

#include "state.grpc.pb.h"

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "usage: " << argv[0]
                  << " <address> <lookup <key> | stats>\n";
        return 2;
    }
    const std::string address = argv[1];
    const std::string cmd = argv[2];

    auto channel =
        grpc::CreateChannel(address, grpc::InsecureChannelCredentials());
    auto stub = statelessstate::StateService::NewStub(channel);

    if (cmd == "lookup") {
        if (argc < 4) {
            std::cerr << "lookup needs a key\n";
            return 2;
        }
        statelessstate::LookupRequest req;
        req.set_key(argv[3]);
        statelessstate::LookupResponse resp;
        grpc::ClientContext ctx;
        grpc::Status status = stub->Lookup(&ctx, req, &resp);
        if (!status.ok()) {
            std::cout << "lookup grpc_code=" << status.error_code()
                      << " message=\"" << status.error_message() << "\"\n";
            return 1;
        }
        std::cout << "lookup key=" << resp.key()
                  << " value=" << resp.value()
                  << " cache_hit=" << (resp.cache_hit() ? "true" : "false")
                  << " cache_size=" << resp.cache_size()
                  << "/" << resp.cache_capacity() << std::endl;
        return 0;
    }

    if (cmd == "stats") {
        statelessstate::StatsRequest req;
        statelessstate::StatsResponse resp;
        grpc::ClientContext ctx;
        grpc::Status status = stub->Stats(&ctx, req, &resp);
        if (!status.ok()) {
            std::cout << "stats grpc_code=" << status.error_code()
                      << " message=\"" << status.error_message() << "\"\n";
            return 1;
        }
        std::cout << "stats lookups=" << resp.lookups()
                  << " hits=" << resp.hits()
                  << " misses=" << resp.misses()
                  << " evictions=" << resp.evictions()
                  << " cache_size=" << resp.cache_size()
                  << "/" << resp.cache_capacity() << std::endl;
        return 0;
    }

    std::cerr << "unknown command: " << cmd << "\n";
    return 2;
}
