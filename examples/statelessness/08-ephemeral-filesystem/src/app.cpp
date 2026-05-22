// app.cpp — the ephemeral-filesystem demo (statelessness/08).
//
// The runnable companion to Doc 08. A container's filesystem is
// ephemeral and, done right, read-only. This binary has four modes the
// demo runs under different `podman run` flags to show what that means
// for a C++ service:
//
//   log-stdout         configure spdlog -> stdout (the correct pattern).
//                      Writes nothing to disk, so it runs fine under a
//                      read-only rootfs.
//   log-file <path>    the trap: spdlog's basic_logger_mt opens the file
//                      in its constructor. Under a read-only rootfs the
//                      write fails with EROFS (spdlog throws). Under a
//                      writable rootfs it "works" — but the file lives in
//                      the container's ephemeral layer and is gone on the
//                      next restart.
//   check-file <path>  report whether <path> exists. Run in a fresh
//                      container after log-file, it shows the write from
//                      the previous container did not survive.
//   scratch <dir>      write scratch into <dir>. Under a read-only rootfs
//                      this needs an explicitly-mounted tmpfs; otherwise
//                      it fails with EROFS.

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>

#include <spdlog/spdlog.h>
#include <spdlog/sinks/basic_file_sink.h>
#include <spdlog/sinks/stdout_color_sinks.h>

namespace {

// Mirrors Doc 08's configure_logging: a stdout sink, a structured
// pattern, the level from config. No file path, no rotation, no log
// directory — the orchestrator captures stdout and ships it to Loki.
void configure_stdout_logging() {
    auto sink = std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
    auto logger = std::make_shared<spdlog::logger>("app", sink);
    logger->set_pattern(
        R"({"ts":"%Y-%m-%dT%H:%M:%S.%e%z","level":"%l","logger":"%n","msg":"%v"})");
    logger->set_level(spdlog::level::info);
    logger->flush_on(spdlog::level::info);
    spdlog::set_default_logger(logger);
}

int mode_log_stdout() {
    configure_stdout_logging();
    spdlog::info("service starting — logging to stdout; the orchestrator captures this stream");
    spdlog::info("handled request method=GetOrder order_id={}", 42);
    spdlog::warn("downstream slow component=postgres latency_ms={}", 213);
    spdlog::info("service ready");
    spdlog::default_logger()->flush();
    return 0;
}

int mode_log_file(const std::string& path) {
    try {
        auto logger = spdlog::basic_logger_mt("file", path);  // opens in ctor
        logger->info("log line written to {}", path);
        logger->flush();
        std::fprintf(stderr,
            "wrote log file at %s\n"
            "NOTE: on a writable rootfs this 'works', but the file is in the\n"
            "container's ephemeral layer — it is gone on the next restart.\n",
            path.c_str());
        return 0;
    } catch (const spdlog::spdlog_ex& e) {
        std::fprintf(stderr, "spdlog file sink failed: %s\n", e.what());
        std::fprintf(stderr,
            "This is the read-only-rootfs trap: basic_logger_mt opens the file\n"
            "in its constructor and the write fails with EROFS. Configure a\n"
            "stdout sink instead (see 'app log-stdout').\n");
        return 1;
    }
}

int mode_check_file(const std::string& path) {
    std::error_code ec;
    const bool exists = std::filesystem::exists(path, ec);
    if (exists && !ec) {
        std::printf("present: %s exists in this container\n", path.c_str());
        return 0;
    }
    std::printf(
        "absent: %s does not exist — a previous container's write did not "
        "survive (this is a fresh ephemeral layer)\n",
        path.c_str());
    return 2;
}

int mode_scratch(const std::string& dir) {
    const std::filesystem::path file = std::filesystem::path(dir) / "scratch.txt";
    errno = 0;
    std::ofstream out(file);
    if (!out) {
        const int e = errno;
        std::fprintf(stderr, "cannot write scratch at %s: %s\n", file.c_str(),
                     std::strerror(e ? e : EROFS));
        std::fprintf(stderr,
            "Under a read-only rootfs, scratch needs an explicitly-mounted\n"
            "tmpfs (compose 'tmpfs:' / K8s emptyDir / podman --tmpfs).\n");
        return 3;
    }
    out << "ephemeral scratch data\n";
    out.flush();
    if (!out) {
        std::fprintf(stderr, "write to %s failed after open\n", file.c_str());
        return 3;
    }
    out.close();
    std::ifstream in(file);
    std::string line;
    std::getline(in, line);
    std::printf("wrote and read back %s: \"%s\"\n", file.c_str(), line.c_str());
    std::printf("This lives on tmpfs (RAM-backed) and is recycled on restart.\n");
    return 0;
}

void usage() {
    std::fprintf(stderr,
        "usage: app <command>\n"
        "  log-stdout         configure spdlog -> stdout (the correct pattern)\n"
        "  log-file <path>    naive spdlog file sink (the read-only trap)\n"
        "  check-file <path>  report whether <path> exists (ephemerality)\n"
        "  scratch <dir>      write scratch into <dir> (needs a tmpfs)\n");
}

}  // namespace

int main(int argc, char** argv) {
    const std::string cmd = (argc > 1) ? argv[1] : "log-stdout";
    if (cmd == "log-stdout") return mode_log_stdout();
    if (cmd == "log-file") {
        if (argc < 3) { usage(); return 2; }
        return mode_log_file(argv[2]);
    }
    if (cmd == "check-file") {
        if (argc < 3) { usage(); return 2; }
        return mode_check_file(argv[2]);
    }
    if (cmd == "scratch") {
        if (argc < 3) { usage(); return 2; }
        return mode_scratch(argv[2]);
    }
    usage();
    return 2;
}
