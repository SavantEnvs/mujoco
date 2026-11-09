// Fuzz NetImgui's delta-compressed draw frames, as a receiver sees them on the wire: the NetImgui
// server app (NetImguiServer_Network.cpp / RemoteClient.cpp) and the MuJoCo web viewer
// (studio/web/web_client_remote_ui.cc) both read a command from the network, validate it with
// CmdDrawFrame::ToPointers(), and hand a compressed frame, with the previous frame they kept, to
// DecompressCmdDrawFrame().
//
// The input is the received byte stream: the previous draw frame command, then the delta-compressed one.
// Each starts with its CmdHeader, whose mSize says how many bytes the command takes.
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>

#include "Private/NetImgui_CmdPackets.h"

using namespace NetImgui::Internal;

// CmdDrawFrame::ToPointers() returns whether the command is valid since the offsets/sizes validation
// fix; before it, it returns void and converts whatever offsets the command holds.
template <typename TCmd>
static bool ToPointersValid(TCmd* cmd) {
  if constexpr (std::is_void_v<decltype(cmd->ToPointers())>) {
    cmd->ToPointers();
    return true;
  } else {
    return cmd->ToPointers();
  }
}

// One command off the stream, the way the receive loops get it: PendingCom::IsBiggerBufferNeeded()
// rejects a size under the header or over kMaxCmdSize, the command lands in an mSize byte buffer, is
// dispatched on its type, and a DrawFrame is dropped when ToPointers() is false (where it can tell).
static CmdDrawFrame* ReceiveDrawFrame(const uint8_t*& pos, const uint8_t* end) {
  if (static_cast<size_t>(end - pos) < sizeof(CmdHeader)) return nullptr;
  uint32_t cmdSize;
  memcpy(&cmdSize, pos, sizeof(cmdSize));
  const uint8_t cmdType = pos[offsetof(CmdHeader, mType)];
  if (cmdSize < sizeof(CmdHeader) || cmdSize > PendingCom::kMaxCmdSize ||
      cmdSize > static_cast<size_t>(end - pos) ||
      cmdType != static_cast<uint8_t>(CmdHeader::eCommands::DrawFrame)) {
    return nullptr;
  }
  CmdDrawFrame* cmd = reinterpret_cast<CmdDrawFrame*>(netImguiSizedNew<uint8_t>(cmdSize));
  memcpy(static_cast<void*>(cmd), pos, cmdSize);
  pos += cmdSize;
  if (!ToPointersValid(cmd)) {
    netImguiDeleteSafe(cmd);
    return nullptr;
  }
  return cmd;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  const uint8_t* pos = data;
  const uint8_t* end = data + size;
  CmdDrawFrame* prev = ReceiveDrawFrame(pos, end);
  if (!prev) return -1;
  CmdDrawFrame* packed = ReceiveDrawFrame(pos, end);
  if (!packed) {
    netImguiDeleteSafe(prev);
    return -1;
  }
  // Client::ReceiveDrawFrame() / RemoteUi::ProcessCmdDrawFrame() only decompress a compressed frame
  // that directly follows the (uncompressed) frame they kept; otherwise they ask for a keyframe.
  if (prev->mCompressed || !packed->mCompressed || prev->mFrameIndex + 1 != packed->mFrameIndex) {
    netImguiDeleteSafe(prev);
    netImguiDeleteSafe(packed);
    return -1;
  }
  CmdDrawFrame* frame = DecompressCmdDrawFrame(prev, packed);
  netImguiDeleteSafe(packed);
  netImguiDeleteSafe(prev);
  netImguiDeleteSafe(frame);
  return 0;
}
