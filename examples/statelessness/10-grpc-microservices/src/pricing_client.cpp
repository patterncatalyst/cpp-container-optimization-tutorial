// pricing_client.cpp — a small client to drive the capstone from demo.sh.
//
//   pricing-client <addr> <idempotency_key> <customer_id> <product:qty>...
//
// Calls PriceOrder once and prints the priced result (or the gRPC error).
// Built into the same image so the demo can `podman exec` it — no host gRPC
// tooling (grpcurl etc.) required.

#include <grpcpp/grpcpp.h>

#include <chrono>
#include <iostream>
#include <string>

#include "pricing.grpc.pb.h"

int main(int argc, char** argv) {
    if (argc < 4) {
        std::cerr << "usage: pricing-client <addr> <idempotency_key> "
                     "<customer_id> <product:qty>...\n";
        return 2;
    }
    const std::string addr = argv[1];
    const std::string idem = argv[2];
    const std::string customer = argv[3];

    pricing::v1::PriceOrderRequest req;
    req.set_idempotency_key(idem);
    req.set_customer_id(customer);
    req.set_correlation_id("cli-" + idem);
    for (int i = 4; i < argc; ++i) {
        const std::string arg = argv[i];
        const auto colon = arg.find(':');
        auto* li = req.add_line_items();
        if (colon == std::string::npos) {
            li->set_product_id(arg);
            li->set_quantity(1);
        } else {
            li->set_product_id(arg.substr(0, colon));
            li->set_quantity(std::stoi(arg.substr(colon + 1)));
        }
    }

    auto channel =
        grpc::CreateChannel(addr, grpc::InsecureChannelCredentials());
    auto stub = pricing::v1::Pricing::NewStub(channel);

    grpc::ClientContext ctx;
    ctx.set_deadline(std::chrono::system_clock::now() +
                     std::chrono::seconds(3));

    pricing::v1::PriceOrderResponse resp;
    const grpc::Status s = stub->PriceOrder(&ctx, req, &resp);
    if (!s.ok()) {
        std::cout << "ERROR " << s.error_code() << ": " << s.error_message()
                  << "\n";
        return 1;
    }
    std::cout << "order_id=" << resp.order_id()
              << " subtotal=" << resp.subtotal_cents()
              << " tax=" << resp.tax_cents()
              << " total=" << resp.total_cents() << "\n";
    return 0;
}
