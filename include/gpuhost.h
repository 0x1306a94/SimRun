// gpuhost: HOST-side (macOS) services that sim-platform IOSurface.framework and Metal (MTLSimDriver) need.
// Replaces CoreSimulator's SimRenderServer.xpc (IOSurfaceRemoteServer) and SimMetalHost.xpc (MTLSimImplementation).
// Each service is an anonymous XPC listener; its raw listener port is handed to the sim process
// (mach_ports_register slots, see below), where render/rshim.dylib turns it back into an xpc connection.
#pragma once
#include <mach/mach.h>
#define SR_PORT_SLOT_IOSURFACE 1   // mach_ports_register slot: com.apple.IOSurface.Remote listener port
#define SR_PORT_SLOT_METAL     2   // mach_ports_register slot: com.apple.metal.simulator listener port
// Starts both services in this (host) process. Returns send rights to the listener ports (0 on failure).
int srgpu_host_start(mach_port_t *iosurface_port, mach_port_t *metal_port);
