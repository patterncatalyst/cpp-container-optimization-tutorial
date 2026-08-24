# statelessness/07-outbox-pattern — atomic DB write + event emission

Compendium reference:
[Doc 07 — State externalization](../../../reference/statelessness/07-state-externalization/)
(the *Outbox pattern* section)

The runnable companion to Doc 07's Outbox pattern. A stateless service
often has to do two things when it handles a write: update its database
*and* tell the rest of the system about it (publish an event). Doing
those as two independent steps has a silent failure mode — the DB commit
succeeds, the publish fails, and the event is lost forever with no trace.

The outbox pattern removes that window. The service writes the business
row **and** an "outbox" row in **one transaction**, so they commit or
fail together. A separate relay reads the outbox and publishes to Kafka.
Because the relay may re-publish after a crash (at-least-once), the
consumer is idempotent — applying the same event twice is a no-op. The
net effect is exactly-once *processing* without exactly-once *delivery*
(which is not achievable).

## What it demonstrates

**Atomic order + event write** ([`src/order_svc.cpp`](src/order_svc.cpp)).
`CreateOrder` opens one transaction and writes both the order (deduped on
`idempotency_key`, exactly as 07 does) and an `outbox` row. The outbox
row is written only on a *fresh* insert, so a client retry never emits a
duplicate event. Both rows commit together — there is no state in which
the order exists but the event was lost.

**The relay** ([`src/relay.cpp`](src/relay.cpp)). A poller reads
unpublished rows with `FOR UPDATE SKIP LOCKED` (so multiple relay
replicas never grab the same row), produces each to Kafka, flushes to
confirm the broker acked, then marks them `published_at` and commits. A
crash between the Kafka ack and the commit re-publishes on the next pass:
at-least-once.

**The idempotent consumer** ([`src/consumer.cpp`](src/consumer.cpp)).
Reads the topic and applies each event with
`INSERT ... ON CONFLICT (event_id) DO NOTHING`. The Kafka offset is
committed only *after* the DB apply, so a crash re-delivers rather than
drops. A duplicate `event_id` is silently ignored — that is what makes
at-least-once delivery safe.

**librdkafka via a C-API RAII wrapper** ([`src/kafka.hpp`](src/kafka.hpp)).
Doc 07 names librdkafka as the standard. We use its **C** API directly —
a stable C ABI from the system — for the same reason 07 uses libpq over
libpqxx: no Conan C++ recipe to fight, no libstdc++ ABI mixing. Thin RAII
wrappers (`KafkaProducer`, `KafkaConsumer`) give us handles and
exceptions without a C++ binding.

## Prerequisites

- **podman** with the `podman compose` provider, and **curl** (the demo
  and test use them).
- **kcat** *(optional)* — only to dump the Kafka topic from the host in
  Act 2 of the demo. On Fedora:

  ```console
  sudo dnf install kcat
  ```

  The demo and the test do **not** require kcat: idempotency is exercised
  by the relay's one-shot `produce` mode, which injects a duplicate event
  directly. kcat is purely a window onto the bus.

## Running it

```console
./demo.sh           # build, bring up all five services, run the three acts
./demo.sh --keep    # leave the stack running afterwards
./demo.sh --clean   # tear everything down
```

The first build compiles the gRPC chain (~5 min cold; much faster with a
warm Conan cache). Kafka takes ~20s to become healthy on first start.

The host-level end-to-end test:

```console
../../../scripts/test-stateless-demo-07-outbox-pattern.sh
```

## Layout

```
07-outbox-pattern/
├── proto/order.proto      OrderService (the producer's front door)
├── src/
│   ├── pg_pool.hpp        process-scoped libpq pool + ScopedConnection (from 07)
│   ├── kafka.hpp          RAII wrappers over the librdkafka C API
│   ├── order_svc.cpp      gRPC producer: order + outbox in one txn
│   ├── relay.cpp          outbox poller (run) + one-shot produce
│   ├── consumer.cpp       Kafka -> idempotent projection
│   └── client.cpp         gRPC client
├── CMakeLists.txt         four binaries
├── conanfile.py           gRPC + protobuf + abseil (libpq + librdkafka are system)
├── Containerfile          UBI 10 (librdkafka built from source); ubi-minimal runtime
└── compose.yml            postgres + kafka (Strimzi) + producer + relay + consumer
```

## A note on the build

The producer/relay/consumer are one image running three different
binaries (`compose.yml` selects each via the command). gRPC, protobuf,
and abseil come from Conan (the verified pinned trio). libpq comes from
UBI AppStream. librdkafka has no el10 package — it's absent from UBI
AppStream, from the (default-enabled) CodeReady Builder repo, and from
EPEL 10 alike (EPEL 10 ships only Python Kafka clients, not the C
library or its headers) — so it's **built from source** in the
Containerfile instead: a pinned tag, a minimal feature set (no
SSL/SASL/compression, since the demo speaks plaintext to Kafka),
installed to `/usr/local` and found via `pkg-config`.

The broker is **Strimzi's Kafka image** (Red Hat ecosystem) run
standalone in single-node **KRaft** mode (no Zookeeper): the container
formats its storage and starts the broker directly. Kafka exposes two
listeners — `INTERNAL` (`kafka:9092`) for the in-network services and
`EXTERNAL` (`localhost:19092`) so host tools like kcat can read the
topic.

## Production note

A real deployment would run multiple relay replicas (the
`FOR UPDATE SKIP LOCKED` query is built for that), partition the Kafka
topic by `aggregate_id` for ordering per order, and use a JSON library in
the consumer rather than storing the raw payload. The shape here is the
teaching version: the transaction boundary, the poller, and the
idempotent apply are the parts that matter.
