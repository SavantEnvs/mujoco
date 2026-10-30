// Fuzz MuJoCo's MJCF/URDF front end: XML parse -> mjSpec -> compile -> a few physics steps -> MJCF
// writer -> re-parse of the written XML.
#include <cstdlib>

#include "harness_common.h"

extern "C" int LLVMFuzzerInitialize(int*, char***) {
  QuietLogs();
  return 0;
}

// A model can name other files (include/mesh/texture/...). The model lives under kSandbox in the VFS
// and a provider that opens nothing is mounted on that directory, so every relative reference the
// model makes (including meshdir/texturedir/include dir) fails inside the library instead of reading
// the process's working directory. Absolute paths are not covered: they resolve against the image's
// read-only file system, which is the same for every input.
static const char kSandbox[] = "sbx";
static const char kModelPath[] = "sbx/model.xml";

static int DenyOpen(mjResource*) { return 0; }
static int DenyRead(mjResource*, const void**) { return -1; }
static void DenyClose(mjResource*) {}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size == 0 || size > (1 << 16)) return -1;

  mjVFS vfs;
  mj_defaultVFS(&vfs);
  mjpResourceProvider deny;
  mjp_defaultProvider(&deny);
  deny.open = DenyOpen;
  deny.read = DenyRead;
  deny.close = DenyClose;
  char err[512] = "";
  if (mj_mountVFS(&vfs, kSandbox, &deny) != 0 ||
      mj_addBufferVFS(&vfs, kModelPath, data, (int)size) != 0) {
    mj_deleteVFS(&vfs);
    return -1;
  }

  int rc = -1;
  mjSpec* spec = mj_parse(kModelPath, nullptr, &vfs, err, sizeof(err));
  if (spec) {
    mjModel* m = mj_compile(spec, &vfs);
    if (m) {
      rc = 0;
      static char xml[1 << 17];
      if (mj_saveXMLString(spec, xml, sizeof(xml), err, sizeof(err)) == 0) {
        mjSpec* again = mj_parseXMLString(xml, nullptr, err, sizeof(err));
        if (again) mj_deleteSpec(again);
      }
      ExerciseAndDelete(m);
    }
    mj_deleteSpec(spec);
  }
  mj_deleteVFS(&vfs);
  return rc;
}
