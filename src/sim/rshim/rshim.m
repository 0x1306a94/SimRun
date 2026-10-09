// rshim.dylib — SIM-platform dylib injected (DYLD_INSERT_LIBRARIES) into the sim process.
// Minimal, self-contained service plumbing for the rendering pipeline:
//  * com.apple.IOSurface.Remote / com.apple.metal.simulator (sim2host XPC services) -> listener ports passed by the
//    host (render/gpuhost.m) via mach_ports_register slots 1/2.
//  * com.apple.CARenderServer bootstrap name -> in-process CA render server port (bootstrap_check_in/look_up).
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <xpc/xpc.h>
#include <dlfcn.h>
#include <spawn.h>
#include <signal.h>
#include "gpuhost.h"

extern mach_port_t bootstrap_port;
kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *out);
kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *out);
kern_return_t bootstrap_register(mach_port_t bp, const char *name, mach_port_t port);
xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t);
void xpc_connection_enable_sim2host_4sim(xpc_connection_t);
// (marked unavailable in the iOS SDK headers; they exist in the sim libxpc)
extern xpc_connection_t sr_xpc_create_mach_service(const char *, dispatch_queue_t, uint64_t) __asm("_xpc_connection_create_mach_service");
extern xpc_connection_t sr_xpc_create_from_endpoint(xpc_endpoint_t) __asm("_xpc_connection_create_from_endpoint");

static mach_port_t gSlots[3];
static int gVerbose;
#define LOG(...) do { if (gVerbose) fprintf(stderr, "[rshim] " __VA_ARGS__); } while (0)

// ---------- sim2host XPC services ----------
static mach_port_t service_port(const char *name) {
  if (!name) return MACH_PORT_NULL;
  if (!strcmp(name, "com.apple.IOSurface.Remote")) return gSlots[SR_PORT_SLOT_IOSURFACE];
  if (!strcmp(name, "com.apple.metal.simulator")) return gSlots[SR_PORT_SLOT_METAL];
  return MACH_PORT_NULL;
}
static xpc_connection_t my_xpc_connection_create_mach_service(const char *name, dispatch_queue_t q, uint64_t flags) {
  mach_port_t p = service_port(name);
  if (p && !(flags & 1 /*XPC_CONNECTION_MACH_SERVICE_LISTENER*/)) {
    mach_port_mod_refs(mach_task_self(), p, MACH_PORT_RIGHT_SEND, 1);
    xpc_endpoint_t ep = xpc_endpoint_create_mach_port_4sim(p);
    xpc_connection_t c = sr_xpc_create_from_endpoint(ep);
    if (q) xpc_connection_set_target_queue(c, q);
    LOG("xpc service %s -> host listener port %#x (conn %p)\n", name, p, c);
    return c;
  }
  return sr_xpc_create_mach_service(name, q, flags);
}

// ---------- bundled XPC service com.apple.MTLCompilerService (sim Metal shader compiler) ----------
// Normally launchd_sim launches Metal.framework/XPCServices/MTLCompilerService.xpc on demand. We spawn it ourselves
// (once, lazily) with this dylib injected and RSHIM_ROLE=xpcservice: our xpc_main() replacement turns it into an
// anonymous listener and sends the listener port back through the child's TASK_BOOTSTRAP_PORT special port.
extern xpc_connection_t sr_xpc_connection_create(const char *, dispatch_queue_t) __asm("_xpc_connection_create");
extern void sr_xpc_main(void (*)(xpc_connection_t)) __asm("_xpc_main");
xpc_endpoint_t xpc_endpoint_create(xpc_connection_t);
mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
int posix_spawnattr_setspecialport_np(posix_spawnattr_t *, mach_port_t, int);
extern char **environ;
typedef struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t p; } port_msg_t;
typedef struct { port_msg_t m; mach_msg_trailer_t t; } port_rcv_t;

static mach_port_t spawn_xpc_service(const char *path) {
  mach_port_t rp; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rp);
  mach_port_insert_right(mach_task_self(), rp, rp, MACH_MSG_TYPE_MAKE_SEND);
  posix_spawnattr_t at; posix_spawnattr_init(&at);
  posix_spawnattr_setspecialport_np(&at, rp, TASK_BOOTSTRAP_PORT);
  int n = 0; while (environ[n]) n++;
  char **env = calloc(n + 6, sizeof(char *)); int k = 0;
  for (int i = 0; i < n; i++)
    if (strncmp(environ[i], "RSHIM_ROLE=", 11) && strncmp(environ[i], "RSHIM_PARENT=", 13) &&
        strncmp(environ[i], "XPC_FLAGS=", 10) && strncmp(environ[i], "XPC_SIMULATOR_LAUNCHD_NAME=", 27) &&
        strncmp(environ[i], "DYLD_INSERT_LIBRARIES=", 22)) env[k++] = environ[i];
  // the helper gets only rshim itself, not the app's other injected dylibs (glue/scenes/hid)
  static char ins[1100]; Dl_info di;
  if (dladdr((void *)spawn_xpc_service, &di) && di.dli_fname) { snprintf(ins, sizeof ins, "DYLD_INSERT_LIBRARIES=%s", di.dli_fname); env[k++] = ins; }
  // the child's TASK_BOOTSTRAP_PORT is our handshake port, NOT a launchd: force sim libxpc into null-bootstrap mode
  env[k++] = "XPC_FLAGS=0x2";
  env[k++] = "RSHIM_ROLE=xpcservice";
  char pp[32]; snprintf(pp, sizeof pp, "RSHIM_PARENT=%d", getpid()); env[k++] = pp;
  char *argv[] = { (char *)path, NULL }; pid_t pid;
  int r = posix_spawn(&pid, path, NULL, &at, argv, env);
  posix_spawnattr_destroy(&at); free(env);
  if (r) { fprintf(stderr, "[rshim] spawn %s: %s\n", path, strerror(r)); return MACH_PORT_NULL; }
  port_rcv_t m = {0};
  kern_return_t kr = mach_msg(&m.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, rp, 20000, MACH_PORT_NULL);
  mach_port_mod_refs(mach_task_self(), rp, MACH_PORT_RIGHT_RECEIVE, -1);
  mach_port_deallocate(mach_task_self(), rp);
  if (kr) { fprintf(stderr, "[rshim] no listener from %s (pid %d): %s\n", path, pid, mach_error_string(kr)); return MACH_PORT_NULL; }
  LOG("spawned %s pid %d -> listener %#x\n", path, pid, m.m.p.name);
  return m.m.p.name;
}
static mach_port_t gCompilerPort;
static xpc_connection_t my_xpc_connection_create(const char *name, dispatch_queue_t q) {
  if (name && !strcmp(name, "com.apple.MTLCompilerService") && !getenv("RSHIM_NO_COMPILER")) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      char path[1024]; snprintf(path, sizeof path, "%s/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService",
                                getenv("DYLD_ROOT_PATH") ?: "");
      gCompilerPort = spawn_xpc_service(path);
    });
    if (gCompilerPort) {
      mach_port_mod_refs(mach_task_self(), gCompilerPort, MACH_PORT_RIGHT_SEND, 1);
      xpc_connection_t c = sr_xpc_create_from_endpoint(xpc_endpoint_create_mach_port_4sim(gCompilerPort));
      if (q) xpc_connection_set_target_queue(c, q);
      LOG("xpc_connection_create(%s) -> compiler listener %#x\n", name, gCompilerPort);
      return c;
    }
  }
  return sr_xpc_connection_create(name, q);
}
// In the spawned service process: replacement for xpc_main(handler).
static void my_xpc_main(void (*handler)(xpc_connection_t)) {
  if (!getenv("RSHIM_ROLE")) { sr_xpc_main(handler); return; }
  xpc_connection_t l = sr_xpc_connection_create(NULL, NULL);
  xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) handler(peer);
  });
  xpc_connection_activate(l);
  mach_port_t lp = xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_create(l));
  mach_port_t parent = MACH_PORT_NULL; task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &parent);
  port_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX; m.h.msgh_size = sizeof m;
  m.h.msgh_remote_port = parent; m.b.msgh_descriptor_count = 1;
  m.p.name = lp; m.p.disposition = MACH_MSG_TYPE_COPY_SEND; m.p.type = MACH_MSG_PORT_DESCRIPTOR;
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 5000, 0);
  LOG("xpcservice %s: listener %#x sent to parent (%s)\n", getprogname(), lp, mach_error_string(kr));
  int ppid = getenv("RSHIM_PARENT") ? atoi(getenv("RSHIM_PARENT")) : getppid();
  dispatch_source_t ds = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, ppid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  dispatch_source_set_event_handler(ds, ^{ _exit(0); }); dispatch_resume(ds);
  if (kill(ppid, 0) != 0) _exit(0);
  dispatch_main();
}

// ---------- bootstrap names (CARenderServer only) ----------
static mach_port_t gCAServerPort;   // receive right checked in by CA::Render::Server::register_name
static int gRealBootstrap;          // a real namespace (launchd/simns) exists -> don't intercept CARenderServer
static kern_return_t my_bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *out) {
  if (name && !strcmp(name, "com.apple.CARenderServer") && !gRealBootstrap) {
    if (!gCAServerPort) {
      mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gCAServerPort);
      mach_port_insert_right(mach_task_self(), gCAServerPort, gCAServerPort, MACH_MSG_TYPE_MAKE_SEND);
    }
    *out = gCAServerPort; LOG("check_in %s -> %#x\n", name, gCAServerPort); return KERN_SUCCESS;
  }
  return bootstrap_check_in(bp, name, out);
}
static kern_return_t my_bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *out) {
  if (name && !strcmp(name, "com.apple.CARenderServer") && gCAServerPort) {
    mach_port_mod_refs(mach_task_self(), gCAServerPort, MACH_PORT_RIGHT_SEND, 1);
    *out = gCAServerPort; LOG("look_up %s -> %#x\n", name, gCAServerPort); return KERN_SUCCESS;
  }
  kern_return_t kr = bootstrap_look_up(bp, name, out);
  LOG("look_up %s -> kr=%#x\n", name, kr);
  return kr;
}

__attribute__((used, section("__DATA,__interpose"))) static struct { const void *n, *o; } interposers[] = {
  { (const void *)my_xpc_connection_create_mach_service, (const void *)sr_xpc_create_mach_service },
  { (const void *)my_bootstrap_check_in, (const void *)bootstrap_check_in },
  { (const void *)my_xpc_connection_create, (const void *)sr_xpc_connection_create },
  { (const void *)my_xpc_main, (const void *)sr_xpc_main },
  { (const void *)my_bootstrap_look_up, (const void *)bootstrap_look_up },
};

__attribute__((constructor)) static void rshim_init(void) {
  gVerbose = getenv("RSHIM_VERBOSE") != NULL;
  mach_port_array_t ports = NULL; mach_msg_type_number_t n = 0;
  if (mach_ports_lookup(mach_task_self(), &ports, &n) == KERN_SUCCESS)
    for (unsigned i = 0; i < n && i < 3; i++) gSlots[i] = ports[i];
  // CA (and others) only call bootstrap_* when bootstrap_port is "valid" (not 0/-1). Give it a dead name so
  // non-interposed lookups fail fast (MACH_SEND_INVALID_DEST) instead of hanging. Only if nobody set one.
  gRealBootstrap = bootstrap_port != MACH_PORT_NULL;
  if (bootstrap_port == MACH_PORT_NULL && !getenv("RSHIM_KEEP_BOOTSTRAP")) {
    mach_port_t p; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
    mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
    mach_port_mod_refs(mach_task_self(), p, MACH_PORT_RIGHT_RECEIVE, -1);   // -> dead name
    bootstrap_port = p;
  }
  LOG("loaded: slots iosurface=%#x metal=%#x bootstrap_port=%#x\n", gSlots[1], gSlots[2], bootstrap_port);
}
