// Fuzz MuJoCo's asset decoders. The input is the raw asset file; a fixed model that references it
// is compiled, so the decoder, mesh/texture/heightfield post-processing (convex hull, inertia,
// normals) and the first physics steps all see fuzzer-controlled data. One source, built once per
// format with -DASSET_KIND=<n>: 1 OBJ mesh, 2 STL mesh, 3 GMSH mesh, 4 PNG (texture or hfield),
// 5 MJZ archive.
#include <cstdio>
#include <string>

#include "harness_common.h"

#ifndef ASSET_KIND
#error "build with -DASSET_KIND=1..5"
#endif

extern "C" int LLVMFuzzerInitialize(int*, char***) {
  QuietLogs();
  return 0;
}

static const char kMeshModel[] =
    "<mujoco><asset><mesh name='m' file='asset.%s'/></asset><worldbody>"
    "<geom type='plane' size='5 5 .1'/>"
    "<body pos='0 0 1'><freejoint/><geom type='mesh' mesh='m'/></body></worldbody></mujoco>";
static const char kTextureModel[] =
    "<mujoco><asset><texture name='t' type='2d' file='asset.png'/>"
    "<material name='mat' texture='t'/></asset><worldbody>"
    "<geom type='plane' size='5 5 .1' material='mat'/></worldbody></mujoco>";
static const char kHfieldModel[] =
    "<mujoco><asset><hfield name='h' file='asset.png' size='1 1 1 .1'/></asset><worldbody>"
    "<geom type='hfield' hfield='h'/>"
    "<body pos='0 0 2'><freejoint/><geom type='sphere' size='.1'/></body></worldbody></mujoco>";

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size == 0 || size > (1 << 18)) return -1;

  mjVFS vfs;
  mj_defaultVFS(&vfs);
  char err[512] = "";
  mjSpec* spec = nullptr;
  mjModel* m = nullptr;

#if ASSET_KIND == 5
  if (mj_addBufferVFS(&vfs, "model.mjz", data, (int)size) == 0) {
    spec = mj_parse("model.mjz", nullptr, &vfs, err, sizeof(err));
    if (spec) m = mj_compile(spec, &vfs);
  }
#else
  char xml[1024];
  const char* name;
  const uint8_t* payload = data;
  size_t payload_size = size;
#if ASSET_KIND == 1
  name = "asset.obj";
  snprintf(xml, sizeof(xml), kMeshModel, "obj");
#elif ASSET_KIND == 2
  name = "asset.stl";
  snprintf(xml, sizeof(xml), kMeshModel, "stl");
#elif ASSET_KIND == 3
  name = "asset.msh";
  snprintf(xml, sizeof(xml), kMeshModel, "msh");
#else
  // First byte picks the consumer; the rest is the PNG.
  name = "asset.png";
  snprintf(xml, sizeof(xml), "%s", (data[0] & 1) ? kHfieldModel : kTextureModel);
  payload = data + 1;
  payload_size = size - 1;
  if (payload_size == 0) {
    mj_deleteVFS(&vfs);
    return -1;
  }
#endif
  if (mj_addBufferVFS(&vfs, name, payload, (int)payload_size) == 0 &&
      mj_addBufferVFS(&vfs, "model.xml", xml, (int)strlen(xml)) == 0) {
    spec = mj_parse("model.xml", nullptr, &vfs, err, sizeof(err));
    if (spec) m = mj_compile(spec, &vfs);
  }
#endif

  int rc = m ? 0 : -1;
  ExerciseAndDelete(m);
  if (spec) mj_deleteSpec(spec);
  mj_deleteVFS(&vfs);
  return rc;
}
