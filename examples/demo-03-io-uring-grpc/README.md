# Demo 3 — io_uring and async gRPC

Tutorial sections: §7 (I/O latency), §8 (Networking and the kernel boundary)

## What this demo shows

Two server variants and a load-generation harness, packaged with
`podman compose`:

1. **`echo-uring`** — a TCP echo service built directly on `io_uring`.
   Demonstrates submission queue / completion queue mechanics, fixed
   buffers, and `IORING_OP_RECV_MULTISHOT` for amortizing syscalls.
2. **`grpc-async`** — an asynchronous gRPC server using the completion-queue
   API, with `SO_REUSEPORT` enabled so multiple workers share a port and
   the kernel does the accept distribution.
3. **`load`** — `hey` and `ghz` driving requests at the two services.

Three networking modes are exercised by the same harness:

- Default rootless slirp/pasta networking
- Pasta with explicit MTU and buffer sizing
- `--network=host` (rootful or with the `userns=keep-id` workaround)

## Run it

```bash
./demo.sh                 # full run, all variants, all networks
./demo.sh --variant uring # only the io_uring server
./demo.sh --network host  # only the host-network case
./demo.sh --clean
```

## Output

- Latency tables (p50/p95/p99) for each server × network combination
- A `results/` directory with the raw `hey` and `ghz` JSON outputs

## Caveats

- `io_uring` requires kernel >= 5.6 for the basics, and >= 5.19 for
  `RECV_MULTISHOT`. Fedora 44 ships well past that, but the demo prints
  the running kernel version up front so the audience sees the dependency.
- Rootless `--network=host` typically requires `userns=keep-id`. The demo
  detects when this isn't possible and skips that comparison rather than
  failing.
- `SO_REUSEPORT` works in both rootless and rootful containers, but only
  if the workers share the same network namespace.
