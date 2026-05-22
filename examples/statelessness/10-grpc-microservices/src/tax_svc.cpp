// tax_svc.cpp — the tax-calculation upstream (Doc 10).
//
// A small standalone gRPC service the pricing service calls. It exists so
// the capstone's outbound-call story — channel cache, deadline propagation,
// error translation — is demonstrated against a REAL upstream rather than a
// mock. It computes a flat per-country rate; the logic is deliberately
// trivial, the point is the wiring.
//
// Like the pricing service it uses the gRPC standard health service and the
// same signal-safe graceful-shutdown sequence as the 09 example (handlers
// set a flag; a control thread does the work).

#include <grpcpp/grpcpp.h>
#include <grpcpp/health_check_service_interface.h>
#include <grpcpp/ext/health_check_service_server_builder_option.h>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

#include "tax.grpc.pb.h"

namespace tax {
namespace {

constexpr char kServiceName[] = "tax.v1.TaxService";

void log_line(const std::string& msg) {
    static std::mutex m;
    std::lock_guard<std::mutex> lk(m);
    std::cout << "[tax-svc] " << msg << std::endl;
}

volatile std::sig_atomic_t g_sigterm = 0;
void on_signal(int sig) {
    if (sig == SIGTERM || sig == SIGINT) g_sigterm = 1;
}

// Flat per-country rate in basis points (1/100 of a percent). A real
// service would source these from a table; a fixed map keeps the example
// about the wiring, not the tax code.
int rate_bps(const std::string& country) {
    static const std::unordered_map<std::string, int> kRates = {
        {"US", 700}, {"GB", 2000}, {"DE", 1900}, {"FR", 2000}, {"JP", 1000},
    };
    auto it = kRates.find(country);
    return it != kRates.end() ? it->second : 0;
}

class TaxServiceImpl final : public tax::v1::TaxService::Service {
public:
    grpc::Status CalculateTax(grpc::ServerContext*,
                              const tax::v1::CalculateTaxRequest* req,
                              tax::v1::CalculateTaxResponse* resp) override {
        const long long bps = rate_bps(req->country());
        // tax = subtotal * bps / 10000, integer cents.
        const long long tax =
            (static_cast<long long>(req->subtotal_cents()) * bps) / 10000;
        resp->set_tax_cents(tax);
        return grpc::Status::OK;
    }
};

}  // namespace
}  // namespace tax

int main() {
    using namespace tax;
    using grpc::HealthCheckServiceInterface;

    std::signal(SIGTERM, on_signal);
    std::signal(SIGINT, on_signal);

    const char* addr_env = std::getenv("LISTEN_ADDR");
    const std::string addr = addr_env ? addr_env : "0.0.0.0:50052";

    grpc::EnableDefaultHealthCheckService(true);
    TaxServiceImpl svc;
    grpc::ServerBuilder builder;
    builder.AddListeningPort(addr, grpc::InsecureServerCredentials());
    builder.RegisterService(&svc);
    std::unique_ptr<grpc::Server> server = builder.BuildAndStart();
    if (!server) { log_line("failed to start"); return 1; }

    HealthCheckServiceInterface* health = server->GetHealthCheckService();
    health->SetServingStatus("", true);
    health->SetServingStatus(kServiceName, true);
    log_line("tax service listening on " + addr);

    std::jthread control([&] {
        while (true) {
            if (g_sigterm) {
                log_line("SIGTERM: draining");
                health->SetServingStatus(kServiceName, false);
                server->Shutdown(std::chrono::system_clock::now() +
                                 std::chrono::seconds(10));
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    });

    server->Wait();
    log_line("stopped");
    return 0;
}
