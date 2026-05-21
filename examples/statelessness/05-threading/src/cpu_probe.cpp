// cpu_probe.cpp — show what hardware_concurrency() reports versus what
// the cgroup quota actually allows, and the pool size you should use.
//
// Run it on the host and again inside a `--cpus=2` container to see the
// gap: the host probe is unchanged, but the cgroup quota — and the
// recommended pool size — drops to the container's budget.

#include <cstdio>

#include "cgroup_cpu.hpp"

int main() {
    const auto b = statelessthreading::detect_cpu_budget();

    std::printf("CPU budget detection\n");
    std::printf("--------------------\n");
    std::printf("  std::thread::hardware_concurrency() : %u  (the HOST's cores)\n",
                b.hardware);

    if (b.cgroup_version == 0) {
        std::printf("  cgroup cpu quota                    : none found\n");
    } else {
        std::printf("  cgroup version                      : v%d\n",
                    b.cgroup_version);
        if (b.limited) {
            std::printf("  cgroup cpu quota                    : %.2f cores"
                        "  (the TRUTH under this container)\n",
                        b.cgroup_cores);
        } else {
            std::printf("  cgroup cpu quota                    : max (unlimited)\n");
        }
    }

    std::printf("  recommended thread-pool size        : %u\n",
                b.recommended_pool());
    std::printf("\n");

    if (b.limited &&
        b.hardware > 2 * b.recommended_pool()) {
        std::printf("WARNING: hardware_concurrency() (%u) is far above the\n",
                    b.hardware);
        std::printf("         cgroup budget (%u). Sizing any pool — yours,\n",
                    b.recommended_pool());
        std::printf("         gRPC's, the allocator's arenas — from the host\n");
        std::printf("         probe would oversubscribe the CPU and amplify\n");
        std::printf("         CFS throttling. Size from the cgroup instead.\n");
    } else if (!b.limited) {
        std::printf("No cgroup CPU quota in effect: hardware_concurrency()\n");
        std::printf("is a fair estimate here. Inside a `--cpus=N` container\n");
        std::printf("it would not be — re-run there to see the gap.\n");
    } else {
        std::printf("hardware_concurrency() and the cgroup budget agree\n");
        std::printf("closely here; no oversubscription risk from the probe.\n");
    }
    return 0;
}
