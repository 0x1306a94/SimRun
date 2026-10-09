// simns_proto.h — wire protocol of the SimRun namespace server ("simns") for messages that are NOT
// launchd/XPC-pipe messages. Plain Mach messages, usable from host (macOS) and sim code alike.
//
// The namespace port (= the sim process' TASK_BOOTSTRAP_PORT, called NS below) accepts:
//   * launchd XPC-pipe requests from sim libxpc (msgh_id 0x40000000|routine, 0x10000000|routine)
//   * the SIMNS_MSG_* control messages defined here.
#pragma once
#include <mach/mach.h>
#include <stdint.h>

#define SIMNS_NAME_MAX 128

enum {
  SIMNS_MSG_BASE = 0x534e5300,        // 'SNS\0'
  SIMNS_MSG_REGISTER,                 // simns_register_msg_t, optional reply (simns_reply_t) if msgh_local_port set
  SIMNS_MSG_DECLARE,                  // simns_name_msg_t: create port now (receive right kept by server until check-in)
  SIMNS_MSG_UNREGISTER,               // simns_name_msg_t
  SIMNS_MSG_SET_FALLBACK,             // simns_port_msg_t: port receives SIMNS_MSG_FALLBACK_REQ for unknown names
  SIMNS_MSG_FALLBACK_REQ,             // simns_name_msg_t sent BY the server, expects simns_fallback_reply_t
  SIMNS_MSG_FALLBACK_REPLY,           // simns_fallback_reply_t
  SIMNS_MSG_HELLO,                    // simns_port_msg_t sent BY the launcher to the host helper: port = send right to NS
  SIMNS_MSG_READY,                    // header only, host -> NS: "host-side registrations done, start the app"
  SIMNS_MSG_REPLY,                    // simns_reply_t
  SIMNS_MSG_DUMP,                     // header only: server prints its registry to its log
  SIMNS_MSG_NEW_NS,                   // header only, reply port in msgh_local_port: create a per-app namespace
  SIMNS_MSG_NS_REPLY,                 // simns_port_msg_t: port = send right to the new namespace (use as TASK_BOOTSTRAP_PORT).
                                      // The namespace layers over the global one and is destroyed when its last send right goes.
};

// flags for SIMNS_MSG_REGISTER
enum {
  SIMNS_F_HOST_SIDE = 1u << 0,        // informational: port is served by a host (macOS) process (sim2host XPC service)
  SIMNS_F_REPLACE   = 1u << 1,        // replace an existing entry (default: replace as well; kept for clarity)
};

typedef struct {
  mach_msg_header_t h;
  mach_msg_body_t b;
  mach_msg_port_descriptor_t port;     // send right (COPY_SEND / MOVE_SEND / MAKE_SEND)
  uint32_t flags;
  char name[SIMNS_NAME_MAX];
} simns_register_msg_t;

typedef struct {
  mach_msg_header_t h;
  mach_msg_body_t b;
  mach_msg_port_descriptor_t port;
  uint32_t flags;
} simns_port_msg_t;

typedef struct {
  mach_msg_header_t h;
  uint32_t flags;
  char name[SIMNS_NAME_MAX];
} simns_name_msg_t;

typedef struct {
  mach_msg_header_t h;
  mach_msg_body_t b;
  mach_msg_port_descriptor_t port;     // MACH_PORT_NULL = "don't know it"
  uint32_t flags;                      // SIMNS_F_HOST_SIDE ...
} simns_fallback_reply_t;

typedef struct {
  mach_msg_header_t h;
  int32_t result;                      // 0 or errno-ish
} simns_reply_t;

// Launcher environment (see LAUNCHD.md):
//   SIMNS_INSERT        DYLD_INSERT_LIBRARIES for the app only
//   SIMNS_HOST_SLOT     n: mach_ports_lookup() slot holding the host helper's port; the launcher sends it
//                        SIMNS_MSG_HELLO and waits (SIMNS_HOST_WAIT ms, default 5000) for SIMNS_MSG_READY
//   SIMNS_LOG           path: also append the log there
//   SIMNS_QUIET         1: don't log to stderr
//   SIMNS_PRELOAD       "name1,name2": declare these names up front (lookups succeed, messages queue until check-in)
