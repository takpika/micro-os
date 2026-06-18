#include "detection/opengl/opengl.h"

const char* ffDetectOpenGL(FFOpenGLOptions* options, FFOpenGLResult* result)
{
    (void)options;
    (void)result;
    return "OpenGL detection is not supported on microOS";
}
