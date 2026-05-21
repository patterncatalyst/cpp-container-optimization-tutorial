// kafka.hpp — thin RAII wrappers over the librdkafka C client.
//
// Doc 07 names "librdkafka with the C++ wrapper" as the standard. This
// example uses librdkafka's C API directly (a stable C ABI, installed
// from the system) for the same reason 07-state-externalization uses
// libpq rather than libpqxx: no Conan C++ recipe to fight, no libstdc++
// ABI mixing. The wrappers below give us RAII handles and exceptions
// without pulling in a C++ binding.
//
//   KafkaProducer   produce(topic, key, value) + flush() — used by the
//                   relay. enable.idempotence + acks=all so a producer
//                   retry doesn't duplicate at the broker; the
//                   end-to-end at-least-once guarantee still rests on
//                   the outbox (the relay may re-publish after a crash),
//                   which is exactly why the consumer must be idempotent.
//   KafkaConsumer   subscribe + poll + commit — used by the consumer,
//                   with manual offset commit AFTER the DB write so a
//                   crash re-delivers rather than loses (at-least-once).

#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>

#include <librdkafka/rdkafka.h>

namespace statelessoutbox {

inline void conf_set_or_throw(rd_kafka_conf_t* conf, const char* k,
                              const char* v) {
    char errstr[512];
    if (rd_kafka_conf_set(conf, k, v, errstr, sizeof(errstr)) !=
        RD_KAFKA_CONF_OK) {
        rd_kafka_conf_destroy(conf);
        throw std::runtime_error(std::string("kafka conf ") + k + ": " + errstr);
    }
}

class KafkaProducer {
public:
    explicit KafkaProducer(const std::string& brokers) {
        rd_kafka_conf_t* conf = rd_kafka_conf_new();
        conf_set_or_throw(conf, "bootstrap.servers", brokers.c_str());
        // Idempotent producer: implies acks=all and dedups producer-side
        // retries at the broker.
        conf_set_or_throw(conf, "enable.idempotence", "true");
        char errstr[512];
        rk_ = rd_kafka_new(RD_KAFKA_PRODUCER, conf, errstr, sizeof(errstr));
        if (!rk_) {
            // rd_kafka_new takes ownership of conf only on success.
            rd_kafka_conf_destroy(conf);
            throw std::runtime_error(std::string("kafka producer: ") + errstr);
        }
    }
    ~KafkaProducer() {
        if (rk_) {
            rd_kafka_flush(rk_, 5000);
            rd_kafka_destroy(rk_);
        }
    }
    KafkaProducer(const KafkaProducer&) = delete;
    KafkaProducer& operator=(const KafkaProducer&) = delete;

    // Enqueue a message. Delivery is confirmed by flush().
    void produce(const std::string& topic, const std::string& key,
                 const std::string& value) {
        const rd_kafka_resp_err_t err = rd_kafka_producev(
            rk_, RD_KAFKA_V_TOPIC(topic.c_str()),
            RD_KAFKA_V_KEY(key.data(), key.size()),
            RD_KAFKA_V_VALUE(const_cast<char*>(value.data()), value.size()),
            RD_KAFKA_V_END);
        if (err) {
            throw std::runtime_error(std::string("kafka produce: ") +
                                     rd_kafka_err2str(err));
        }
    }

    // Block until all enqueued messages are delivered (acked). Throws if
    // any remain undelivered after the timeout — the caller must then
    // NOT mark the outbox row published.
    void flush(int timeout_ms) {
        rd_kafka_flush(rk_, timeout_ms);
        if (rd_kafka_outq_len(rk_) > 0) {
            throw std::runtime_error("kafka flush: messages still queued");
        }
    }

private:
    rd_kafka_t* rk_ = nullptr;
};

class KafkaConsumer {
public:
    KafkaConsumer(const std::string& brokers, const std::string& group,
                  const std::string& topic) {
        rd_kafka_conf_t* conf = rd_kafka_conf_new();
        conf_set_or_throw(conf, "bootstrap.servers", brokers.c_str());
        conf_set_or_throw(conf, "group.id", group.c_str());
        conf_set_or_throw(conf, "auto.offset.reset", "earliest");
        // Manual commit: we commit AFTER the DB apply, so a crash
        // re-delivers (at-least-once) rather than silently dropping.
        conf_set_or_throw(conf, "enable.auto.commit", "false");

        char errstr[512];
        rk_ = rd_kafka_new(RD_KAFKA_CONSUMER, conf, errstr, sizeof(errstr));
        if (!rk_) {
            rd_kafka_conf_destroy(conf);
            throw std::runtime_error(std::string("kafka consumer: ") + errstr);
        }
        rd_kafka_poll_set_consumer(rk_);

        rd_kafka_topic_partition_list_t* tlist =
            rd_kafka_topic_partition_list_new(1);
        rd_kafka_topic_partition_list_add(tlist, topic.c_str(),
                                          RD_KAFKA_PARTITION_UA);
        const rd_kafka_resp_err_t err = rd_kafka_subscribe(rk_, tlist);
        rd_kafka_topic_partition_list_destroy(tlist);
        if (err) {
            throw std::runtime_error(std::string("kafka subscribe: ") +
                                     rd_kafka_err2str(err));
        }
    }
    ~KafkaConsumer() {
        if (rk_) {
            rd_kafka_consumer_close(rk_);
            rd_kafka_destroy(rk_);
        }
    }
    KafkaConsumer(const KafkaConsumer&) = delete;
    KafkaConsumer& operator=(const KafkaConsumer&) = delete;

    // Poll for one message. Caller owns the returned message and must
    // call rd_kafka_message_destroy(). Returns nullptr on timeout.
    rd_kafka_message_t* poll(int timeout_ms) {
        return rd_kafka_consumer_poll(rk_, timeout_ms);
    }

    // Synchronously commit the offset of a processed message.
    void commit(rd_kafka_message_t* msg) {
        rd_kafka_commit_message(rk_, msg, /*async=*/0);
    }

private:
    rd_kafka_t* rk_ = nullptr;
};

}  // namespace statelessoutbox
