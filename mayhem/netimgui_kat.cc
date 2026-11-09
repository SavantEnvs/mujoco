// Known-answer test for the NetImgui client's receive path. A peer talks to the client over a real
// loopback TCP connection: it sends an input command whole and one byte at a time, then performs the
// handshake with a good version, a wrong version and a short CmdVersion. The program prints what the
// client ended up with; mayhem/test.sh compares that output with the expected lines.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

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

struct Link {
  Network::SocketInfo* client;
  int peer;
};

static Link Open() {
  Link link;
  link.client = Network::Connect("127.0.0.1", g_port);
  link.peer = accept(g_listen, nullptr, nullptr);
  return link;
}

static void Pump(ClientInfo& client) {
  for (int i = 0; i < 100000 && !client.mbDisconnectPending &&
                  Network::DataReceivePending(client.mpSocketComs);
       i++) {
    Client::Communications_Incoming(client);
  }
}

// Sends 'bytes' to the client in pieces of 'step' bytes and returns what the client received.
static void SendInput(const char* name, size_t step) {
  Link link = Open();
  ClientInfo* client = new ClientInfo();
  client->mbDisconnectPending = false;
  client->mpSocketComs = link.client;

  CmdInput cmd;
  cmd.mDesiredFps = 60.f;
  cmd.mKeyCharCount = 3;
  cmd.mKeyChars[0] = 'a';
  cmd.mKeyChars[1] = 'b';
  cmd.mKeyChars[2] = 0x263a;
  const uint8_t* bytes = reinterpret_cast<const uint8_t*>(&cmd);
  for (size_t off = 0; off < sizeof(cmd); off += step) {
    size_t len = sizeof(cmd) - off < step ? sizeof(cmd) - off : step;
    send(link.peer, bytes + off, len, MSG_NOSIGNAL);
    Pump(*client);
  }

  CmdInput* got = client->mPendingInputIn.Release();
  printf("%s: received=%s", name, got ? "yes" : "no");
  if (got) {
    printf(" size=%u fps=%.0f keys=%u", got->mSize, got->mDesiredFps, got->mKeyCharCount);
    netImguiDeleteSafe(got);
  }
  uint16_t key;
  printf(" ring=");
  while (client->mPendingKeyIn.ReadData(&key)) printf("%04x ", key);
  printf("disconnect=%d\n", client->mbDisconnectPending ? 1 : 0);

  Network::Disconnect(client->mpSocketComs.exchange(nullptr));
  close(link.peer);
  delete client;
}

// Runs the handshake against 'bytes' and prints the verdict and the answer the client sent.
static void Handshake(const char* name, const uint8_t* bytes, size_t size) {
  Link link = Open();
  ClientInfo* client = new ClientInfo();
  client->mbDisconnectPending = false;
  client->mpSocketPending = link.client;
  strcpy(client->mName, "kat");
  send(link.peer, bytes, size, MSG_NOSIGNAL);
  shutdown(link.peer, SHUT_WR);

  bool ok = Client::Communications_Initialize(*client);
  CmdVersion answer;
  memset(static_cast<void*>(&answer), 0, sizeof(answer));
  ssize_t n = recv(link.peer, &answer, sizeof(answer), MSG_DONTWAIT);
  printf("%s: connected=%d coms=%d answer=%zd type=%d size=%u name=%s\n", name, ok ? 1 : 0,
         client->IsConnected() ? 1 : 0, n, static_cast<int>(answer.mType), answer.mSize,
         answer.mClientName);

  if (Network::SocketInfo* coms = client->mpSocketComs.exchange(nullptr)) Network::Disconnect(coms);
  close(link.peer);
  delete client;
}

int main() {
  g_listen = socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  socklen_t len = sizeof(addr);
  if (g_listen < 0 || bind(g_listen, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
      listen(g_listen, 16) != 0 ||
      getsockname(g_listen, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
    perror("loopback listener");
    return 1;
  }
  g_port = ntohs(addr.sin_port);

  SendInput("input whole", sizeof(CmdInput));
  SendInput("input bytewise", 1);

  CmdVersion good;
  Handshake("handshake good", reinterpret_cast<const uint8_t*>(&good), sizeof(good));
  CmdVersion wrong;
  wrong.mWCharSize = 8;
  Handshake("handshake wchar", reinterpret_cast<const uint8_t*>(&wrong), sizeof(wrong));
  Handshake("handshake short", reinterpret_cast<const uint8_t*>(&good), sizeof(CmdHeader));
  return 0;
}
