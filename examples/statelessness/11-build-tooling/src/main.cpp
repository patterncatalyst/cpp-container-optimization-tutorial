// main.cpp — print what the vendored helpers detect (Doc 11).
//
// Run this under different cgroup caps and watch the readings change:
//
//   podman run --rm IMAGE                       # unconstrained
//   podman run --rm --cpus=1.5 IMAGE            # cpu_limit_cores() -> 1.5
//   podman run --rm --cpus=0.5 --memory=256m IMAGE
//
// That is the whole point of the cgroup helper from Doc 05: a process must
// read its cgroup budget, not hardware_concurrency(), to size its thread
// pools and caches correctly under a container limit. This binary makes the
// reading observable; demo.sh sweeps the caps so you can see it track them.

#include <cstdio>
#include <optional>
#include <string>
#include <thread>

#include "cgroup_helper.h"
#include "psi_reader.h"

namespace {

std::string fmt_cores(std::optional<double> v) {
    if (!v) return "unconstrained";
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.3g cores", *v);
    return buf;
}

std::string fmt_bytes(std::optional<std::size_t> v) {
    if (!v) return "unbounded";
    const double mib = static_cast<double>(*v) / (1024.0 * 1024.0);
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%zu bytes (%.1f MiB)", *v, mib);
    return buf;
}

}  // namespace

int main() {
    using namespace cgroup_helper;

    std::printf("=== vendored-helper readings (this process's view) ===\n");
    std::printf("in_container()        : %s\n",
                in_container() ? "true" : "false");

    const auto cpu = cpu_limit_cores();
    std::printf("cpu_limit_cores()     : %s\n", fmt_cores(cpu).c_str());
    std::printf("hardware_concurrency(): %u  (what a naive pool would use)\n",
                std::thread::hardware_concurrency());
    if (cpu) {
        const auto pool = static_cast<unsigned>(*cpu < 1.0 ? 1.0 : *cpu);
        std::printf("  -> a cgroup-aware pool would size to ~%u thread(s)\n",
                    pool);
    }

    std::printf("memory_limit_bytes()  : %s\n",
                fmt_bytes(memory_limit_bytes()).c_str());

    // PSI is best-effort: it requires CONFIG_PSI=y and the pressure files
    // to be exposed to the container. Absence is normal and not an error.
    if (auto p = psi_reader::read_some("cpu")) {
        std::printf("cpu pressure (some)   : avg10=%.2f avg60=%.2f avg300=%.2f\n",
                    p->avg10, p->avg60, p->avg300);
    } else {
        std::printf("cpu pressure (some)   : unavailable "
                    "(PSI not exposed to this container)\n");
    }

    return 0;
}
