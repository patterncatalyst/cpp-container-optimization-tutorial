---
title: "Statelessness 07 — Outbox pattern"
description: "The runnable companion to compendium Doc 07's Outbox pattern: an order and its event written in one PostgreSQL transaction, a relay that publishes the outbox to Kafka with FOR UPDATE SKIP LOCKED, and an idempotent consumer — at-least-once delivery plus idempotent apply gives an exactly-once effect."
order: 208
card_eyebrow: "Compendium · <strong>Doc 07</strong>"
card_title: "Outbox pattern"
card_blurb: "Atomic DB write plus event emission: an order and its event written in one transaction, a relay that publishes the outbox to Kafka with FOR UPDATE SKIP LOCKED, and an idempotent consumer — at-least-once delivery plus idempotent apply gives an exactly-once effect."
layout: example
sectionid: examples
permalink: /examples/statelessness-07-outbox-pattern/
demo_dir: statelessness/07-outbox-pattern
github_path: examples/statelessness/07-outbox-pattern
---

> The full source for this example lives in [`examples/statelessness/07-outbox-pattern/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/07-outbox-pattern) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 07 — State externalization]({{ '/reference/statelessness/07-state-externalization/' | relative_url }})
(the *Outbox pattern* section)

Tutorial sections:
[§8 I/O Latency: io_uring, Async gRPC]({{ '/docs/08-io-latency/' | relative_url }}) +
[§9 Networking & Kernel Parameters]({{ '/docs/09-networking-kernel/' | relative_url }})

A stateless service often has to update its database *and* announce the
change to the rest of the system. Doing those as two independent steps has a
silent failure mode: the commit succeeds, the publish fails, and the event is
lost with no trace. The outbox pattern closes that window by writing the
business row and an event row in **one transaction**, then publishing the
event from a separate relay.

## Why this matters

The dual-write problem is one of the most common sources of silent data
divergence in distributed systems, and it's invisible until it bites:

- **You can't atomically write to two systems.** A commit to PostgreSQL and a
  publish to Kafka are separate operations; any failure between them leaves
  the two out of sync. Crash after the commit but before the publish, and the
  order exists but nothing downstream ever hears about it.
- **The lost event has no trace.** Unlike a failed write that returns an
  error, a lost publish often succeeds silently from the caller's view — the
  order was created, the response was 200, and the missing event surfaces
  hours later as a reconciliation discrepancy nobody can explain.
- **Exactly-once delivery doesn't exist; exactly-once *effect* does.** You
  can't guarantee a message is delivered exactly once over a network. What
  you *can* build is at-least-once delivery plus an idempotent consumer,
  which produces the same end state as exactly-once — the achievable
  guarantee.

## What this demo shows

**An atomic order + event write.** `CreateOrder` opens one transaction and
writes both the order (deduped on `idempotency_key`, exactly as
[07-state-externalization]({{ '/examples/statelessness-07-state-externalization/' | relative_url }})
does) and an `outbox` row. The outbox row is written only on a *fresh*
insert, so a client retry never emits a duplicate event. Both rows commit
together — there is no state where the order exists but the event was lost.

**A relay with `FOR UPDATE SKIP LOCKED`.** A poller reads unpublished outbox
rows, produces each to Kafka, flushes to confirm the broker acked, then marks
them published and commits. `SKIP LOCKED` lets multiple relay replicas run
without grabbing the same row. A crash between the Kafka ack and the commit
re-publishes on the next pass — at-least-once delivery.

**An idempotent consumer.** The consumer applies each event with `INSERT ...
ON CONFLICT (event_id) DO NOTHING` and commits the Kafka offset only *after*
the DB write. A duplicate `event_id` is a no-op, so at-least-once delivery is
safe. At-least-once delivery plus an idempotent consumer gives an
exactly-once *effect*.

**librdkafka through a C-API RAII wrapper.** Doc 07 names librdkafka as the
standard. The example uses its C API directly — a stable C ABI from the
system — for the same reason 07 reaches PostgreSQL through libpq rather than
libpqxx: no Conan C++ recipe to fight, no libstdc++ ABI mixing.

## How to run

```bash
cd examples/statelessness/07-outbox-pattern
./demo.sh            # postgres + kafka + producer + relay + consumer
./demo.sh --keep     # leave the stack running
./demo.sh --clean    # tear down
```

Five services come up: the SCLorg Postgres image, a Strimzi Kafka broker
(single-node KRaft, no Zookeeper), and the producer, relay, and consumer (one
image, three commands). Act 3 injects a *duplicate* event so you can watch the
consumer dedup it. The first build compiles the gRPC chain (~5 min cold);
Kafka takes ~20 s to become healthy on first start.

CI verification: `scripts/test-stateless-demo-07-outbox-pattern.sh`.

## What you'll see

Representative output on a Fedora 44 host with Podman 5.x — a create that
writes order + outbox atomically, the relay publishing it, the consumer
applying it, then a deliberately duplicated event being deduped:

```
==> act 1: CreateOrder  key=ord-xyz-001
    order_id   : 1   outbox_event_id : evt-1   (both written in ONE txn)
    status: OK

==> act 2: relay (poll outbox, publish to Kafka)
    [relay] SELECT ... FOR UPDATE SKIP LOCKED -> 1 unpublished row
    [relay] produced evt-1 to topic 'orders'   (broker acked)
    [relay] marked evt-1 published, committed

    [consumer] received evt-1 -> INSERT ON CONFLICT DO NOTHING -> applied
    [consumer] projection now has order 1

==> act 3: re-inject evt-1 (duplicate delivery)
    [consumer] received evt-1 -> INSERT ON CONFLICT DO NOTHING -> 0 rows
    [consumer] duplicate ignored (idempotent apply)
    projection row count : 1   <- exactly-once EFFECT
```

## How to read the output

- **Act 1 writes two rows in one transaction.** The order and its outbox
  event commit together. There is no instant where the order exists but the
  event doesn't — that atomicity is the whole point of the pattern.
- **The relay's `FOR UPDATE SKIP LOCKED` log line is the multi-replica
  enabler.** It locks only the rows it's processing and skips rows another
  relay holds, so you can run several relays without double-publishing.
- **Act 3's duplicate produces "0 rows" and is ignored.** That's the
  idempotent consumer: the second delivery of `evt-1` hits the `ON CONFLICT
  (event_id)` and applies nothing. The projection row count staying at 1 is
  the exactly-once *effect*.
- **If act 3 ever bumps the count to 2**, the consumer isn't idempotent — it
  applied a duplicate. The `event_id` UNIQUE constraint plus committing the
  offset *after* the DB write is what prevents that.

## Files

- `proto/order.proto` — `OrderService`, the producer's front door
- `src/pg_pool.hpp` — process-scoped libpq pool + `ScopedConnection` (reused
  from state externalization)
- `src/kafka.hpp` — RAII wrappers over the librdkafka C API
- `src/order_svc.cpp` — gRPC producer: order + outbox in one transaction
- `src/relay.cpp` — outbox poller (`run`) + a one-shot `produce` mode
- `src/consumer.cpp` — Kafka → idempotent projection
- `src/client.cpp` — the gRPC client
- `CMakeLists.txt` — four binaries
- `conanfile.py` — gRPC + protobuf + abseil (libpq + librdkafka are system)
- `Containerfile` — UBI 9 + EPEL (librdkafka); `ubi-minimal` runtime
- `compose.yml` — postgres + kafka (Strimzi) + producer + relay + consumer
- `demo.sh` — the three acts

## Caveats and gotchas

- **librdkafka comes from EPEL.** It has no UBI-native package, so EPEL is
  enabled solely for it — a sanctioned exception, in the same spirit as the
  Postgres and Strimzi images. Everything else stays on UBI/Conan.
- **The consumer commits the offset *after* the DB write, never before.**
  This ordering is what makes at-least-once safe: if it crashes after applying
  but before committing the offset, the event redelivers and the idempotent
  `ON CONFLICT` makes the re-apply a no-op. Commit the offset first and you'd
  have at-most-once — the lost-event bug, reintroduced.
- **`kcat` is optional.** It's only a window onto the bus for inspecting the
  topic from the host (`sudo dnf install kcat`). Neither the demo nor the
  test needs it — idempotency is exercised by the relay's one-shot `produce`
  mode, which injects the duplicate directly.
- **The payload is stored raw.** The teaching version stores the event
  payload as a raw string; production would parse it with a JSON library and
  partition the topic by `aggregate_id` for per-order ordering.

## Source materials

This example deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Enberg, *Latency*, ch. 5** — the cost and failure modes of crossing a
  process boundary; why the dual-write window exists and what closes it
- **Iglberger, *C++ Software Design*, ch. 2** — separation of concerns: the
  producer, relay, and consumer as independent components with one
  responsibility each
- **Andrist & Sehr, *C++ High Performance* 2e, ch. 9** — the RAII wrappers
  over the librdkafka C API; owning a C resource safely from C++

## Linked tutorial sections

- [**§8 I/O Latency: io_uring, Async gRPC**]({{ '/docs/08-io-latency/' | relative_url }}) —
  the latency of crossing to Kafka and back; the relay's flush-and-confirm is
  an I/O-latency decision.
- [**§9 Networking & Kernel Parameters**]({{ '/docs/09-networking-kernel/' | relative_url }}) —
  broker connections, listener configuration, and the network-level settings
  behind talking to Kafka across the compose network.

## Production note

A real deployment would run several relay replicas (the `FOR UPDATE SKIP
LOCKED` query is built for that), partition the topic by `aggregate_id` for
per-order ordering, and parse the payload with a JSON library rather than
storing it raw. The transaction boundary, the poller, and the idempotent
apply are the parts worth keeping.

## Where it sits in the compendium

The outbox builds directly on
[state externalization]({{ '/examples/statelessness-07-state-externalization/' | relative_url }}) —
same `pg_pool.hpp`, same `ON CONFLICT` idempotency — and extends it with
atomic event emission. The idempotent-consumer discipline is the same
authoritative-dedup idea the capstone
([Doc 10]({{ '/reference/statelessness/10-grpc-microservices/' | relative_url }}))
applies to its idempotency store.
