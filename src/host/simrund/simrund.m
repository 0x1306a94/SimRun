// SimRun.app / simrund — the SimRun host process (macOS, AppKit).
//
// One process owns the launcher, every app window, one set of host-side "sim2host" services (IOSurface, Metal, the
// Mac pasteboard) and a `simns --serve` per iOS runtime in use (the launchd_sim stand-in, which also runs that runtime's
// shared sim daemons): SimRun's own runtime's from the start, another runtime's once an app launched on it needs it.
// Each iOS app is still its own process: it gets a private simns namespace layered over the global one of its
// runtime's simns and a window (SRSession).
//
//   SimRun [app.app ...]         GUI: the launcher window (drop .app bundles to add + launch them); also serves
//                                `simapp` clients on the Unix socket. If another instance already serves the socket,
//                                it is asked to show its launcher (and open the given apps) and this one exits.
//   SimRun --serve               headless server for `simapp` clients (scripts/simapp.sh starts it on demand); shows the
//                                launcher when asked; exits after SIMRUND_IDLE seconds (default 600, 0 = never) without
//                                apps unless the launcher was used
//   SimRun --run <exe> [args]    standalone: launch one app with this process's environment/stdio, exit with its status
#import <Cocoa/Cocoa.h>
#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <libproc.h>
#include <sys/proc.h>
#include "session.h"
#include "environment.h"
#include "library.h"
#include "launcher.h"
#include "pasteboard.h"
#include "keychainwindow.h"
#include "launchoptions.h"
#include "simns_proto.h"
#include "simrund_proto.h"
#include "gpuhost.h"
#include "pboard.h"

typedef NS_ENUM(NSInteger, SRMode) { SRModeGUI, SRModeServe, SRModeRun };

static void LOG(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
  fprintf(stderr, "[simrund] %s\n", s.UTF8String);
}

// A pending/active launch request.
@interface SRRequest : NSObject
@property NSArray<NSString *> *argv, *env; @property NSString *cwd, *title, *appPath;
@property NSString *runtimeRoot;                   // the iOS runtime it runs on
@property int sock; @property int fd0, fd1, fd2;   // client connection (-1 if none) and the app's stdio (-1 = inherit)
@property int captureFD;                           // read end of the app's output pipe (launcher launches), or -1
@property SRSession *session; @property dispatch_source_t eofSource;
@end
@implementation SRRequest
- (instancetype)init { if ((self = [super init])) { _sock = _fd0 = _fd1 = _fd2 = _captureFD = -1; } return self; }
@end

// One `simns --serve`: the launchd_sim stand-in for the apps on one runtime, and that runtime's shared daemons.
@interface SRSimns : NSObject
@property NSString *root;
@property mach_port_t ctlPort;   // our receive port: simns sends SIMNS_MSG_HELLO here
@property mach_port_t control;   // simns's control port (send right); set once it said hello
@property pid_t pid;
@property dispatch_source_t ctlSource;
@end
@implementation SRSimns
@end

@interface SRServer : NSObject <NSApplicationDelegate, SRLauncherDelegate, NSMenuDelegate>
@end

@implementation SRServer {
  SRMode _mode; NSArray<NSString *> *_args;
  BOOL _interactive;             // the launcher has been used: stay until quit
  NSMutableDictionary<NSString *, SRSimns *> *_simns;   // by runtime root
  dispatch_source_t _listenSource, _sigSource;
  int _listenFd; NSString *_socketPath;
  NSMutableArray<SRRequest *> *_pending, *_active;
  NSMutableArray<NSString *> *_openAtLaunch;
  NSTimer *_idleTimer;
  SRLauncher *_launcher;
  NSMenuItem *_quitServerItem, *_quitAppItem;   // ⌘Q quits the app whose window is key, else SimRun
  SRPasteboardHost *_pasteboard; mach_port_t _pasteboardPort;
  BOOL _gpuStarted; mach_port_t _iosurfacePort, _metalPort;
  BOOL _launched;
}

- (instancetype)initWithMode:(SRMode)mode args:(NSArray<NSString *> *)args {
  if ((self = [super init])) {
    _mode = mode; _args = args; _listenFd = -1;
    _pending = [NSMutableArray array]; _active = [NSMutableArray array]; _openAtLaunch = [NSMutableArray array];
    _simns = [NSMutableDictionary dictionary];
    if (mode == SRModeGUI) [_openAtLaunch addObjectsFromArray:args];
    _launcher = [[SRLauncher alloc] initWithDelegate:self];
  }
  return self;
}

// ---------------------------------------------------------------- app lifecycle
- (void)applicationWillFinishLaunching:(NSNotification *)n { if (_mode != SRModeRun) [self buildMenus]; }

- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls {   // Dock drop, "Open With", `open -a SimRun x.app`
  NSMutableArray *paths = [NSMutableArray array];
  for (NSURL *u in urls) if (u.isFileURL) [paths addObject:u.path];
  if (!_launched) { [_openAtLaunch addObjectsFromArray:paths]; return; }
  _interactive = YES;
  [_launcher openPaths:paths];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
  // SIMRUN_DEBUG_STALL=<ms> (testing): block the main thread for that long every 100 ms, as a busy UI would
  double stall = getenv("SIMRUN_DEBUG_STALL") ? atof(getenv("SIMRUN_DEBUG_STALL")) : 0;
  if (stall > 0) [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { usleep((useconds_t)(stall * 1000)); }];
  signal(SIGTERM, SIG_IGN); signal(SIGPIPE, SIG_IGN);
  _sigSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(_sigSource, ^{ [NSApp terminate:nil]; });
  dispatch_resume(_sigSource);

  if (![SREnvironment runtimeRoot]) {
    if (_mode == SRModeGUI) {
      NSAlert *al = [NSAlert new]; al.messageText = @"No iOS Simulator runtime found";
      al.informativeText = @"Install an iOS Simulator runtime in Xcode (Settings ▸ Components), then open SimRun again.";
      [al runModal];
    }
    LOG(@"no iOS Simulator runtime found"); exit(1);
  }
  if (_mode != SRModeRun && ![self startListening]) {
    if (_mode == SRModeGUI) [self forwardToRunningInstance];   // another instance serves: hand over and quit
    exit(0);
  }
  LOG(@"runtime %@", [SRRuntime runtimeAtRoot:SREnvironment.runtimeRoot].name ?: SREnvironment.runtimeRoot);
  if (![self simnsForRoot:SREnvironment.runtimeRoot]) { LOG(@"cannot start simns"); exit(1); }
  _launched = YES;

  if (_mode == SRModeRun) {
    SRRequest *r = [SRRequest new];
    r.argv = _args; r.runtimeRoot = SREnvironment.runtimeRoot;
    r.env = [SREnvironment environment:[SREnvironment processEnvironment] withOverrides:[SREnvironment runtimeVariablesForRoot:r.runtimeRoot]];
    r.cwd = NSFileManager.defaultManager.currentDirectoryPath;
    r.title = NSProcessInfo.processInfo.environment[@"SIMRUN_TITLE"] ?: _args.firstObject.lastPathComponent;
    [self enqueue:r];
    return;
  }
  if (_mode == SRModeGUI) {
    _interactive = YES;
    [_launcher show];
    if (_openAtLaunch.count) [_launcher openPaths:_openAtLaunch];
    [_openAtLaunch removeAllObjects];
  }
  [self scheduleIdleCheck];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {   // Dock icon click
  _interactive = YES;
  if (!visible) [_launcher show];
  return YES;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return NO; }
- (void)applicationWillTerminate:(NSNotification *)n {
  for (SRRequest *r in [_active copy]) { [self reply:r dict:@{ @"error": @"SimRun quit" }]; [r.session terminate]; }
  for (SRRequest *r in _active) if (r.session.pid > 0) kill(r.session.pid, SIGKILL);   // no time for the SIGTERM grace period
  for (SRSimns *ns in _simns.allValues) if (ns.pid > 0) kill(ns.pid, SIGTERM);
  if (_listenFd >= 0 && _socketPath) unlink(_socketPath.fileSystemRepresentation);
}

// ---------------------------------------------------------------- menus
- (void)buildMenus {
  NSMenu *bar = [NSMenu new];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"SimRun"];
  [appMenu addItemWithTitle:@"About SimRun" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  [appMenu addItem:NSMenuItem.separatorItem];
  NSMenu *runtimes = [[NSMenu alloc] initWithTitle:@"iOS Runtime"];
  runtimes.delegate = self;   // filled when opened: menuNeedsUpdate:
  [appMenu addItemWithTitle:@"iOS Runtime" action:nil keyEquivalent:@""].submenu = runtimes;
  [appMenu addItem:NSMenuItem.separatorItem];
  [appMenu addItemWithTitle:@"Hide SimRun" action:@selector(hide:) keyEquivalent:@"h"];
  NSMenuItem *ho = [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
  ho.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
  [appMenu addItem:NSMenuItem.separatorItem];
  _quitServerItem = [appMenu addItemWithTitle:@"Quit SimRun" action:@selector(terminate:) keyEquivalent:@"q"];

  NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
  [file addItemWithTitle:@"Add App…" action:@selector(addApp:) keyEquivalent:@"o"].target = self;
  [file addItemWithTitle:@"Add Xcode Simulator Builds" action:@selector(addXcodeBuilds:) keyEquivalent:@""].target = self;
  [file addItem:NSMenuItem.separatorItem];
  [file addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];

  NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];   // in app windows, SRView sends these to the app
  [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];   // ⇧⌘Z
  [edit addItem:NSMenuItem.separatorItem];
  [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [edit addItemWithTitle:@"Delete" action:@selector(delete:) keyEquivalent:@""];
  [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

  NSMenu *appCmds = [[NSMenu alloc] initWithTitle:@"App"];
  [appCmds addItemWithTitle:@"Relaunch" action:@selector(relaunchFrontApp:) keyEquivalent:@"r"].target = self;
  NSMenuItem *with = [appCmds addItemWithTitle:@"Relaunch With…" action:@selector(relaunchFrontAppWith:) keyEquivalent:@"r"];
  with.target = self; with.alternate = YES; with.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  _quitAppItem = [appCmds addItemWithTitle:@"Quit App" action:@selector(quitFrontApp:) keyEquivalent:@""];
  _quitAppItem.target = self;
  [appCmds addItemWithTitle:@"Show Log" action:@selector(showFrontAppLog:) keyEquivalent:@"l"].target = self;
  [appCmds addItemWithTitle:@"Show Keychain Items" action:@selector(showFrontAppKeychain:) keyEquivalent:@""].target = self;

  NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
  [win addItemWithTitle:@"Launcher" action:@selector(showLauncher:) keyEquivalent:@"0"].target = self;
  [win addItemWithTitle:@"Keychain" action:@selector(showKeychain:) keyEquivalent:@"K"].target = self;   // ⇧⌘K
  [win addItem:NSMenuItem.separatorItem];
  [win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  [win addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];

  for (NSMenu *m in @[ appMenu, file, edit, appCmds, win ]) { NSMenuItem *it = [NSMenuItem new]; it.submenu = m; [bar addItem:it]; }
  NSApp.mainMenu = bar; NSApp.windowsMenu = win;
  for (NSNotificationName n in @[ NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification ])
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyWindowChanged:) name:n object:nil];
}

// Key equivalents are matched without opening the menu, so move ⌘Q as the key window changes: to "Quit <app>"
// while an app window is key (SimRun itself then quits with ⌥⌘Q), back to "Quit SimRun" otherwise.
- (void)keyWindowChanged:(NSNotification *)n {
  // on resign, NSApp.keyWindow can still be the resigning window
  SRRequest *r = [n.name isEqualToString:NSWindowDidBecomeKeyNotification] ? [self requestForWindow:n.object] : nil;
  _quitAppItem.title = r ? [NSString stringWithFormat:@"Quit %@", r.session.title] : @"Quit App";
  _quitAppItem.keyEquivalent = r ? @"q" : @"";
  _quitServerItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | (r ? NSEventModifierFlagOption : 0);
}

- (SRRequest *)requestForWindow:(NSWindow *)w {
  for (SRRequest *r in _active) if (w && r.session.window == w) return r;
  return nil;
}
- (SRRequest *)frontRequest { return [self requestForWindow:NSApp.keyWindow ?: NSApp.mainWindow]; }
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  SEL a = item.action;
  if (a == @selector(relaunchFrontApp:) || a == @selector(relaunchFrontAppWith:)) return [self frontRequest].appPath != nil;
  if (a == @selector(quitFrontApp:) || a == @selector(showFrontAppLog:)) return [self frontRequest] != nil;
  if (a == @selector(showFrontAppKeychain:)) return [self frontRequest].appPath != nil;
  return YES;
}
- (void)addApp:(id)s { _interactive = YES; [_launcher addAppWithPanel]; }
- (void)addXcodeBuilds:(id)s { _interactive = YES; [_launcher addXcodeBuilds]; }
- (void)showLauncher:(id)s { _interactive = YES; [_launcher show]; }
- (void)quitFrontApp:(id)s { [[self frontRequest].session terminate]; }
- (void)showFrontAppLog:(id)s { [[self frontRequest].session showLog]; }
- (void)showKeychain:(id)s { [SRKeychainWindow.shared showWithFilter:nil]; }
- (void)showFrontAppKeychain:(id)s {
  NSString *path = [self frontRequest].appPath;
  if (path) [SRKeychainWindow.shared showWithFilter:[SRAppInfo infoWithPath:path].bundleIdentifier ?: @""];
}
- (void)relaunchFrontApp:(id)s { NSString *path = [self frontRequest].appPath; if (path) [self relaunchApp:[SRAppInfo infoWithPath:path]]; }
- (void)relaunchFrontAppWith:(id)s {
  NSString *path = [self frontRequest].appPath;
  if (!path) return;
  _interactive = YES;
  [_launcher showLaunchOptionsForApp:[SRAppInfo infoWithPath:path]];
}

// SimRun ▸ iOS Runtime: the runtime SimRun's shared services run on (and apps without their own), from the next start.
- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];
  NSArray<SRRuntime *> *installed = SREnvironment.installedRuntimes;
  NSString *pref = SREnvironment.preferredRuntimeBuild;
  NSMenuItem *newest = [menu addItemWithTitle:installed.count ? [NSString stringWithFormat:@"Newest Installed (%@)", installed[0].name] : @"Newest Installed"
                                       action:@selector(chooseRuntime:) keyEquivalent:@""];
  newest.target = self; newest.state = pref ? NSControlStateValueOff : NSControlStateValueOn;
  [menu addItem:NSMenuItem.separatorItem];
  BOOL listed = NO;
  for (SRRuntime *r in installed) {
    NSMenuItem *it = [menu addItemWithTitle:r.name action:@selector(chooseRuntime:) keyEquivalent:@""];
    it.target = self; it.representedObject = r.build;
    if ([r.build isEqualToString:pref]) { it.state = NSControlStateValueOn; listed = YES; }
  }
  if (pref && !listed) {
    NSMenuItem *it = [menu addItemWithTitle:[NSString stringWithFormat:@"%@ (Not Installed)", pref] action:nil keyEquivalent:@""];
    it.state = NSControlStateValueOn;
  }
  // a choice other than the running one waits for the next start; SIMRUN_RUNTIME_ROOT overrides it for this one
  SRRuntime *running = [SRRuntime runtimeAtRoot:SREnvironment.runtimeRoot];
  SRRuntime *chosen = pref ? [SREnvironment installedRuntimeWithBuild:pref] : installed.firstObject;
  NSString *note = nil;
  if (SREnvironment.runtimeRootFromEnvironment) note = [NSString stringWithFormat:@"Using %@ (set by SIMRUN_RUNTIME_ROOT)", running.name ?: SREnvironment.runtimeRoot];
  else if (![chosen.build isEqualToString:running.build]) note = [NSString stringWithFormat:@"Using %@ until SimRun is reopened", running.name];
  if (note) { [menu addItem:NSMenuItem.separatorItem]; [menu addItemWithTitle:note action:nil keyEquivalent:@""].enabled = NO; }
}
- (void)chooseRuntime:(NSMenuItem *)item { SREnvironment.preferredRuntimeBuild = item.representedObject; }

// ---------------------------------------------------------------- SRLauncherDelegate
- (SRRequest *)requestForApp:(SRAppInfo *)app {
  for (SRRequest *r in _active) if ([r.appPath isEqualToString:app.path]) return r;
  for (SRRequest *r in _pending) if ([r.appPath isEqualToString:app.path]) return r;
  return nil;
}
- (SRAppState)stateForApp:(SRAppInfo *)app {
  SRRequest *r = [self requestForApp:app];
  if (!r) return SRAppStateStopped;
  return r.session.isReady ? SRAppStateRunning : SRAppStateLaunching;
}
- (void)quitApp:(SRAppInfo *)app { [[self requestForApp:app].session terminate]; }
- (void)relaunchApp:(SRAppInfo *)app {
  SRRequest *r = [self requestForApp:app];
  if (!r.session) { [self launchApp:app]; return; }   // not running (or still waiting for its simns)
  __weak SRServer *weakSelf = self;
  SRSessionExitHandler old = r.session.onExit;
  r.session.onExit = ^(SRSession *session, int status) { if (old) old(session, status); [weakSelf launchApp:app]; };
  [r.session terminate];
}
- (void)showLogForApp:(SRAppInfo *)app { [[self requestForApp:app].session showLog]; }

- (void)resetDataForApp:(SRAppInfo *)app {
  if ([self requestForApp:app]) return;   // running: it would recreate what we delete
  NSString *ident = [SREnvironment containerIdentifierForExecutable:app.executablePath];
  // The shared cfprefsd caches the app's preferences domain and would write it straight back into the new container:
  // stop it first (letting it flush). simns keeps its service port meanwhile and relaunches it on the next message, so
  // running apps keep their CFPreferences connection (docs/simns.md).
  [self stopSimDaemonsNamed:@"cfprefsd"];
  NSFileManager *fm = NSFileManager.defaultManager;
  [fm removeItemAtPath:[SREnvironment containerPathForIdentifier:ident] error:nil];
  // cfprefsd copies a domain missing from a container from the shared Preferences (where every app's preferences
  // lived before apps had containers); don't let a stale copy come back
  [fm removeItemAtPath:[[SREnvironment dataDirectory] stringByAppendingFormat:@"/Library/Preferences/%@.plist", ident] error:nil];
  LOG(@"reset the data container of %@", ident);
}

// SIGTERM to the simns-spawned daemons with this process name; waits up to 1 s for them, then SIGKILL. (They are
// simns's children: once exited they stay zombies until simns reaps them at the next lookup.)
static BOOL ProcessGone(pid_t pid) {
  struct proc_bsdinfo bi;
  return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != sizeof bi || bi.pbi_status == SZOMB;
}
- (void)stopSimDaemonsNamed:(NSString *)name {
  NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
  for (SRSimns *ns in _simns.allValues) {
    if (ns.pid <= 0) continue;
    pid_t kids[512];
    int n = proc_listchildpids(ns.pid, kids, sizeof kids);
    for (int i = 0; i < n && i < (int)(sizeof kids / sizeof *kids); i++) {
      char buf[64] = {0};
      if (proc_name(kids[i], buf, sizeof buf) > 0 && [@(buf) isEqualToString:name] && kill(kids[i], SIGTERM) == 0) [pids addObject:@(kids[i])];
    }
  }
  for (int t = 0; t < 50 && pids.count; t++) {
    usleep(20000);
    for (NSNumber *p in [pids copy]) if (ProcessGone(p.intValue)) [pids removeObject:p];
  }
  for (NSNumber *p in pids) kill(p.intValue, SIGKILL);
}

- (void)launchApp:(SRAppInfo *)app {
  SRRequest *running = [self requestForApp:app];
  if (running) { [running.session bringToFront]; return; }   // no-op while it is still launching
  // the app's launch options (Launch With…): its runtime, arguments, environment
  SRLaunchOptions *o = [SRLaunchOptions optionsForAppAtPath:app.path];
  NSString *root = SREnvironment.runtimeRoot;
  if (o.runtimeBuild && ![o.runtimeBuild isEqualToString:[SRRuntime runtimeAtRoot:root].build]) {
    root = [SREnvironment installedRuntimeWithBuild:o.runtimeBuild].root;
    if (!root) {
      NSAlert *al = [NSAlert new]; al.messageText = [NSString stringWithFormat:@"Couldn't launch %@", app.name];
      al.informativeText = [NSString stringWithFormat:@"It is set to run on iOS runtime %@, which isn't installed. Choose another "
                                                       "runtime with Launch With… (hold Option in the app's menu in the launcher).", o.runtimeBuild];
      [al runModal];
      return;
    }
  }
  SRRequest *r = [SRRequest new];
  r.argv = [@[ app.executablePath ] arrayByAddingObjectsFromArray:o.launchArguments];
  r.cwd = app.path; r.title = app.name; r.appPath = app.path; r.runtimeRoot = root;
  NSMutableDictionary *vars = [[SREnvironment simulatorVariablesForRoot:root] mutableCopy];
  vars[@"SIMNS_INSERT"] = [SREnvironment injectedLibraries];
  vars[@"SIMULATOR_FRAMEBUFFER_FRAMEWORK"] = [SREnvironment framebufferFramework];
  vars[@"SIMRUN_TITLE"] = app.name;
  [vars addEntriesFromDictionary:o.environmentVariables];
  r.env = [SREnvironment environment:[SREnvironment processEnvironment] withOverrides:vars];
  // no terminal: stdout/stderr go to the session's log window
  int p[2]; pipe(p);
  r.fd0 = open("/dev/null", O_RDONLY); r.fd1 = p[1]; r.fd2 = dup(p[1]); r.captureFD = p[0];
  [self enqueue:r];
}

// ---------------------------------------------------------------- simns (shared namespace + daemons), one per runtime
// The simns for `root`, started if there is none yet; nil if it can't be started. It is usable once it has said hello
// (`control` set); requests for it wait in _pending until then.
- (SRSimns *)simnsForRoot:(NSString *)root {
  root = root.stringByStandardizingPath;
  if (!root.length) return nil;
  SRSimns *ns = _simns[root];
  if (ns) return ns;
  ns = [SRSimns new]; ns.root = root;
  mach_port_t ctl;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &ctl);
  mach_port_insert_right(mach_task_self(), ctl, ctl, MACH_MSG_TYPE_MAKE_SEND);
  ns.ctlPort = ctl;
  ns.ctlSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, ctl, 0, dispatch_get_main_queue());
  __weak SRServer *weakSelf = self; __weak SRSimns *weakNS = ns;
  dispatch_source_set_event_handler(ns.ctlSource, ^{ [weakSelf drainControlOf:weakNS]; });
  dispatch_resume(ns.ctlSource);

  NSString *simns = [SREnvironment simnsPath];
  NSMutableDictionary *vars = [[SREnvironment simulatorVariablesForRoot:root] mutableCopy];
  vars[@"SIMNS_HOST_SLOT"] = @"0";
  NSMutableArray *env = [NSMutableArray array];
  for (NSString *kv in [SREnvironment environment:[SREnvironment processEnvironment] withOverrides:vars])
    if (![kv hasPrefix:@"DYLD_INSERT_LIBRARIES="]) [env addObject:kv];
  char **cenv = calloc(env.count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < env.count; i++) cenv[i] = (char *)[env[i] UTF8String];
  char *argv[] = { (char *)simns.UTF8String, "--serve", NULL };
  mach_port_t reg[1] = { ctl };
  mach_ports_register(mach_task_self(), reg, 1);   // simns finds us in slot 0 and says hello
  pid_t pid = 0;
  int r = posix_spawn(&pid, argv[0], NULL, NULL, argv, cenv);
  mach_ports_register(mach_task_self(), NULL, 0);
  free(cenv);
  if (r) {
    LOG(@"spawn %@: %s", simns, strerror(r));
    dispatch_source_cancel(ns.ctlSource);
    mach_port_mod_refs(mach_task_self(), ctl, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), ctl);
    return nil;
  }
  ns.pid = pid;
  _simns[root] = ns;
  LOG(@"simns pid %d (%@)", pid, [SRRuntime runtimeAtRoot:root].name ?: root);
  return ns;
}

- (void)drainControlOf:(SRSimns *)ns {
  if (!ns) return;
  union { mach_msg_header_t h; simns_port_msg_t p; char buf[512]; } m;
  while (mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, ns.ctlPort, 0, 0) == KERN_SUCCESS) {
    if (m.h.msgh_id != SIMNS_MSG_HELLO) { mach_msg_destroy(&m.h); continue; }
    ns.control = m.p.port.name;
    // host services, started once and published in every runtime's simns
    if (!_gpuStarted) {
      _gpuStarted = YES;
      if (srgpu_host_start(&_iosurfacePort, &_metalPort) != 0) LOG(@"host GPU services failed to start");
    }
    if (_iosurfacePort) [self registerName:"com.apple.IOSurface.Remote" port:_iosurfacePort in:ns];
    if (_metalPort) [self registerName:"com.apple.metal.simulator" port:_metalPort in:ns];
    if (!_pasteboard) { _pasteboard = [SRPasteboardHost new]; _pasteboardPort = [_pasteboard start]; }
    if (_pasteboardPort) [self registerName:SRPB_SERVICE port:_pasteboardPort in:ns]; else LOG(@"host pasteboard service failed to start");
    mach_msg_header_t ready = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0), .msgh_size = sizeof ready,
                                .msgh_remote_port = ns.control, .msgh_id = SIMNS_MSG_READY };
    mach_msg(&ready, MACH_SEND_MSG, sizeof ready, 0, 0, 0, 0);
    LOG(@"ready (%@)", [SRRuntime runtimeAtRoot:ns.root].name ?: ns.root);
    for (SRRequest *r in [_pending copy])
      if ([r.runtimeRoot.stringByStandardizingPath isEqualToString:ns.root]) { [_pending removeObject:r]; [self launch:r]; }
  }
}

- (void)registerName:(const char *)name port:(mach_port_t)port in:(SRSimns *)ns {
  simns_register_msg_t r = {0};
  r.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  r.h.msgh_size = sizeof r; r.h.msgh_remote_port = ns.control; r.h.msgh_id = SIMNS_MSG_REGISTER;
  r.b.msgh_descriptor_count = 1; r.port.name = port; r.port.disposition = MACH_MSG_TYPE_COPY_SEND; r.port.type = MACH_MSG_PORT_DESCRIPTOR;
  r.flags = SIMNS_F_HOST_SIDE; strlcpy(r.name, name, sizeof r.name);
  mach_msg(&r.h, MACH_SEND_MSG, sizeof r, 0, 0, 0, 0);
}

// A fresh per-app namespace (send right) from `ns`.
- (mach_port_t)newNamespaceIn:(SRSimns *)ns {
  if (!ns.control) return MACH_PORT_NULL;
  mach_port_t reply; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
  union { mach_msg_header_t h; simns_port_msg_t p; char buf[512]; } m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
  m.h.msgh_size = sizeof(mach_msg_header_t); m.h.msgh_remote_port = ns.control; m.h.msgh_local_port = reply;
  m.h.msgh_id = SIMNS_MSG_NEW_NS;
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT, sizeof(mach_msg_header_t), sizeof m, reply, 3000, 0);
  mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1);
  if (kr || m.h.msgh_id != SIMNS_MSG_NS_REPLY) { LOG(@"new namespace failed: %x", kr); return MACH_PORT_NULL; }
  return m.p.port.name;
}

// ---------------------------------------------------------------- launching
- (void)enqueue:(SRRequest *)r {
  [_idleTimer invalidate]; _idleTimer = nil;
  SRSimns *ns = [SRRuntime runtimeAtRoot:r.runtimeRoot] ? [self simnsForRoot:r.runtimeRoot] : nil;
  if (!ns || ns.control) [self launch:r];   // no simns: launch: reports the failure
  else { [_pending addObject:r]; [_launcher reloadState]; }
}

// The app's environment: the client's (or the launcher's), aimed at this server's simns and at the app's own data
// container (HOME), with the shared data directory for what is managed centrally (keychain, app groups, daemons).
// SCENES_W/SCENES_H/SCENES_SCALE size the app's scene (scenes.dylib); the display it renders into (simfb, the window)
// is SIMULATOR_MAINSCREEN_* in pixels. Keep them the same, or a smaller scene draws into a corner of a 402x874 display.
- (NSDictionary<NSString *, NSString *> *)displayVariablesForScene:(NSArray<NSString *> *)env {
  NSMutableDictionary *vars = [NSMutableDictionary dictionary];
  for (NSString *kv in env) {
    NSRange eq = [kv rangeOfString:@"="];
    if (eq.location != NSNotFound && [kv hasPrefix:@"SCENES_"]) vars[[kv substringToIndex:eq.location]] = [kv substringFromIndex:NSMaxRange(eq)];
  }
  if (!vars[@"SCENES_W"] && !vars[@"SCENES_H"] && !vars[@"SCENES_SCALE"]) return @{};
  double w = vars[@"SCENES_W"] ? [vars[@"SCENES_W"] doubleValue] : 402, h = vars[@"SCENES_H"] ? [vars[@"SCENES_H"] doubleValue] : 874;
  double scale = vars[@"SCENES_SCALE"] ? [vars[@"SCENES_SCALE"] doubleValue] : 3;   // scenes.dylib's defaults
  if (w <= 0 || h <= 0 || scale <= 0) return @{};
  return @{ @"SIMULATOR_MAINSCREEN_WIDTH": [NSString stringWithFormat:@"%.0f", round(w * scale)],
            @"SIMULATOR_MAINSCREEN_HEIGHT": [NSString stringWithFormat:@"%.0f", round(h * scale)],
            @"SIMULATOR_MAINSCREEN_SCALE": [NSString stringWithFormat:@"%f", scale] };
}

- (NSArray<NSString *> *)appEnvironmentFrom:(NSArray<NSString *> *)env executable:(NSString *)exe {
  NSString *data = [SREnvironment dataDirectory];
  NSString *home = [SREnvironment createContainerForIdentifier:[SREnvironment containerIdentifierForExecutable:exe]];
  env = [SREnvironment environment:env withOverrides:@{
    @"HOME": home, @"CFFIXED_USER_HOME": home, @"TMPDIR": [home stringByAppendingString:@"/tmp/"],
    @"SIMULATOR_SHARED_RESOURCES_DIRECTORY": data, @"IPHONE_SHARED_RESOURCES_DIRECTORY": data,
  }];
  env = [SREnvironment environment:env withOverrides:[self displayVariablesForScene:env]];
  NSString *insert = nil;
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *kv in env) {
    if ([kv hasPrefix:@"SIMNS_INSERT="]) insert = [kv substringFromIndex:13];
    if ([kv hasPrefix:@"DYLD_INSERT_LIBRARIES="] || [kv hasPrefix:@"XPC_SIMULATOR_LAUNCHD_NAME="] || [kv hasPrefix:@"XPC_FLAGS="] ||
        [kv hasPrefix:@"XPC_SERVICE_NAME="] || [kv hasPrefix:@"SIMNS_"] || [kv hasPrefix:@"SIMRUN_HOST_INTL="]) continue;
    [out addObject:kv];
  }
  NSString *intl = [SREnvironment hostInternationalSettings];   // read at each launch: follows changes on the Mac
  if (intl) [out addObject:[@"SIMRUN_HOST_INTL=" stringByAppendingString:intl]];
  [out addObject:@"XPC_SIMULATOR_LAUNCHD_NAME=dev.simrun.simns"];   // value unused; makes sim libxpc use our bootstrap port
  [out addObject:@"XPC_FLAGS=0x0"];
  if (insert.length) [out addObject:[@"DYLD_INSERT_LIBRARIES=" stringByAppendingString:insert]];
  return out;
}

// Why `r`'s executable can't run on `rt` (its minimum iOS is newer: dyld would refuse to load it and the app would just
// exit), or nil.
- (NSString *)runtimeProblemFor:(SRRequest *)r runtime:(SRRuntime *)rt {
  NSString *exe = r.argv.firstObject;
  if (!exe.absolutePath && r.cwd) exe = [r.cwd stringByAppendingPathComponent:exe];   // a client's path is relative to its cwd
  NSString *min = [SRAppInfo minimumOSVersionOfExecutable:exe];
  if (!min || [min compare:rt.version options:NSNumericSearch] != NSOrderedDescending) return nil;
  NSString *name = r.title ?: r.argv.firstObject.lastPathComponent;
  NSString *how = r.sock >= 0 || _mode == SRModeRun
      ? @"Run it on a newer runtime with SIMRUN_RUNTIME_ROOT=<…/RuntimeRoot>, or choose one in SimRun ▸ iOS Runtime."
      : @"Choose a newer runtime for it with Launch With… (hold Option in its menu in the launcher), or for SimRun in "
         "SimRun ▸ iOS Runtime.";
  return [NSString stringWithFormat:@"%@ requires iOS %@ or later, but it would run on %@. %@", name, min, rt.name, how];
}

- (void)launch:(SRRequest *)r {
  SRSession *s = [[SRSession alloc] initWithTitle:r.title ?: @"SimRun"];
  s.appPath = r.appPath;
  r.session = s;
  [_active addObject:r];
  __weak SRServer *weakSelf = self;
  s.onExit = ^(SRSession *session, int status) { [weakSelf finish:r status:status]; };
  s.onReady = ^(SRSession *session) { SRServer *me = weakSelf; [me->_launcher reloadState]; };
  NSString *err = nil;
  mach_port_t ns = MACH_PORT_NULL;
  SRRuntime *rt = [SRRuntime runtimeAtRoot:r.runtimeRoot];
  if (!rt) err = [NSString stringWithFormat:@"Not an iOS Simulator runtime: %@", r.runtimeRoot];
  else if ((err = [self runtimeProblemFor:r runtime:rt])) {}
  else ns = [self newNamespaceIn:_simns[r.runtimeRoot.stringByStandardizingPath]];
  int fds[3] = { r.fd0, r.fd1, r.fd2 };
  BOOL ok = ns && [s spawnArgv:r.argv env:[self appEnvironmentFrom:r.env executable:r.argv.firstObject] cwd:r.cwd bootstrap:ns fds:fds error:&err];
  if (ns) mach_port_deallocate(mach_task_self(), ns);   // the app holds its own send right; simns frees the namespace after it
  for (int i = 0; i < 3; i++) if (fds[i] >= 0) close(fds[i]);
  r.fd0 = r.fd1 = r.fd2 = -1;
  if (ok && r.captureFD >= 0) { [s captureOutputFrom:r.captureFD]; r.captureFD = -1; }
  if (!ok) {
    LOG(@"launch failed: %@", err ?: @"no namespace");
    if (r.captureFD >= 0) { close(r.captureFD); r.captureFD = -1; }
    [self reply:r dict:@{ @"error": err ?: @"simns did not create a namespace" }];
    [s terminate]; [_active removeObject:r]; [self closeClient:r];
    if (_mode == SRModeRun) exit(1);
    if (r.sock < 0) {
      NSAlert *al = [NSAlert new]; al.messageText = [NSString stringWithFormat:@"Couldn't launch %@", r.title];
      al.informativeText = err ?: @"The SimRun helper (simns) did not respond."; [al runModal];
    }
    [_launcher reloadState];
    [self scheduleIdleCheck];
    return;
  }
  LOG(@"launched %@ pid %d", r.argv.firstObject.lastPathComponent, s.pid);
  [self reply:r dict:@{ @"pid": @(s.pid) }];
  [_launcher reloadState];
}

- (void)finish:(SRRequest *)r status:(int)status {
  LOG(@"%@ (pid %d) exited, status %d", r.title, r.session.pid, status);
  [self reply:r dict:@{ @"exit": @(status) }];
  [self closeClient:r];
  [_active removeObject:r];
  if (_mode == SRModeRun) exit(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
  [_launcher reloadState];
  [self scheduleIdleCheck];
}

// ---------------------------------------------------------------- client connections
- (BOOL)startListening {
  char path[1024]; simrund_socket_path(path, sizeof path);
  _socketPath = @(path);
  [NSFileManager.defaultManager createDirectoryAtPath:_socketPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  struct sockaddr_un a; if (simrund_socket_addr(path, &a)) exit(2);
  // a live server already listening? then we're redundant
  int probe = socket(AF_UNIX, SOCK_STREAM, 0);
  if (connect(probe, (struct sockaddr *)&a, sizeof a) == 0) { close(probe); LOG(@"another instance is serving %s", path); return NO; }
  close(probe);
  unlink(path);
  _listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (bind(_listenFd, (struct sockaddr *)&a, sizeof a) || listen(_listenFd, 16)) { LOG(@"bind %s: %s", path, strerror(errno)); return NO; }
  chmod(path, 0600);
  _listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _listenFd, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(_listenSource, ^{
    int c = accept(self->_listenFd, NULL, NULL);
    if (c >= 0) [self readRequestFrom:c];
  });
  dispatch_resume(_listenSource);
  LOG(@"serving %s", path);
  return YES;
}

// GUI instance started while another one serves the socket: ask it to show its launcher and open our apps.
- (void)forwardToRunningInstance {
  char path[1024]; simrund_socket_path(path, sizeof path);
  struct sockaddr_un a; if (simrund_socket_addr(path, &a)) return;
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) {
    NSDictionary *msg = @{ @"action": @"show", @"open": _openAtLaunch };
    simrund_send(s, (__bridge CFDictionaryRef)msg, NULL, 0);
  }
  close(s);
}

- (void)readRequestFrom:(int)c {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    int fds[3] = { -1, -1, -1 }, nfds = 0;
    CFDictionaryRef req = simrund_recv(c, fds, &nfds);
    int f0 = fds[0], f1 = fds[1], f2 = fds[2];
    dispatch_async(dispatch_get_main_queue(), ^{
      int got[3] = { f0, f1, f2 };
      NSDictionary *d = CFBridgingRelease(req);
      if ([d[@"action"] isEqual:@"show"]) {   // another SimRun instance handed over
        for (int i = 0; i < nfds; i++) close(got[i]);
        close(c);
        self->_interactive = YES; [self->_idleTimer invalidate]; self->_idleTimer = nil;
        [self->_launcher show];
        NSArray *open = d[@"open"];
        if ([open isKindOfClass:NSArray.class] && open.count) [self->_launcher openPaths:open];
        return;
      }
      NSArray *argv = d[@"argv"];
      if (![argv isKindOfClass:NSArray.class] || !argv.count || nfds != 3) {
        for (int i = 0; i < nfds; i++) close(got[i]);
        close(c); return;
      }
      SRRequest *r = [SRRequest new];
      r.argv = argv; r.cwd = d[@"cwd"]; r.title = d[@"title"];
      // The runtime: the client's SIMRUN_RUNTIME_ROOT, else SimRun's; its variables replace whatever runtime the
      // client's environment points at, so the app and the daemons it talks to (that runtime's simns) always match.
      NSArray *env = [d[@"env"] isKindOfClass:NSArray.class] ? d[@"env"] : @[];
      NSString *root = nil;
      for (NSString *kv in env) if ([kv hasPrefix:@"SIMRUN_RUNTIME_ROOT="] && kv.length > 20) root = [kv substringFromIndex:20];
      r.runtimeRoot = root ?: SREnvironment.runtimeRoot;
      r.env = [SREnvironment environment:env withOverrides:[SREnvironment runtimeVariablesForRoot:r.runtimeRoot]];
      NSString *dir = [argv.firstObject stringByDeletingLastPathComponent];
      if ([dir.pathExtension isEqualToString:@"app"]) r.appPath = dir;   // lets the launcher show it as running
      r.sock = c; r.fd0 = got[0]; r.fd1 = got[1]; r.fd2 = got[2];
      // client gone (e.g. Ctrl-C) before the app exited -> terminate the app
      dispatch_source_t eof = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, c, 0, dispatch_get_main_queue());
      dispatch_source_set_event_handler(eof, ^{
        char b; if (recv(c, &b, 1, MSG_PEEK | MSG_DONTWAIT) == 0) { dispatch_source_cancel(eof); [r.session terminate]; }
      });
      dispatch_resume(eof); r.eofSource = eof;
      [self enqueue:r];
    });
  });
}

- (void)reply:(SRRequest *)r dict:(NSDictionary *)d {
  if (r.sock >= 0) simrund_send(r.sock, (__bridge CFDictionaryRef)d, NULL, 0);
}
- (void)closeClient:(SRRequest *)r {
  if (r.eofSource) { dispatch_source_cancel(r.eofSource); r.eofSource = nil; }
  if (r.sock >= 0) { close(r.sock); r.sock = -1; }
}

// ---------------------------------------------------------------- idle exit (headless --serve only)
- (void)scheduleIdleCheck {
  if (_mode != SRModeServe || _interactive || _active.count || _pending.count) return;
  const char *e = getenv("SIMRUND_IDLE");
  double idle = e ? atof(e) : 600;
  if (idle <= 0) return;
  [_idleTimer invalidate];
  _idleTimer = [NSTimer scheduledTimerWithTimeInterval:idle repeats:NO block:^(NSTimer *t) {
    if (!self->_interactive && !self->_active.count && !self->_pending.count) { LOG(@"idle for %.0f s, exiting", idle); [NSApp terminate:nil]; }
  }];
}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    SRMode mode = SRModeGUI;
    NSMutableArray *rest = [NSMutableArray array];
    if (argc >= 2 && !strcmp(argv[1], "--serve")) mode = SRModeServe;
    else if (argc >= 3 && !strcmp(argv[1], "--run")) { mode = SRModeRun; for (int i = 2; i < argc; i++) [rest addObject:@(argv[i])]; }
    else if (argc >= 2 && !strcmp(argv[1], "--run")) { fprintf(stderr, "usage: SimRun --run <sim-binary> [args...]\n"); return 2; }
    else for (int i = 1; i < argc; i++)   // GUI: app bundles to open; skip LaunchServices/AppKit flags (-psn_…, -NSFoo YES)
      if (argv[i][0] == '-') { if (strncmp(argv[i], "-psn_", 5) && i + 1 < argc && argv[i + 1][0] != '-') i++; }
      else [rest addObject:[@(argv[i]) stringByStandardizingPath]];
    NSApplication *app = [NSApplication sharedApplication];
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    SRServer *server = [[SRServer alloc] initWithMode:mode args:rest];
    app.delegate = server;
    [app run];
  }
}
