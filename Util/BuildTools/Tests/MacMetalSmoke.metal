#include <metal_stdlib>
using namespace metal;

kernel void carla_native_smoke(device uint *values [[buffer(0)]],
                              uint index [[thread_position_in_grid]]) {
  values[index] = index * 3 + 1;
}
