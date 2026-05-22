// health_probe.cpp — a minimal grpc_health_probe, built from health.proto.
//
// Speaks the standard grpc.health.v1.Health protocol: one-shot Check of a
// named service against a gRPC server, exit 0 if SERVING, non-zero
// otherwise. This is what the demo uses to query readiness, and it is the
// same role the upstream `grpc_health_probe` release binary plays in a
// Podman HEALTHCHECK or a pre-1.24 Kubernetes exec probe. We build our own
// rather than download theirs so the image has no build-time network
// dependency (see §14 on build-time surprises) and so the Check RPC is
// visible in the example rather than hidden in a prebuilt binary.
//
//   health-probe <addr> [service-name]
//
//   addr          host:port of the gRPC server (e.g. localhost:50051)
//   service-name  service to check; omit (or "") for the server-wide status
//
// Exit codes mirror the upstream tool's intent:
//   0  SERVING
//   1  NOT_SERVING / SERVICE_UNKNOWN / UNKNOWN
//   2  RPC failed (could not reach the health service at all)

#include <grpcpp/grpcpp.h>

#include <chrono>
#include <iostream>
#include <string>

#include "health.grpc.pb.h"

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "usage: health-probe <addr> [service-name]\n";
        return 2;
    }
    const std::string addr = argv[1];
    const std::string service = (argc >= 3) ? argv[2] : "";

    auto channel =
        grpc::CreateChannel(addr, grpc::InsecureChannelCredentials());
    auto stub = grpc::health::v1::Health::NewStub(channel);

    grpc::health::v1::HealthCheckRequest req;
    req.set_service(service);

    grpc::ClientContext ctx;
    ctx.set_deadline(std::chrono::system_clock::now() +
                     std::chrono::seconds(2));

    grpc::health::v1::HealthCheckResponse resp;
    const grpc::Status status = stub->Check(&ctx, req, &resp);

    const std::string who = service.empty() ? "(server-wide)" : service;
    if (!status.ok()) {
        std::cout << "health-probe " << who << ": RPC FAILED ("
                  << status.error_message() << ")\n";
        return 2;
    }

    using R = grpc::health::v1::HealthCheckResponse;
    switch (resp.status()) {
        case R::SERVING:
            std::cout << "health-probe " << who << ": SERVING\n";
            return 0;
        case R::NOT_SERVING:
            std::cout << "health-probe " << who << ": NOT_SERVING\n";
            return 1;
        case R::SERVICE_UNKNOWN:
            std::cout << "health-probe " << who << ": SERVICE_UNKNOWN\n";
            return 1;
        default:
            std::cout << "health-probe " << who << ": UNKNOWN\n";
            return 1;
    }
}
