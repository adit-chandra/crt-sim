#pragma once
#include <CoreVideo/CoreVideo.h>
#include <mpv/client.h>

typedef struct CRTVideoRenderer CRTVideoRenderer;

// All calls must be serialized. Free the renderer before destroying its mpv handle.
CRTVideoRenderer *crt_video_create(mpv_handle *player, int *error);
CVPixelBufferRef crt_video_draw(CRTVideoRenderer *renderer, int width, int height,
                               int *error) CF_RETURNS_RETAINED;
void crt_video_free(CRTVideoRenderer *renderer);
