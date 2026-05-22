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

A stateless service often has to update its database *and* announce the
change to the rest of the system. Doing those as two independent
steps has a silent failure mode: the commit succeeds, the publish
fails, and the event is lost with no trace. The outbox pattern closes
that window by writing the business row and an event row in **one
transaction**, then publishing the event from a separate relay.

## What it demonstrates

**An atomic order + event write.** `CreateOrder` opens one transaction
and writes both the order (deduped on `idempotency_key`, exactly as
[07-state-externalization]({{ '/examples/statelessness-07-state-externalization/' | relative_url }})
does) and an `outbox` row. The outbox row is written only on a *fresh*
insert, so a client retry never emits a duplicate event. Both rows
commit together — there is no state where the order exists but the event
was lost.

**A relay with `FOR UPDATE SKIP LOCKED`.** A poller reads unpublished
outbox rows, produces each to Kafka, flushes to confirm the broker
acked, then marks them published and commits. `SKIP LOCKED` lets
multiple relay replicas run without grabbing the same row. A crash
between the Kafka ack and the commit re-publishes on the next pass —
at-least-once delivery.

**An idempotent consumer.** The consumer applies each event with
`INSERT ... ON CONFLICT (event_id) DO NOTHING` and commits the Kafka
offset only *after* the DB write. A duplicate `event_id` is a no-op, so
at-least-once delivery is safe. At-least-once delivery plus an idempotent
consumer gives an exactly-once *effect* — the achievable guarantee, since
exactly-once *delivery* is not.

**librdkafka through a C-API RAII wrapper.** Doc 07 names librdkafka as
the standard. The example uses its C API directly — a stable C ABI from
the system — for the same reason 07 reaches PostgreSQL through libpq
rather than libpqxx: no Conan C++ recipe to fight, no libstdc++ ABI
mixing.

## Running it

```bash
cd examples/statelessness/07-outbox-pattern
./demo.sh            # postgres + kafka + producer + relay + consumer
./demo.sh --clean    # tear down
```

CI verification: `scripts/test-stateless-demo-07-outbox-pattern.sh`.

The demo brings up five services: the SCLorg Postgres image, a Strimzi
Kafka broker (single-node KRaft, no Zookeeper), and the producer, relay,
and consumer (one image, three commands). Act 3 injects a *duplicate*
event so you can watch the consumer dedup it; the optional kcat step
dumps the topic from the host if `kcat` is installed.

## A note on the dependencies

librdkafka has no UBI-native package, so **EPEL** is enabled solely for
it — a sanctioned exception, in the same spirit as the Postgres and
Strimzi images. The broker is Strimzi's Kafka image (Red Hat ecosystem)
driven standalone in KRaft mode. kcat is an *optional* host tool
(`sudo dnf install kcat` on Fedora); neither the demo nor the test
requires it, because the relay's one-shot `produce` mode injects the
duplicate event directly.

## Production note

A real deployment would run several relay replicas, partition the topic
by `aggregate_id` for per-order ordering, and parse the payload with a
JSON library rather than storing it raw. The transaction boundary, the
poller, and the idempotent apply are the parts worth keeping.
