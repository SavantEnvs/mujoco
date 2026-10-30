/* Known-answer probe: drives the public MuJoCo API with fixed inputs and prints the results.
 * mayhem/test.sh compares this output to golden values, so a patch that breaks the physics, the
 * math library, the ray caster or the XML compiler (or that just makes the process exit(0)) fails. */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include <mujoco/mujoco.h>

static const char kFall[] =
    "<mujoco><option timestep='0.002' gravity='0 0 -9.81'/>"
    "<worldbody><body name='ball' pos='1 2 10'><freejoint/>"
    "<geom type='sphere' size='0.1' mass='1'/></body>"
    "<geom name='target' type='sphere' pos='3 0 0' size='0.5'/></worldbody></mujoco>";

/* Snap values within rounding noise of zero to +0 so the printed text is stable. */
static double clean(double x) { return fabs(x) < 1e-9 ? 0.0 : x; }

int main(void) {
  char err[256] = "";
  mjSpec* spec = mj_parseXMLString(kFall, NULL, err, sizeof(err));
  if (!spec) { printf("parse failed: %s\n", err); return 1; }
  mjModel* m = mj_compile(spec, NULL);
  if (!m) { printf("compile failed: %s\n", mjs_getError(spec)); return 1; }
  mjData* d = mj_makeData(m);

  printf("nq=%ld nv=%ld nbody=%ld ngeom=%ld\n", (long)m->nq, (long)m->nv, (long)m->nbody,
         (long)m->ngeom);

  for (int i = 0; i < 500; i++) mj_step(m, d);
  printf("time=%.3f\n", d->time);
  printf("x=%.3f y=%.3f z=%.3f\n", clean(d->qpos[0]), clean(d->qpos[1]), clean(d->qpos[2]));
  printf("vz=%.3f\n", clean(d->qvel[2]));

  mjtNum pnt[3] = {3, -5, 0}, vec[3] = {0, 1, 0};
  int geomid = -1;
  mjtNum dist = mj_ray(m, d, pnt, vec, NULL, 1, -1, &geomid, NULL);
  printf("ray dist=%.4f geom=%d\n", dist, geomid);

  mjtNum a[3] = {1, 2, 3}, b[3] = {4, -5, 6}, c[3];
  mju_cross(c, a, b);
  printf("dot=%.1f cross=%.1f,%.1f,%.1f norm=%.4f\n", mju_dot3(a, b), c[0], c[1], c[2], mju_norm3(a));

  mjtNum quat[4], axis[3] = {0, 0, 1}, v[3] = {1, 0, 0}, rot[3];
  mju_axisAngle2Quat(quat, axis, 3.14159265358979323846 / 2);
  mju_rotVecQuat(rot, v, quat);
  printf("rot=%.4f,%.4f,%.4f\n", clean(rot[0]), clean(rot[1]), clean(rot[2]));

  mj_deleteData(d);
  mj_deleteModel(m);
  mj_deleteSpec(spec);
  return 0;
}
