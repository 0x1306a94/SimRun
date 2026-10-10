// simrund_proto.h — client (simapp) <-> server (simrund) protocol over a Unix-domain socket. Host (macOS) code only.
//
// Every message is a uint32 length (host byte order) followed by a binary property list (a dictionary).
//   client -> server  request  { argv: [string], env: [string], cwd: string, title: string }
//                     The first message carries the client's stdin/stdout/stderr as SCM_RIGHTS, so the app writes
//                     straight to the client's terminal.
//   server -> client  { pid: int }            app started
//                     { exit: int }           app finished; raw wait(2) status
//                     { error: string }       launch failed
// Closing the connection before { exit } terminates the app (this is how Ctrl-C on the client propagates).
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

// The real home directory (simrun.sh points $HOME at the simulated device's data directory).
static inline const char *simrund_home(void) {
  struct passwd *pw = getpwuid(getuid());
  return pw && pw->pw_dir ? pw->pw_dir : "/tmp";
}
static inline void simrund_socket_path(char *buf, size_t n) {
  const char *o = getenv("SIMRUND_SOCKET");
  if (o) { snprintf(buf, n, "%s", o); return; }
  snprintf(buf, n, "%s/Library/Developer/SimRun/simrund.sock", simrund_home());
}
// Unix socket paths are limited to sizeof(sun_path) - 1 (103) bytes; a longer SIMRUND_SOCKET would be silently
// truncated by strlcpy (and the truncated file then left behind). Returns 0 if the path fits.
static inline int simrund_socket_addr(const char *path, struct sockaddr_un *a) {
  memset(a, 0, sizeof *a); a->sun_family = AF_UNIX;
  if (strlen(path) >= sizeof a->sun_path) { fprintf(stderr, "simrun: socket path too long (max %zu bytes): %s\n", sizeof a->sun_path - 1, path); return -1; }
  strlcpy(a->sun_path, path, sizeof a->sun_path); return 0;
}
static inline void simrund_log_path(char *buf, size_t n) {
  char dir[1024]; snprintf(dir, sizeof dir, "%s/Library/Logs/SimRun", simrund_home());
  mkdir(dir, 0755);
  snprintf(buf, n, "%s/simrund.log", dir);
}

static inline int simrund_write_all(int fd, const void *p, size_t n) {
  while (n) { ssize_t w = write(fd, p, n); if (w <= 0) return -1; p = (const char *)p + w; n -= (size_t)w; }
  return 0;
}
static inline int simrund_read_all(int fd, void *p, size_t n) {
  while (n) { ssize_t r = read(fd, p, n); if (r <= 0) return -1; p = (char *)p + r; n -= (size_t)r; }
  return 0;
}

// Sends one message; if fds != NULL, attaches nfds descriptors to it.
static inline int simrund_send(int sock, CFDictionaryRef dict, const int *fds, int nfds) {
  CFDataRef data = CFPropertyListCreateData(NULL, dict, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
  if (!data) return -1;
  uint32_t len = (uint32_t)CFDataGetLength(data);
  int rc;
  if (fds && nfds > 0) {
    struct iovec iov = { &len, sizeof len };
    char ctl[CMSG_SPACE(sizeof(int) * 3)] = {0};
    struct msghdr mh = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl, .msg_controllen = (socklen_t)CMSG_SPACE(sizeof(int) * nfds) };
    struct cmsghdr *c = CMSG_FIRSTHDR(&mh);
    c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS; c->cmsg_len = (socklen_t)CMSG_LEN(sizeof(int) * nfds);
    memcpy(CMSG_DATA(c), fds, sizeof(int) * nfds);
    rc = sendmsg(sock, &mh, 0) == (ssize_t)sizeof len ? 0 : -1;
  } else rc = simrund_write_all(sock, &len, sizeof len);
  if (rc == 0) rc = simrund_write_all(sock, CFDataGetBytePtr(data), len);
  CFRelease(data);
  return rc;
}

// Receives one message (caller releases). Received descriptors (if any) go to fds[0..*nfds), up to 3.
static inline CFDictionaryRef simrund_recv(int sock, int *fds, int *nfds) {
  uint32_t len = 0;
  struct iovec iov = { &len, sizeof len };
  char ctl[CMSG_SPACE(sizeof(int) * 3)] = {0};
  struct msghdr mh = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl, .msg_controllen = sizeof ctl };
  ssize_t r = recvmsg(sock, &mh, MSG_WAITALL);
  if (nfds) *nfds = 0;
  if (r != (ssize_t)sizeof len) return NULL;
  for (struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c; c = CMSG_NXTHDR(&mh, c))
    if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS && fds && nfds) {
      int n = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int)); if (n > 3) n = 3;
      memcpy(fds, CMSG_DATA(c), sizeof(int) * n); *nfds = n;
    }
  if (len == 0 || len > (64u << 20)) return NULL;
  UInt8 *buf = malloc(len);
  if (simrund_read_all(sock, buf, len)) { free(buf); return NULL; }
  CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, buf, len, kCFAllocatorMalloc);
  CFPropertyListRef pl = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
  CFRelease(data);
  if (pl && CFGetTypeID(pl) != CFDictionaryGetTypeID()) { CFRelease(pl); pl = NULL; }
  return (CFDictionaryRef)pl;
}
