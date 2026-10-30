// Shared helpers for the MuJoCo libFuzzer harnesses. Harnesses take bytes only from the fuzzer and
// hand them to MuJoCo through its in-memory virtual file system, so no harness touches the disk.
#ifndef MAYHEM_HARNESS_COMMON_H_
#define MAYHEM_HARNESS_COMMON_H_

#include <mujoco/mujoco.h>

#include <cstddef>
#include <cstdint>
#include <cstring>

// MuJoCo's default log handler appends to ./MUJOCO_LOG.TXT and prints to stderr; both are noise
// (and a file write) in a fuzz loop. The process-wide asset cache would otherwise keep every
// compiled mesh/texture alive across executions and grow the fuzzer's RSS until it is killed.
static inline void QuietLogs() {
  mjLogConfig cfg = mju_getLogConfig();
  cfg.logto_console = 0;
  cfg.logto_file = 0;
  mju_setLogConfig(cfg);
  mj_setCacheCapacity(mj_getCache(), 0);
}

// Run a compiled model through the physics pipeline, bounded so one input cannot spend seconds in
// a step loop, then free it.
static inline void ExerciseAndDelete(mjModel* m) {
  if (!m) return;
  if (mj_sizeModel(m) < (1 << 24) && m->narena < (1 << 24) && m->nv <= 256 && m->ngeom <= 512 &&
      m->nbody <= 512) {
    mjData* d = mj_makeData(m);
    if (d) {
      for (int i = 0; i < 3; i++) mj_step(m, d);
      mj_forward(m, d);
      mj_deleteData(d);
    }
  }
  mj_deleteModel(m);
}

#endif  // MAYHEM_HARNESS_COMMON_H_
