# simns — launchd_sim replacement

## How a sim process finds launchd (verified)
- Sim libxpc `_libxpc_initializer` does NOT look up XPC_SIMULATOR_LAUNCHD_NAME; it only requires it to be set.
  Null-bootstrap mode (bootstrap_port = 0, everything fails with 0x10000003) is chosen if the env var is missing
  OR XPC_FLAGS has bit 0x2/0x80. Sim posix_spawn adds `XPC_FLAGS=0x2` when the parent is in null mode -> the launcher
  must pass `XPC_FLAGS=0x0` explicitly.
- Otherwise bootstrap_port = the task's TASK_BOOTSTRAP_PORT special port. So: posix_spawnattr_setspecialport_np(ns, TASK_BOOTSTRAP_PORT).

## Wire protocol (sim libxpc XPC pipe)
request msgh_id = 0x40000000|routine (wants reply) or 0x10000000|routine; body = serialized xpc dictionary; reply port = send-once in remote.
To decode with sim libxpc: reset msgh_id to the bare type (xpc_receive_mach_msg_validate_hdr rejects routine bits), include the audit
trailer in the dispatch_mach_msg (decoder reads it), then xpc_receive_mach_msg(); reply with xpc_dictionary_create_reply + xpc_pipe_routine_reply.
| routine | client API | request | reply | not found |
|---|---|---|---|---|
| 204 | bootstrap_register2 | name, port(send), flags | error 0 | |
| 206 | bootstrap_check_in3 | name, flags | port(recv), instance | |
| 207 | bootstrap_look_up3 | name, targetpid, instance, flags | port(send) | error 1102 |
| 804 | xpc_connection_create_mach_service (libxpc internal) | name, type, handle, lookup-handle, flags | port(send), non-launching | error 3 |
| 805 | XPC mach-service listener | name, type 6 | port(recv) | |
sim2host services (xpc_connection_enable_sim2host_4sim) are normal 804 lookups; the flag only changes message encoding.
Real launchd_sim publishes host-side ports (com.apple.IOSurface.Remote, com.apple.metal.simulator, com.apple.CoreSimulator.SimFramebufferServer,
IndigoHIDRegistrationPort, coreaudiod, configd, FSEvents, ...) registered by CoreSimulator.

## Usage
    ./simrun.sh launchd/simns <app> [args]          # (SIMRUN_INSERT must be unset; use SIMNS_INSERT for the app's dylib)
Env: SIMNS_INSERT, SIMNS_LOG=file, SIMNS_QUIET=1, SIMNS_HOST_SLOT=n (send SIMNS_MSG_HELLO{control port} to mach_ports_lookup()[n],
wait SIMNS_HOST_WAIT ms for SIMNS_MSG_READY). Control messages: simns_proto.h (SIMNS_MSG_REGISTER {name, send right, flags}).
The control port is also registered as `dev.simrun.simns.control` so an in-app shim can bootstrap_look_up it and register in-process services.

## Inventory: Hello.app (UIKit, scene-based) until first fatal error
| service | kind | handling |
|---|---|---|
| com.apple.logd, com.apple.diagnosticd | lookup / endpoint (diagnosticd repeated) | ignore |
| com.apple.system.notification_center | lookup | ignore for now (notify_* fail softly); could run sim notifyd |
| com.apple.cfprefsd.daemon | endpoint | optional: spawn sim $R/usr/sbin/cfprefsd under simns; else prefs not persisted |
| com.apple.runningboard | endpoint | needed? (scenes workstream) |
| com.apple.backboard.display.services | lookup (MIG) | FATAL: BKSDisplayServicesStart -> must implement/stub |
| routine 904 (empty dict) | ? | replied ENOTSUP, harmless so far |

## On-demand sim daemons
simns reads $SIMULATOR_ROOT/System/Library/{LaunchDaemons,LaunchAgents}/*.plist. For allow-listed labels
(env SIMNS_DAEMONS, comma-separated; default com.apple.trustd,com.apple.securityd,com.apple.cfprefsd.xpc.daemon,
com.apple.cfprefsd.xpc.agent; "none" disables) the first lookup of any of the daemon's MachServices pre-creates its ports
(lookups succeed immediately, messages queue), then spawns the daemon (ProgramArguments rebased into the runtime root,
plist EnvironmentVariables, XPC_SERVICE_NAME=label, simns as bootstrap). Check-in hands it the queued receive rights.
Dead daemons are relaunched on the next lookup; all are SIGTERMed when the app exits or simns is terminated.
Why: without trustd, every TLS handshake fails (-9808 errSSLBadCert / NSURLErrorDomain -1202). Plain BSD sockets and
getaddrinfo work without any daemon. notifyd is NOT allow-listed: it needs XPC event-publisher routines simns lacks
(aborts "Event publisher error").

## Shared server mode (simns --serve)
Used by simrund. simns spawns no app; the host sends SIMNS_MSG_NEW_NS (reply port in msgh_local_port) and gets back
SIMNS_MSG_NS_REPLY carrying a send right to a fresh per-app namespace port, which it passes to the app as its
TASK_BOOTSTRAP_PORT. Requests are resolved by the port they arrive on: the app's namespace first, then the global
one (daemons, host services, control port). Registrations/check-ins made through an app namespace stay private to it
(e.g. each app's in-process com.apple.CARenderServer). Daemons are spawned on the global port, so they are shared.
simns asks for a no-senders notification on each namespace port and frees it when the app and host have dropped
their send rights. simns exits (stopping its daemons) when its parent, simrund, goes away. Daemons that ignore
SIGTERM are SIGKILLed after 1 s.
