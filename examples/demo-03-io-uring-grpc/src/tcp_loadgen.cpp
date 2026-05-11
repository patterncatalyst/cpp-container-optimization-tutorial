// Demo-03 — TCP load generator for the io_uring and Asio echo servers.
//
// Opens N concurrent TCP connections to host:port, sends a payload of
// configurable size per connection M times, measures per-round-trip
// latency, and prints summary stats (min, p50, p99, max, throughput).
//
// Args (positional):
//   $1 host           default 127.0.0.1
//   $2 port           default 9000
//   $3 num_conns      default 16
//   $4 reqs_per_conn  default 100
//   $5 payload_bytes  default 64
//
// Output: a single line of JSON to stdout for easy jq parsing in the
// demo.sh / test script, like:
//   {"host":"...","port":9000,"conns":16,"reqs":1600,"min_us":42,
//    "p50_us":78,"p99_us":210,"max_us":1310,"throughput_per_sec":18500}

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

namespace {

struct Args {
    std::string host          = "127.0.0.1";
    int         port          = 9000;
    int         num_conns     = 16;
    int         reqs_per_conn = 100;
    int         payload_bytes = 64;
};

Args parse_args(int argc, char** argv) {
    Args a;
    if (argc >= 2) a.host          = argv[1];
    if (argc >= 3) a.port          = std::atoi(argv[2]);
    if (argc >= 4) a.num_conns     = std::atoi(argv[3]);
    if (argc >= 5) a.reqs_per_conn = std::atoi(argv[4]);
    if (argc >= 6) a.payload_bytes = std::atoi(argv[5]);
    return a;
}

int connect_to(const std::string& host, int port) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(static_cast<uint16_t>(port));
    if (inet_pton(AF_INET, host.c_str(), &a.sin_addr) != 1) {
        ::close(fd); return -1;
    }
    if (::connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) < 0) {
        ::close(fd); return -1;
    }
    return fd;
}

void send_all(int fd, const char* buf, int n) {
    int sent = 0;
    while (sent < n) {
        ssize_t s = ::send(fd, buf + sent, static_cast<std::size_t>(n - sent), 0);
        if (s <= 0) return;
        sent += static_cast<int>(s);
    }
}

void recv_all(int fd, char* buf, int n) {
    int got = 0;
    while (got < n) {
        ssize_t r = ::recv(fd, buf + got, static_cast<std::size_t>(n - got), 0);
        if (r <= 0) return;
        got += static_cast<int>(r);
    }
}

void worker(const Args& a, std::vector<std::int64_t>& out_latencies_us) {
    int fd = connect_to(a.host, a.port);
    if (fd < 0) {
        std::cerr << "loadgen: connect failed to " << a.host << ":" << a.port << "\n";
        return;
    }
    std::vector<char> tx(static_cast<std::size_t>(a.payload_bytes), 'X');
    std::vector<char> rx(static_cast<std::size_t>(a.payload_bytes));
    out_latencies_us.reserve(static_cast<std::size_t>(a.reqs_per_conn));
    for (int i = 0; i < a.reqs_per_conn; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        send_all(fd, tx.data(), a.payload_bytes);
        recv_all(fd, rx.data(), a.payload_bytes);
        auto t1 = std::chrono::steady_clock::now();
        out_latencies_us.push_back(
            std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count());
    }
    ::close(fd);
}

}  // namespace

int main(int argc, char** argv) {
    auto args = parse_args(argc, argv);
    std::cerr << "loadgen: " << args.host << ":" << args.port
              << " conns=" << args.num_conns
              << " reqs/conn=" << args.reqs_per_conn
              << " payload=" << args.payload_bytes << "\n";

    std::vector<std::thread> threads;
    std::vector<std::vector<std::int64_t>> per_worker(static_cast<std::size_t>(args.num_conns));

    auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < args.num_conns; ++i) {
        threads.emplace_back([&, i]() { worker(args, per_worker[static_cast<std::size_t>(i)]); });
    }
    for (auto& t : threads) t.join();
    auto end = std::chrono::steady_clock::now();

    std::vector<std::int64_t> all;
    for (const auto& v : per_worker) all.insert(all.end(), v.begin(), v.end());
    if (all.empty()) {
        std::cerr << "loadgen: no measurements collected\n";
        return 1;
    }
    std::sort(all.begin(), all.end());
    const auto n = all.size();
    auto p = [&](double q) {
        auto idx = std::min(static_cast<std::size_t>(q * static_cast<double>(n)), n - 1);
        return all[idx];
    };
    double total_secs =
        std::chrono::duration<double>(end - start).count();
    double throughput = static_cast<double>(n) / total_secs;

    // Single-line JSON for easy jq parsing downstream.
    std::printf(
        "{\"host\":\"%s\",\"port\":%d,\"conns\":%d,\"reqs\":%zu,"
        "\"min_us\":%ld,\"p50_us\":%ld,\"p99_us\":%ld,\"max_us\":%ld,"
        "\"throughput_per_sec\":%.1f}\n",
        args.host.c_str(), args.port, args.num_conns, n,
        all.front(), p(0.50), p(0.99), all.back(), throughput);
    return 0;
}
