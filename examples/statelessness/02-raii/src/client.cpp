// client.cpp — drives the RequestProcessor through all three exit
// paths and prints what it gets back.
//
// Usage:
//   raii-client <address> <mode> [payload]
//   raii-client 127.0.0.1:50051 ok    hello
//   raii-client 127.0.0.1:50051 reject hello
//   raii-client 127.0.0.1:50051 throw  hello
//
// Exit code is 0 if the RPC completed in the way the mode predicts
// (ok → OK, reject → INVALID_ARGUMENT, throw → INTERNAL), so the demo
// and test scripts can assert behaviour without parsing prose.

#include <iostream>
#include <memory>
#include <string>

#include <grpcpp/grpcpp.h>

#include "processor.grpc.pb.h"

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "usage: " << argv[0]
                  << " <address> <mode:ok|reject|throw> [payload]\n";
        return 2;
    }
    const std::string address = argv[1];
    const std::string mode = argv[2];
    const std::string payload = (argc > 3) ? argv[3] : "hello";

    auto channel =
        grpc::CreateChannel(address, grpc::InsecureChannelCredentials());
    auto stub = statelessraii::RequestProcessor::NewStub(channel);

    statelessraii::ProcessRequest req;
    req.set_payload(payload);
    req.set_mode(mode);

    statelessraii::ProcessResponse resp;
    grpc::ClientContext ctx;
    grpc::Status status = stub->Process(&ctx, req, &resp);

    std::cout << "mode=" << mode
              << " grpc_code=" << status.error_code();
    if (status.ok()) {
        std::cout << " request_id=" << resp.request_id()
                  << " result=" << resp.result()
                  << " handler_us=" << resp.handler_duration_micros();
    } else {
        std::cout << " message=\"" << status.error_message() << "\"";
    }
    std::cout << std::endl;

    // Predicted outcome per mode → exit code 0 when it matches.
    grpc::StatusCode expected =
        (mode == "ok")     ? grpc::StatusCode::OK
        : (mode == "reject") ? grpc::StatusCode::INVALID_ARGUMENT
        : (mode == "throw")  ? grpc::StatusCode::INTERNAL
                             : grpc::StatusCode::UNKNOWN;

    return (status.error_code() == expected) ? 0 : 1;
}
