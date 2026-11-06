#import "MPVBridge.h"
#import <Foundation/Foundation.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <mpv/render_gl.h>

struct CRTVideoRenderer {
    CGLContextObj gl;
    mpv_render_context *mpv;
    CVPixelBufferPoolRef pool;
    int width, height;
};

static void *gl_address(void *context, const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

// The main run loop polls update at display cadence, even while the window is hidden.
static void render_updated(void *context) {}

CRTVideoRenderer *crt_video_create(mpv_handle *player, int *error) {
    *error = MPV_ERROR_GENERIC;
    CRTVideoRenderer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, 0
    };
    CGLPixelFormatObj format = NULL;
    GLint count = 0;
    CGLError status = CGLChoosePixelFormat(attrs, &format, &count);
    if (status == kCGLNoError && format) status = CGLCreateContext(format, NULL, &r->gl);
    if (format) CGLReleasePixelFormat(format);
    if (status != kCGLNoError || !r->gl) {
        free(r);
        return NULL;
    }
    CGLContextObj previous = CGLGetCurrentContext();
    CGLSetCurrentContext(r->gl);
    mpv_opengl_init_params gl = { .get_proc_address = gl_address };
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    *error = mpv_render_context_create(&r->mpv, player, params);
    if (*error >= 0) mpv_render_context_set_update_callback(r->mpv, render_updated, NULL);
    CGLSetCurrentContext(previous);
    if (*error < 0) {
        crt_video_free(r);
        return NULL;
    }
    return r;
}

CVPixelBufferRef crt_video_draw(CRTVideoRenderer *r, int width, int height, int *error) {
    *error = 0;
    CGLContextObj previous = CGLGetCurrentContext();
    CGLSetCurrentContext(r->gl);
    CVPixelBufferRef buffer = NULL;
    GLuint texture = 0, framebuffer = 0;
    if (!(mpv_render_context_update(r->mpv) & MPV_RENDER_UPDATE_FRAME)) goto done;
    if (!r->pool || r->width != width || r->height != height) {
        if (r->pool) CVPixelBufferPoolRelease(r->pool);
        r->pool = NULL;
        NSDictionary *attrs = @{
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferOpenGLCompatibilityKey: @YES
        };
        if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &r->pool)
            != kCVReturnSuccess) goto fail;
        r->width = width;
        r->height = height;
    }
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, r->pool, &buffer) != kCVReturnSuccess) goto fail;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_RECTANGLE, texture);
    if (CGLTexImageIOSurface2D(r->gl, GL_TEXTURE_RECTANGLE, GL_RGBA8, width, height,
                              GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
                              CVPixelBufferGetIOSurface(buffer), 0) != kCGLNoError) goto fail;
    glBindTexture(GL_TEXTURE_RECTANGLE, 0);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) goto fail;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    mpv_opengl_fbo fbo = { (int)framebuffer, width, height, GL_RGBA8 };
    int flip = 0, block = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    *error = mpv_render_context_render(r->mpv, params);
    // Complete writes to the shared IOSurface before Metal samples it. The pool
    // only recycles a buffer after both the model and Metal have released it.
    glFinish();
    if (*error < 0) goto fail;
    mpv_render_context_report_swap(r->mpv);
    goto done;
fail:
    if (*error >= 0) *error = MPV_ERROR_GENERIC;
    if (buffer) CVPixelBufferRelease(buffer);
    buffer = NULL;
done:
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
    if (texture) glDeleteTextures(1, &texture);
    CGLSetCurrentContext(previous);
    return buffer;
}

void crt_video_free(CRTVideoRenderer *r) {
    if (!r) return;
    CGLContextObj previous = CGLGetCurrentContext();
    CGLSetCurrentContext(r->gl);
    if (r->mpv) mpv_render_context_free(r->mpv);
    CGLSetCurrentContext(previous);
    if (r->pool) CVPixelBufferPoolRelease(r->pool);
    if (r->gl) CGLReleaseContext(r->gl);
    free(r);
}
