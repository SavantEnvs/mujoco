// Known-answer test for NetImgui's draw-frame delta codec: hand-built frames go through
// CompressCmdDrawFrame() and DecompressCmdDrawFrame(); the program prints the size of each compressed
// frame and every decompressed element. mayhem/test.sh compares that output with the expected lines.
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "Private/NetImgui_CmdPackets.h"

using namespace NetImgui::Internal;

static uint64_t Elem(uint32_t stream, uint32_t i, int variant) {
  uint64_t v = 0x1111000000000000ull * (stream + 1) + i;
  if (variant == 1 && i % 3 == 1) v ^= 0x5000;
  if (variant == 2) v ^= 0x77;
  return v;
}

static size_t Elems(size_t bytes) { return (bytes + ComDataSize - 1) / ComDataSize; }

// An uncompressed frame with one draw group; its 3 streams are filled from Elem().
static CmdDrawFrame* MakeFrame(uint64_t groupID, uint32_t indiceCount, uint32_t verticeCount,
                               uint32_t drawCount, int variant) {
  const size_t counts[3] = {Elems(indiceCount * 2u), Elems(verticeCount * sizeof(ImguiVert)),
                            Elems(drawCount * sizeof(ImguiDraw))};
  const size_t total = sizeof(CmdDrawFrame) / ComDataSize + sizeof(ImguiDrawGroup) / ComDataSize +
                       counts[0] + counts[1] + counts[2];
  CmdDrawFrame* frame = netImguiSizedNew<CmdDrawFrame>(total * ComDataSize);
  frame->mDrawGroupCount = 1;
  frame->mTotalIndiceCount = indiceCount;
  frame->mTotalVerticeCount = verticeCount;
  frame->mTotalDrawCount = drawCount;
  frame->mSize = frame->mUncompressedSize = static_cast<uint32_t>(total * ComDataSize);
  ComDataType* out = reinterpret_cast<ComDataType*>(&frame[1]);
  frame->mpDrawGroups.SetComDataPtr(out);
  ImguiDrawGroup* group = new (out) ImguiDrawGroup();
  group->mGroupID = groupID;
  group->mIndiceCount = indiceCount;
  group->mVerticeCount = verticeCount;
  group->mDrawCount = drawCount;
  out += sizeof(ImguiDrawGroup) / ComDataSize;
  group->mpIndices.SetComDataPtr(out);
  group->mpVertices.SetComDataPtr(out + counts[0]);
  group->mpDraws.SetComDataPtr(out + counts[0] + counts[1]);
  for (uint32_t s = 0; s < 3; s++) {
    for (size_t i = 0; i < counts[s]; i++) *out++ = Elem(s, static_cast<uint32_t>(i), variant);
  }
  return frame;
}

static void Dump(const char* name, const ComDataType* data, size_t elems) {
  printf("%s:", name);
  for (size_t i = 0; i < elems; i++) printf(" %016llx", static_cast<unsigned long long>(data[i]));
  printf("\n");
}

static int Case(const char* name, const CmdDrawFrame* prev, const CmdDrawFrame* next) {
  CmdDrawFrame* packed = CompressCmdDrawFrame(prev, next);
  CmdDrawFrame* got = DecompressCmdDrawFrame(prev, packed);
  if (!got) {
    printf("%s decompress failed\n", name);
    netImguiDeleteSafe(packed);
    return 1;
  }
  const ImguiDrawGroup& want = next->mpDrawGroups[0];
  const ImguiDrawGroup& have = got->mpDrawGroups[0];
  const size_t n[3] = {Elems(want.mIndiceCount * 2u), Elems(want.mVerticeCount * sizeof(ImguiVert)),
                       Elems(want.mDrawCount * sizeof(ImguiDraw))};
  printf("%s packed_bytes=%u\n", name, packed->mSize);
  Dump("indices", have.mpIndices.GetComData(), n[0]);
  Dump("vertices", have.mpVertices.GetComData(), n[1]);
  Dump("draws", have.mpDraws.GetComData(), n[2]);
  const bool same =
      !memcmp(have.mpIndices.GetComData(), want.mpIndices.GetComData(), n[0] * ComDataSize) &&
      !memcmp(have.mpVertices.GetComData(), want.mpVertices.GetComData(), n[1] * ComDataSize) &&
      !memcmp(have.mpDraws.GetComData(), want.mpDraws.GetComData(), n[2] * ComDataSize);
  printf("%s roundtrip=%s\n", name, same ? "same" : "different");
  netImguiDeleteSafe(packed);
  netImguiDeleteSafe(got);
  return same ? 0 : 1;
}

int main() {
  int bad = 0;
  CmdDrawFrame* a = MakeFrame(7, 12, 4, 2, 0);
  CmdDrawFrame* same = MakeFrame(7, 12, 4, 2, 0);
  CmdDrawFrame* edited = MakeFrame(7, 12, 4, 2, 1);
  CmdDrawFrame* grown = MakeFrame(7, 20, 7, 3, 2);
  CmdDrawFrame* shrunk = MakeFrame(7, 4, 1, 1, 1);
  CmdDrawFrame* other = MakeFrame(9, 12, 4, 2, 2);
  bad += Case("unchanged", a, same);
  bad += Case("edited", a, edited);
  bad += Case("grown", a, grown);
  bad += Case("shrunk", a, shrunk);
  bad += Case("newgroup", a, other);
  netImguiDeleteSafe(a);
  netImguiDeleteSafe(same);
  netImguiDeleteSafe(edited);
  netImguiDeleteSafe(grown);
  netImguiDeleteSafe(shrunk);
  netImguiDeleteSafe(other);
  return bad;
}
