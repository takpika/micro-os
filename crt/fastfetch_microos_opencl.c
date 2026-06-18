#include "detection/gpu/gpu.h"
#include "detection/opencl/opencl.h"

FFOpenCLResult* ffDetectOpenCL(void)
{
  static FFOpenCLResult result;

  if (result.gpus.elementSize == 0) {
    ffStrbufInit(&result.version);
    ffStrbufInit(&result.name);
    ffStrbufInit(&result.vendor);
    ffListInit(&result.gpus, sizeof(FFGPUResult));
    result.error = "OpenCL detection is not supported on microOS";
  }

  return &result;
}
