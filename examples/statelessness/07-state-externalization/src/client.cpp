// client.cpp — drives the OrderService.
//
// Usage:
//   order-client <address> create <customer> <item> <idempotency_key>
//   order-client <address> get <order_id>
//
// The demo calls create twice with the same key (showing the idempotent
// replay returns the same order_id) and once with a new key (a fresh
// order), then reads one back.

#include <chrono>
#include <iostream>
#include <string>

#include <grpcpp/grpcpp.h>

#include "order.grpc.pb.h"

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "usage: " << argv[0]
                  << " <address> <create <customer> <item> <key> | get <order_id>>\n";
        return 2;
    }
    const std::string address = argv[1];
    const std::string cmd = argv[2];

    auto channel =
        grpc::CreateChannel(address, grpc::InsecureChannelCredentials());
    auto stub = statelessextern::OrderService::NewStub(channel);

    if (cmd == "create") {
        if (argc < 6) {
            std::cerr << "create needs <customer> <item> <key>\n";
            return 2;
        }
        statelessextern::CreateOrderRequest req;
        req.set_customer_id(argv[3]);
        req.set_item(argv[4]);
        req.set_idempotency_key(argv[5]);
        statelessextern::OrderResponse resp;
        grpc::ClientContext ctx;
        ctx.set_deadline(std::chrono::system_clock::now() +
                         std::chrono::seconds(5));
        grpc::Status status = stub->CreateOrder(&ctx, req, &resp);
        if (!status.ok()) {
            std::cout << "create grpc_code=" << status.error_code()
                      << " message=\"" << status.error_message() << "\"\n";
            return 1;
        }
        std::cout << "create order_id=" << resp.order_id()
                  << " customer=" << resp.customer_id()
                  << " item=" << resp.item()
                  << " idempotent_replay="
                  << (resp.idempotent_replay() ? "true" : "false") << std::endl;
        return 0;
    }

    if (cmd == "get") {
        if (argc < 4) {
            std::cerr << "get needs <order_id>\n";
            return 2;
        }
        statelessextern::GetOrderRequest req;
        req.set_order_id(std::stoll(argv[3]));
        statelessextern::OrderResponse resp;
        grpc::ClientContext ctx;
        ctx.set_deadline(std::chrono::system_clock::now() +
                         std::chrono::seconds(5));
        grpc::Status status = stub->GetOrder(&ctx, req, &resp);
        if (!status.ok()) {
            std::cout << "get grpc_code=" << status.error_code()
                      << " message=\"" << status.error_message() << "\"\n";
            return 1;
        }
        std::cout << "get order_id=" << resp.order_id()
                  << " customer=" << resp.customer_id()
                  << " item=" << resp.item() << std::endl;
        return 0;
    }

    std::cerr << "unknown command: " << cmd << "\n";
    return 2;
}
