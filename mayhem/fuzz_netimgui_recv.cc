// Fuzz the NetImgui client's receive path, the one a MuJoCo process exposes to whoever connects to
// its NetImgui port: the TCP handshake (Communications_Initialize) and the receive loop
// (Communications_Incoming) that reads each command's size off the wire.
//
// A real loopback TCP connection carries the input: the client side is a NetImgui socket from
// Network::Connect(), the peer is a plain socket this harness writes the input to.
//
// Input: byte 0, bit 0: 0 = handshake, 1 = receive loop; byte 1: how many bytes the peer delivers
// between two runs of the receive loop (0 = everything at once, N = N bytes at a time, as TCP
// segmentation would); the rest is what the peer sends, followed by a close.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Private/NetImgui_Client.h"
#include "Private/NetImgui_CmdPackets.h"
#include "Private/NetImgui_Network.h"

namespace NetImgui {
namespace Internal {
namespace Client {
void Communications_Incoming(ClientInfo& client);
bool Communications_Initialize(ClientInfo& client);
}  // namespace Client
}  // namespace Internal
}  // namespace NetImgui

using namespace NetImgui::Internal;
using Client::ClientInfo;

static int g_listen = -1;
static uint16_t g_port = 0;

extern "C" int LLVMFuzzerInitialize(int*, char***) {
  g_listen = socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  socklen_t len = sizeof(addr);
  if (g_listen < 0 || bind(g_listen, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
      listen(g_listen, 16) != 0 ||
      getsockname(g_listen, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
    perror("loopback listener");
    abort();
  }
  g_port = ntohs(addr.sin_port);
  return 0;
}

static void Deliver(int peer, const uint8_t* data, size_t size) {
  while (size > 0) {
    ssize_t sent = send(peer, data, size, MSG_NOSIGNAL | MSG_DONTWAIT);
    if (sent <= 0) return;  // socket buffer full: the rest never arrives
    data += sent;
    size -= static_cast<size_t>(sent);
  }
}

// Run the receive loop while the socket has data (or an error) to report.
static void Pump(ClientInfo& client) {
  for (int i = 0; i < 1000000 && !client.mbDisconnectPending &&
                  Network::DataReceivePending(client.mpSocketComs);
       i++) {
    Client::Communications_Incoming(client);
  }
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size < 2) return -1;
  const bool handshake = (data[0] & 1) == 0;
  const size_t step = data[1];
  data += 2;
  size -= 2;

  Network::SocketInfo* sock = Network::Connect("127.0.0.1", g_port);
  int peer = accept(g_listen, nullptr, nullptr);
  if (!sock || peer < 0) {
    fprintf(stderr, "loopback connection failed\n");
    abort();
  }

  ClientInfo* client = new ClientInfo();
  client->mbDisconnectPending = false;
  client->mbDisconnectListen = false;

  if (handshake) {
    client->mpSocketPending = sock;
    Deliver(peer, data, size);
    shutdown(peer, SHUT_WR);
    Client::Communications_Initialize(*client);
  } else {
    client->mpSocketComs = sock;
    size_t off = 0;
    while (off < size && !client->mbDisconnectPending) {
      const size_t len = step ? std::min(step, size - off) : size;
      Deliver(peer, data + off, len);
      off += len;
      Pump(*client);
    }
    shutdown(peer, SHUT_WR);
    Pump(*client);
  }

  if (client->mPendingRcv.bAutoFree) netImguiDeleteSafe(client->mPendingRcv.pCommand);
  Network::SocketInfo* coms = client->mpSocketComs.exchange(nullptr);
  if (coms) Network::Disconnect(coms);
  close(peer);
  delete client;
  return 0;
}
