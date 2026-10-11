// simapp — client for simrund: launch a sim app in the shared server, starting the server if needed.
// usage: simapp <sim-binary> [args...]   (run with the simrun.sh environment; scripts/simapp.sh does this)
// SIMRUN_PROFILE=<name> in the environment runs it in that profile: another data container of the app's.
// Behaves like running the app directly: its stdout/stderr go to this terminal, the exit status is the app's,
// and Ctrl-C (or killing simapp) terminates the app.
#include "simrund_proto.h"
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/wait.h>

extern char **environ;

static int try_connect(const char *path) {
  struct sockaddr_un a; if (simrund_socket_addr(path, &a)) exit(2);
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) return s;
  close(s); return -1;
}

// The SimRun.app executable: $SIMRUN_SERVER, else inside the bundle we live in (Contents/Helpers/simapp), else
// build/SimRun.app next to build/bin/simapp.
static int find_server(char *server, size_t n) {
  const char *o = getenv("SIMRUN_SERVER");
  if (o) { snprintf(server, n, "%s", o); return access(server, X_OK); }
  char exe[PATH_MAX], real[PATH_MAX]; uint32_t len = sizeof exe;
  _NSGetExecutablePath(exe, &len); realpath(exe, real);
  char *dir = dirname(real);
  snprintf(server, n, "%s/../MacOS/SimRun", dir);
  if (access(server, X_OK) == 0) return 0;
  snprintf(server, n, "%s/../SimRun.app/Contents/MacOS/SimRun", dir);
  return access(server, X_OK);
}

// Start `SimRun --serve` as a detached session leader, logging to ~/Library/Logs/SimRun/simrund.log.
static int start_server(void) {
  char server[PATH_MAX];
  if (find_server(server, sizeof server)) { fprintf(stderr, "simapp: SimRun.app not found (set SIMRUN_SERVER)\n"); return -1; }
  char log[1024]; simrund_log_path(log, sizeof log);
  posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0644);
  posix_spawn_file_actions_adddup2(&fa, 1, 2);
  posix_spawnattr_t at; posix_spawnattr_init(&at);
  posix_spawnattr_setflags(&at, POSIX_SPAWN_SETSID);
  // the server's own environment: the simrun.sh environment minus per-app settings
  int ne = 0; while (environ[ne]) ne++;
  char **env = calloc(ne + 1, sizeof(char *)); int k = 0;
  for (int i = 0; i < ne; i++)
    if (strncmp(environ[i], "DYLD_INSERT_LIBRARIES=", 22) && strncmp(environ[i], "SIMRUN_TITLE=", 13) &&
        strncmp(environ[i], "SIMRUN_PROFILE=", 15)) env[k++] = environ[i];
  char *argv[] = { server, "--serve", NULL };
  pid_t pid; int r = posix_spawn(&pid, server, &fa, &at, argv, env);
  posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at); free(env);
  if (r) { fprintf(stderr, "simapp: cannot start %s: %s\n", server, strerror(r)); return -1; }
  return 0;
}

static int connect_or_start(const char *path) {
  int s = try_connect(path);
  if (s >= 0) return s;
  // serialize server start-up between concurrent clients
  char lockp[1100]; snprintf(lockp, sizeof lockp, "%s.lock", path);
  int lk = open(lockp, O_CREAT | O_RDWR, 0600);
  if (lk >= 0) flock(lk, LOCK_EX);
  s = try_connect(path);
  if (s < 0 && start_server() == 0)
    for (int i = 0; i < 200 && (s = try_connect(path)) < 0; i++) usleep(25000);
  if (lk >= 0) { flock(lk, LOCK_UN); close(lk); }
  return s;
}

static CFStringRef str(const char *s) { return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8); }

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: simapp <sim-binary> [args...]\n"); return 2; }
  char path[1024]; simrund_socket_path(path, sizeof path);
  int s = connect_or_start(path);
  if (s < 0) { fprintf(stderr, "simapp: cannot reach simrund at %s (see ~/Library/Logs/SimRun/simrund.log)\n", path); return 1; }

  CFMutableArrayRef av = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks), ev = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
  char exe[PATH_MAX];
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (i == 1 && realpath(a, exe)) a = exe;   // the server has its own working directory
    CFStringRef v = str(a); CFArrayAppendValue(av, v); CFRelease(v);
  }
  for (char **e = environ; *e; e++) { CFStringRef v = str(*e); CFArrayAppendValue(ev, v); CFRelease(v); }
  char cwd[PATH_MAX]; if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "/");
  const char *title = getenv("SIMRUN_TITLE"); char base[PATH_MAX];
  if (!title) { strlcpy(base, argv[1], sizeof base); title = basename(base); }
  CFStringRef cwdS = str(cwd), titleS = str(title);
  const void *keys[] = { CFSTR("argv"), CFSTR("env"), CFSTR("cwd"), CFSTR("title") };
  const void *vals[] = { av, ev, cwdS, titleS };
  CFDictionaryRef req = CFDictionaryCreate(NULL, keys, vals, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  int fds[3] = { 0, 1, 2 };
  if (simrund_send(s, req, fds, 3)) { fprintf(stderr, "simapp: send failed\n"); return 1; }

  // Ctrl-C / SIGTERM: exiting closes the socket, which makes simrund terminate the app.
  for (;;) {
    CFDictionaryRef msg = simrund_recv(s, NULL, NULL);
    if (!msg) { fprintf(stderr, "simapp: lost connection to simrund\n"); return 1; }
    CFNumberRef exitN = CFDictionaryGetValue(msg, CFSTR("exit"));
    CFStringRef err = CFDictionaryGetValue(msg, CFSTR("error"));
    if (exitN) {
      int st = 0; CFNumberGetValue(exitN, kCFNumberIntType, &st);
      return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
    }
    if (err) {
      char b[1024]; CFStringGetCString(err, b, sizeof b, kCFStringEncodingUTF8);
      fprintf(stderr, "simapp: %s\n", b); return 1;
    }
    CFRelease(msg);
  }
}
