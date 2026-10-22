#include "carla/client/Client.h"
#include "carla/client/TimeoutException.h"
#include "carla/MsgPackAdaptors.h"
#include "carla/rpc/Metadata.h"
#include "carla/rpc/Response.h"
#include "rpc/server.h"

#include <atomic>
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>

void ValidateSerialization() {
  carla::Buffer allocated(std::size_t(5u));
  const unsigned char payload[] = {'m', 'a', 'c'};
  carla::Buffer copied(payload, sizeof(payload));
  if (allocated.size() != 5u || copied.size() != 3u || copied.data()[2] != 'c') {
    throw std::runtime_error("Native size_t buffer construction failed");
  }
  carla::Buffer buffer;
  void (carla::Buffer::*reset_narrow)(carla::Buffer::size_type) = &carla::Buffer::reset;
  (buffer.*reset_narrow)(2u);
  buffer.copy_from(4u, std::string("macOS"));
  if (buffer.size() != 9u || buffer.data()[4] != 'm') {
    throw std::runtime_error("Buffer offset copy failed");
  }
  bool rejected_oversize = false;
  try {
    buffer.reset(static_cast<uint64_t>(carla::Buffer::max_size()) + 1u);
  } catch (const std::invalid_argument &) {
    rejected_oversize = true;
  }
  if (!rejected_oversize) {
    throw std::runtime_error("Buffer size limit was not enforced");
  }
  using Variant = boost::variant2::variant<uint32_t, std::string>;
  for (const Variant &value : {Variant(uint32_t(42u)), Variant(std::string("macOS"))}) {
    const auto serialized = carla::MsgPack::Pack(value);
    if (carla::MsgPack::UnPack<Variant>(serialized) != value) {
      throw std::runtime_error("MessagePack variant roundtrip failed");
    }
  }
}

int main(int argc, char **argv) {
  ValidateSerialization();
  const unsigned long port = argc > 1 ? std::stoul(argv[1]) : 42916u;
  if (port == 0u || port > 65535u) {
    throw std::invalid_argument("Expected a TCP port between 1 and 65535");
  }
  std::atomic<bool> delay_response{false};
  rpc::server server("127.0.0.1", static_cast<uint16_t>(port));
  server.bind("version", [&delay_response](carla::rpc::Metadata metadata) {
    if (metadata.IsResponseIgnored()) {
      return carla::rpc::Response<std::string>(carla::rpc::ResponseError("Expected a synchronous call"));
    }
    if (delay_response.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    return carla::rpc::Response<std::string>(std::string("0.9.16"));
  });
  server.async_run(1);
  carla::client::Client client("127.0.0.1", static_cast<uint16_t>(port), 1);
  client.SetTimeout(carla::time_duration::seconds(2));
  if (client.GetClientVersion() != "0.9.16" || client.GetServerVersion() != "0.9.16") {
    throw std::runtime_error("Native client version or loopback RPC failed");
  }
  delay_response.store(true);
  client.SetTimeout(carla::time_duration::milliseconds(20));
  bool timed_out = false;
  try {
    client.GetServerVersion();
  } catch (const carla::client::TimeoutException &) {
    timed_out = true;
  }
  if (!timed_out) {
    throw std::runtime_error("Delayed RPC did not raise a client timeout");
  }
  std::cout << "Native LibCarla 0.9.16: serialization, loopback RPC and timeout passed\n";
}
