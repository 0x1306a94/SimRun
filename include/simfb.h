// Public in-process API of the fake SimFramebuffer (render/SimFramebuffer, sim platform).
#pragma once
#include <IOSurface/IOSurfaceRef.h>
#include <dispatch/dispatch.h>
#include <stdint.h>
// Called once per presented frame with the IOSurface CA just rendered into (CA's framebuffer: BGRA 8888,
// canvas size, e.g. 1206x2622; CA may reuse the same surface for the next frame and only redraw dirty regions).
// seq increases monotonically.
typedef void (^SimRunFBFrameHandler)(IOSurfaceRef surface, uint64_t seq);
// q == NULL: handler runs SYNCHRONOUSLY on CA's display-server thread inside SFBSwapchainSwapSubmit, so the surface
//            content is stable for the duration of the call (copy/blit it there; keep it fast, it stalls rendering).
// q != NULL: handler runs async on q (surface retained, but CA may already be drawing the next frame into it).
// Resolve with dlsym(dlopen(getenv("SIMULATOR_FRAMEBUFFER_FRAMEWORK"), RTLD_NOW), "SimRunFBSetFrameHandler").
void SimRunFBSetFrameHandler(dispatch_queue_t q, SimRunFBFrameHandler handler);
// How many frames have been presented so far (any thread). It stays put while nothing on screen changes, which is how
// script.dylib tells that the UI has settled.
uint64_t SimRunFBFrameCount(void);
