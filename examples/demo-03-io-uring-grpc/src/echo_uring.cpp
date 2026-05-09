// Demo 3 — io_uring TCP echo server.
//
// A deliberately small server that uses the modern io_uring API with
// IORING_OP_RECV_MULTISHOT so each accepted socket needs only a single
// SQE for an unbounded stream of receives. This keeps the example's
// hot loop short enough to read in one sitting while still showing the
// pattern that matters for high-throughput services.
//
// Build via the Containerfile; expects liburing >= 2.5.

#include <liburing.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <print>
#include <span>
#include <string>
#include <vector>

namespace {

constexpr int kPort        = 8080;
constexpr int kBacklog     = 1024;
constexpr int kRingEntries = 256;
constexpr int kBufGroup    = 1;
constexpr int kNumBufs     = 256;
constexpr int kBufSize     = 4096;

std::atomic<bool> g_stop{false};
void on_sigterm(int) { g_stop = true; }

enum class Op : std::uint16_t { kAccept = 1, kRecv = 2, kSend = 3 };

// We pack op + client fd into the SQE user_data so we can route CQEs
// without a side hashmap.
constexpr std::uint64_t pack(Op op, int fd) {
    return (static_cast<std::uint64_t>(op) << 32) | static_cast<std::uint32_t>(fd);
}
constexpr Op  op_of(std::uint64_t u) { return static_cast<Op>(u >> 32); }
constexpr int fd_of(std::uint64_t u) { return static_cast<int>(u & 0xFFFFFFFFu); }

int make_listener() {
    int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) { std::perror("socket"); std::exit(1); }
    int one = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port = htons(kPort);
    if (::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) < 0) {
        std::perror("bind"); std::exit(1);
    }
    if (::listen(fd, kBacklog) < 0) { std::perror("listen"); std::exit(1); }
    return fd;
}

}  // namespace

int main() {
    std::signal(SIGTERM, on_sigterm);
    std::signal(SIGINT,  on_sigterm);

    int listen_fd = make_listener();

    io_uring ring;
    io_uring_params params{};
    params.flags = IORING_SETUP_CLAMP;
    if (io_uring_queue_init_params(kRingEntries, &ring, &params) < 0) {
        std::perror("io_uring_queue_init_params"); return 1;
    }

    // Provide a buffer group for receives. RECV_MULTISHOT will draw from this.
    std::vector<std::byte> bufs(static_cast<std::size_t>(kNumBufs) * kBufSize);
    io_uring_buf_ring* br = io_uring_setup_buf_ring(&ring, kNumBufs, kBufGroup, 0, nullptr);
    if (!br) { std::perror("setup_buf_ring"); return 1; }
    for (int i = 0; i < kNumBufs; ++i) {
        io_uring_buf_ring_add(br, &bufs[i * kBufSize], kBufSize, i,
                              io_uring_buf_ring_mask(kNumBufs), i);
    }
    io_uring_buf_ring_advance(br, kNumBufs);

    auto submit_accept = [&] {
        io_uring_sqe* sqe = io_uring_get_sqe(&ring);
        io_uring_prep_multishot_accept(sqe, listen_fd, nullptr, nullptr, 0);
        io_uring_sqe_set_data64(sqe, pack(Op::kAccept, listen_fd));
    };

    auto submit_recv = [&](int fd) {
        io_uring_sqe* sqe = io_uring_get_sqe(&ring);
        io_uring_prep_recv_multishot(sqe, fd, nullptr, 0, 0);
        sqe->flags |= IOSQE_BUFFER_SELECT;
        sqe->buf_group = kBufGroup;
        io_uring_sqe_set_data64(sqe, pack(Op::kRecv, fd));
    };

    auto submit_send = [&](int fd, void* p, std::size_t n) {
        io_uring_sqe* sqe = io_uring_get_sqe(&ring);
        io_uring_prep_send(sqe, fd, p, n, MSG_NOSIGNAL);
        io_uring_sqe_set_data64(sqe, pack(Op::kSend, fd));
    };

    submit_accept();
    io_uring_submit(&ring);

    std::print("io_uring echo server listening on :{} (multishot accept+recv)\n", kPort);

    while (!g_stop.load(std::memory_order_relaxed)) {
        io_uring_cqe* cqe = nullptr;
        int r = io_uring_wait_cqe(&ring, &cqe);
        if (r < 0) {
            if (-r == EINTR) continue;
            std::perror("wait_cqe");
            break;
        }
        unsigned head;
        unsigned count = 0;
        io_uring_for_each_cqe(&ring, head, cqe) {
            ++count;
            const auto u = io_uring_cqe_get_data64(cqe);
            const auto op = op_of(u);
            const int   fd = fd_of(u);
            const int   res = cqe->res;
            const auto  flags = cqe->flags;

            switch (op) {
            case Op::kAccept: {
                if (res >= 0) submit_recv(res);
                if ((flags & IORING_CQE_F_MORE) == 0) submit_accept();
                break;
            }
            case Op::kRecv: {
                if (res <= 0) {  // EOF or error
                    ::close(fd);
                    break;
                }
                const int bid = flags >> IORING_CQE_BUFFER_SHIFT;
                void* p = &bufs[bid * kBufSize];
                submit_send(fd, p, static_cast<std::size_t>(res));
                // Recycle the buffer back to the ring.
                io_uring_buf_ring_add(br, p, kBufSize, bid,
                                      io_uring_buf_ring_mask(kNumBufs), 0);
                io_uring_buf_ring_advance(br, 1);
                if ((flags & IORING_CQE_F_MORE) == 0) submit_recv(fd);
                break;
            }
            case Op::kSend:
                if (res < 0) ::close(fd);
                break;
            }
        }
        io_uring_cq_advance(&ring, count);
        io_uring_submit(&ring);
    }

    io_uring_queue_exit(&ring);
    ::close(listen_fd);
    return 0;
}
