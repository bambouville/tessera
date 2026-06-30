#include "fatal_assert.h"

#include "completeterminal.h"
#include "networktransport-impl.h"
#include "user.h"

namespace {

using ClientTransport = Network::Transport<Network::UserStream, Terminal::Complete>;
using ServerTransport = Network::Transport<Terminal::Complete, Network::UserStream>;

[[maybe_unused]] constexpr const char *kClientKey = "AAECAwQFBgcICQoLDA0ODw";
[[maybe_unused]] constexpr const char *kLoopbackIP = "127.0.0.1";
[[maybe_unused]] constexpr const char *kLoopbackPort = "60001";

__attribute__((used)) void force_client_transport_instantiation() {
  Network::UserStream user_stream;
  Terminal::Complete terminal(80, 24);
  ClientTransport transport(user_stream, terminal, kClientKey, kLoopbackIP, kLoopbackPort);

  transport.set_send_delay(1);
  transport.get_current_state().push_back(Parser::Resize(80, 24));
  transport.set_verbose(0);

  (void)transport.wait_time();
  (void)transport.fds();
  (void)transport.has_remote_addr();
  (void)transport.get_remote_state_num();
  (void)transport.get_latest_remote_state();
  (void)transport.get_sent_state_acked_timestamp();
  (void)transport.get_sent_state_acked();
  (void)transport.get_sent_state_last();
  (void)transport.send_interval();
  (void)transport.get_send_error();
  (void)transport.shutdown_in_progress();
  (void)transport.shutdown_acknowledged();
  (void)transport.shutdown_ack_timed_out();
  (void)transport.counterparty_shutdown_ack_sent();

  transport.tick();
  transport.recv();
  transport.start_shutdown();
}

__attribute__((used)) void force_server_transport_instantiation() {
  Terminal::Complete terminal(80, 24);
  Network::UserStream remote_stream;
  ServerTransport transport(terminal, remote_stream, nullptr, nullptr);

  transport.set_send_delay(1);
  transport.set_verbose(0);
  transport.set_current_state(terminal);

  (void)transport.wait_time();
  (void)transport.fds();
  (void)transport.port();
  (void)transport.get_key();
  (void)transport.get_remote_addr();
  (void)transport.get_remote_addr_len();
  (void)transport.get_remote_state_num();
  (void)transport.get_latest_remote_state();
  (void)transport.get_remote_diff();
  (void)transport.get_sent_state_acked_timestamp();
  (void)transport.get_sent_state_acked();
  (void)transport.get_sent_state_last();
  (void)transport.send_interval();
  (void)transport.get_send_error();
  (void)transport.shutdown_in_progress();
  (void)transport.shutdown_acknowledged();
  (void)transport.shutdown_ack_timed_out();
  (void)transport.counterparty_shutdown_ack_sent();

  transport.tick();
  transport.recv();
  transport.start_shutdown();
}

} // namespace
