// cgroup_cpu.hpp — detect the container's real CPU budget (Doc 05).
//
// std::thread::hardware_concurrency() returns the HOST's CPU count, not
// the container's cgroup quota. Sizing a thread pool (or an allocator's
// arena count, or gRPC's internal pool) from that number on a quota-
// limited container oversubscribes the CPU: more threads competing for
// the same slice of CFS quota, more context switches, and throttling
// pauses spread across more threads — worse tail latency, no more
// throughput.
//
// This helper reads the truth from the cgroup and recommends a pool
// size from it. It handles cgroup v2 (the modern path,
// /sys/fs/cgroup/cpu.max) and falls back to cgroup v1
// (cpu.cfs_quota_us / cpu.cfs_period_us). When no quota is set it
// reports "unlimited" and the recommendation falls back to
// hardware_concurrency().
//
// A production version would also consult sched_getaffinity() (CPU
// pinning narrows the effective set independently of the quota) and
// inspect /proc/1/cgroup to confirm we're actually containerized; Doc 11
// covers vendoring the full helper. This is the teaching core.

#pragma once

#include <algorithm>
#include <cmath>
#include <fstream>
#include <string>
#include <thread>

namespace statelessthreading {

struct CpuBudget {
    unsigned hardware = 0;       // hardware_concurrency() — the host's count
    double cgroup_cores = 0.0;   // effective cores from the cgroup quota
    bool limited = false;        // true if a cgroup CPU quota was found
    int cgroup_version = 0;      // 2, 1, or 0 (none found)

    // The pool size to actually use: the quota when limited, else the
    // host count. Never less than 1 (a sub-core quota still needs a
    // thread to run on).
    unsigned recommended_pool() const {
        if (limited) {
            return static_cast<unsigned>(
                std::max(1L, std::lround(cgroup_cores)));
        }
        return std::max(1u, hardware);
    }
};

inline CpuBudget detect_cpu_budget() {
    CpuBudget b;
    b.hardware = std::thread::hardware_concurrency();

    // ── cgroup v2: /sys/fs/cgroup/cpu.max ──
    // Format: "<quota_us> <period_us>", or "max <period_us>" when
    // unlimited. Effective cores = quota / period.
    {
        std::ifstream f("/sys/fs/cgroup/cpu.max");
        if (f) {
            std::string quota, period;
            if (f >> quota >> period) {
                b.cgroup_version = 2;
                if (quota != "max") {
                    const double q = std::stod(quota);
                    const double p = std::stod(period);
                    if (p > 0.0 && q > 0.0) {
                        b.cgroup_cores = q / p;
                        b.limited = true;
                    }
                }
                return b;  // cgroup v2 present (limited or not) — done
            }
        }
    }

    // ── cgroup v1 fallback ──
    {
        std::ifstream q("/sys/fs/cgroup/cpu/cpu.cfs_quota_us");
        std::ifstream p("/sys/fs/cgroup/cpu/cpu.cfs_period_us");
        long quota = -1, period = -1;
        if (q && p && (q >> quota) && (p >> period)) {
            b.cgroup_version = 1;
            if (quota > 0 && period > 0) {
                b.cgroup_cores = static_cast<double>(quota) /
                                 static_cast<double>(period);
                b.limited = true;
            }
        }
    }
    return b;
}

}  // namespace statelessthreading
