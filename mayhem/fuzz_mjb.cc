// Fuzz the binary model (MJB) loader: header/size validation, buffer slicing, and the copy/save paths
// that walk the loaded model.
#include <cstdlib>

#include "harness_common.h"

extern "C" int LLVMFuzzerInitialize(int*, char***) {
  QuietLogs();
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size == 0 || size > (1 << 20)) return -1;
  // The loader reads typed fields from the buffer: hand it a malloc-aligned private copy.
  void* buf = malloc(size);
  memcpy(buf, data, size);
  mjModel* m = mj_loadModelBuffer(buf, (mjtSize)size);
  free(buf);
  if (!m) return -1;

  mjModel* copy = mj_copyModel(nullptr, m);
  if (copy) {
    mjtSize n = mj_sizeModel(copy);
    if (n > 0 && n < (1 << 24)) {
      void* out = malloc((size_t)n);
      mj_saveModel(copy, nullptr, out, n);
      free(out);
    }
    mj_deleteModel(copy);
  }
  mj_deleteModel(m);
  return 0;
}
