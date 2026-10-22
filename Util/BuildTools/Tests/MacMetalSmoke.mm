#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 2) {
      std::fprintf(stderr, "Usage: metal-smoke /absolute/path/to/smoke.metallib\n");
      return 2;
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
      std::fprintf(stderr, "No native Metal device is available\n");
      return 1;
    }
    NSError *error = nil;
    NSURL *library_url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    id<MTLLibrary> library = [device newLibraryWithURL:library_url error:&error];
    id<MTLFunction> function = [library newFunctionWithName:@"carla_native_smoke"];
    id<MTLComputePipelineState> pipeline = function == nil ? nil :
        [device newComputePipelineStateWithFunction:function error:&error];
    if (pipeline == nil) {
      std::fprintf(stderr, "Metal pipeline failed: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }
    id<MTLBuffer> buffer = [device newBufferWithLength:64 * sizeof(uint32_t)
                                            options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> command_queue = [device newCommandQueue];
    id<MTLCommandBuffer> command_buffer = [command_queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command_buffer computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(64, 1, 1)
       threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [encoder endEncoding];
    [command_buffer commit];
    [command_buffer waitUntilCompleted];
    if (command_buffer.status != MTLCommandBufferStatusCompleted) {
      std::fprintf(stderr, "Metal command failed: %s\n", command_buffer.error.localizedDescription.UTF8String);
      return 1;
    }
    const auto *values = static_cast<const uint32_t *>(buffer.contents);
    for (uint32_t index = 0; index < 64; ++index) {
      if (values[index] != index * 3 + 1) {
        std::fprintf(stderr, "Metal readback mismatch at %u\n", index);
        return 1;
      }
    }
    std::printf("Native Metal compile, GPU dispatch and shared-buffer readback passed: %s\n",
                device.name.UTF8String);
  }
  return 0;
}
