// scenes.dylib — in-process "FrontBoard host" for iOS-Simulator UIKit apps run as plain host processes.
//
// Injected with DYLD_INSERT_LIBRARIES (see run.sh). No Mach services are needed.
//
// How it works (see SCENES.md):
//  * UIKit's _UIApplicationMainPreparations calls FBSWorkspaceInitialize(options{delegate=UIApp}) (cross-image ->
//    interposable). We call the original, then register an extra "scenes source" with the FBSWorkspace: a
//    FBSWorkspaceScenesClient whose BSServiceConnection is a local fake (SRFakeConnection). Its remoteTarget is
//    SRFakeHost, an in-process implementation of <FBSWorkspaceServiceClientInterface> (what SpringBoard/FrontBoard
//    would implement).
//  * We then invoke, on the workspace queue, the same <FBSWorkspaceServiceServerInterface> method SpringBoard would
//    send over XPC: -[FBSWorkspaceScenesClient createSceneWithIdentity:parameters:transitionContext:completion:].
//    FrontBoardServices builds the FBSScene, calls UIApplicationSceneClientAgent -> -[UIApplication
//    workspace:didCreateScene:...] -> UIWindowScene + scene delegate -scene:willConnectToSession:options:.
//  * Later settings changes (resize, foreground/background, orientation) go through
//    -[FBSWorkspaceScenesClient sceneID:updateWithSettingsDiff:transitionContext:completion:] (SRScenesUpdate()).
//
// Also (each independent, see SCENES.md):
//  * BKSDisplayServicesStart stub + GSSetMainScreenInfo (no backboardd).
//  * os_trace_set_mode fix: NSLog/os_log visible with OS_ACTIVITY_DT_MODE=1 even in null-bootstrap mode.
//  * BackBoard HID BSService endpoint ("com.apple.backboard.hid-services.xpc") -> in-process anonymous XPC sink.
//  * No com.apple.runningboard: RBS assertion acquisition fails at once instead of a sleep-and-retry (~100 ms of launch).
//  * No LaunchServices: -[UTType conformsToType:nil] (unresolvable type) is NO instead of an assertion (drag & drop).
//  * Only when there is no CARenderServer: +[CADisplay displays] -> @[] (skips a 5 s retry loop), synthesized main
//    FBSDisplayConfiguration for UIScreen, remote CAContext -> local CAContext fallback.
// Exported API (scenes.h): SRScenesCreate, SRScenesUpdate, SRScenesSetLayersCallback, SRScenesGetMainContextID.
// Env: SCENES_W/SCENES_H/SCENES_SCALE (default 402x874@3), SCENES_NO_AUTOCREATE, SCENES_CREATE_DELAY=sec,
//      SCENES_DEMO_UPDATES, SCENES_VERBOSE, SCENES_DISABLE, SCENES_NO_SINK, SCENES_NO_SYNTH_DISPLAY, SCENES_KEEP_CADISPLAY.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <os/log.h>
#include <mach/mach.h>

#define LOG(fmt, ...) fprintf(stderr, "[scenes] " fmt "\n", ##__VA_ARGS__)

// ---------------------------------------------------------------- private API declarations
@interface NSObject (SRPrivate)
// FBSWorkspace / BSServiceQueue
- (void)performAsync:(dispatch_block_t)b;
- (void)performAsyncAndWait:(dispatch_block_t)b;
// FBSWorkspaceScenesClient
- (void)_registerSource:(id)source;
- (id)delegate;
+ (id)nullEndpointForService:(NSString *)service instance:(NSString *)instance;
+ (NSString *)identifier;
- (void)handshakeWithRemnants:(id)r;
- (void)createSceneWithIdentity:(id)identity parameters:(id)params transitionContext:(id)tc completion:(void (^)(id))c;
- (void)sceneID:(id)sceneIdentity updateWithSettingsDiff:(id)diff transitionContext:(id)tc completion:(void (^)(id))c;
// FBSSceneIdentity / parameters / settings
+ (id)identityForIdentifier:(NSString *)i workspaceIdentifier:(NSString *)w;
+ (id)parametersForSpecification:(id)spec;
+ (id)specification;
- (void)updateSettingsWithBlock:(void (^)(id))b;
- (void)setDisplay:(id)displayConfiguration;
- (id)settings;
- (id)mutableCopy;
+ (id)diffFromSettings:(id)a toSettings:(id)b;
- (id)displayConfiguration;
- (id)sceneWithIdentity:(id)identity;
- (id)clientSettings;
- (id)layers;
- (uint32_t)contextID;
- (void)_updateDisplayConfiguration:(id)c;
@end
// UIMutableApplicationSceneSettings / FBSMutableSceneSettings setters
@protocol SRMutableSceneSettings
- (void)setFrame:(CGRect)f;
- (void)setLevel:(double)l;
- (void)setInterfaceOrientation:(long long)o;
- (void)setForeground:(BOOL)f;
- (void)setDeactivationReasons:(unsigned long long)r;
- (void)setDeviceOrientation:(long long)o;
- (void)setUserInterfaceStyle:(long long)s;
- (void)setCanShowAlerts:(BOOL)b;
- (void)setStatusBarHeight:(double)h;
- (void)setDefaultStatusBarHeight:(double)h forOrientation:(long long)o;
- (void)setSafeAreaInsetsPortrait:(UIEdgeInsets)i;
- (void)setSafeAreaInsetsPortraitUpsideDown:(UIEdgeInsets)i;
- (void)setSafeAreaInsetsLandscapeLeft:(UIEdgeInsets)i;
- (void)setSafeAreaInsetsLandscapeRight:(UIEdgeInsets)i;
- (void)setPersistenceIdentifier:(NSString *)p;
@end

static void SRSetIvar(id obj, const char *name, id value);
static id SRSynthMainDisplayConfiguration(void);

// ---------------------------------------------------------------- config
static CGFloat gW = 402, gH = 874, gScale = 3;
static NSString *gSceneID;
static id gWorkspace, gScenesClient, gHost, gConn, gIdentity;
static id gCurrentSettings; // last settings we sent (immutable FBSSceneSettings subclass)
static BOOL gNoRenderServer;

// ---------------------------------------------------------------- fake host (<FBSWorkspaceServiceClientInterface>)
static void SRCallBlockWithNils(id blk) {
  if (!blk) return;
  ((void (^)(id, id))blk)(nil, nil); // completion blocks here take (error) or (response, error); extra nil is harmless
}

// Integrator API: get told which CAContext IDs the scene wants displayed (FBSSceneClientSettings.layers), i.e. what a
// host would wrap in CALayerHost(contextId). Called on the FBS workspace queue whenever the client settings change.
typedef void (*SRScenesLayersCallback)(const uint32_t *contextIDs, const double *levels, size_t count, void *ctx);
static SRScenesLayersCallback gLayersCB; static void *gLayersCtx;
__attribute__((visibility("default"))) void SRScenesSetLayersCallback(SRScenesLayersCallback cb, void *ctx) { gLayersCB = cb; gLayersCtx = ctx; }
static uint32_t gMainContextID;
__attribute__((visibility("default"))) uint32_t SRScenesGetMainContextID(void) { return gMainContextID; }

static void SRReportLayers(void) {
  id scene = [gScenesClient sceneWithIdentity:gIdentity];
  id cs = [scene clientSettings];
  id layers = [cs respondsToSelector:@selector(layers)] ? ((id (*)(id, SEL))objc_msgSend)(cs, @selector(layers)) : nil; // NSOrderedSet<FBSSceneLayer *>
  uint32_t ids[16]; double lv[16]; size_t n = 0;
  for (id l in layers) {
    if (n == 16) break;
    if ([l respondsToSelector:@selector(contextID)]) { ids[n] = [l contextID]; lv[n] = ((double (*)(id, SEL))objc_msgSend)(l, @selector(level)); n++; }
  }
  uint32_t main = n ? ids[0] : 0;
  if (main != gMainContextID) LOG("scene layers: %zu, main CAContext id 0x%x", n, main);
  gMainContextID = main;
  if (gLayersCB) gLayersCB(ids, lv, n, gLayersCtx);
}

@interface SRFakeHost : NSObject
@end
@implementation SRFakeHost
- (void)handshakeWithRemnants:(id)remnants { LOG("host <- handshakeWithRemnants: %s", [[remnants description] UTF8String]); }
- (void)sceneID:(id)sid didUpdateClientSettingsWithDiff:(id)diff transitionContext:(id)tc completion:(void (^)(id))c {
  if (getenv("SCENES_VERBOSE")) LOG("host <- sceneID:%s didUpdateClientSettingsWithDiff: %s", [[sid description] UTF8String], [[diff description] UTF8String]);
  SRReportLayers();
  if (c) c(nil);
}
- (void)sceneID:(id)sid didReceiveActions:(NSSet *)actions forExtension:(id)ext {
  LOG("host <- sceneID:%s didReceiveActions: %s", [[sid description] UTF8String], [[actions description] UTF8String]);
}
- (void)sceneID:(id)sid invalidateWithContext:(id)ctx clientError:(id)err {
  LOG("host <- sceneID:%s invalidateWithContext: err=%s", [[sid description] UTF8String], [[err description] UTF8String]);
}
- (void)sceneID:(id)sid sendMessage:(id)msg withResponse:(id)resp { LOG("host <- sceneID:%s sendMessage: %s", [[sid description] UTF8String], [[msg description] UTF8String]); SRCallBlockWithNils(resp); }
- (void)sceneID:(id)sid handleInvocation:(id)inv completion:(id)c { LOG("host <- sceneID:%s handleInvocation:", [[sid description] UTF8String]); SRCallBlockWithNils(c); }
- (void)workspaceID:(id)wid sendActions:(id)actions completion:(id)c { LOG("host <- workspaceID:sendActions: %s", [[actions description] UTF8String]); SRCallBlockWithNils(c); }
- (void)requestSceneWithOptions:(id)opts completion:(id)c { LOG("host <- requestSceneWithOptions: %s (unsupported)", [[opts description] UTF8String]); SRCallBlockWithNils(c); }
- (void)createSceneWithOptions:(id)opts completion:(id)c { LOG("host <- createSceneWithOptions: %s (unsupported)", [[opts description] UTF8String]); SRCallBlockWithNils(c); }
// catch-all so an unexpected message can't crash the app
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
  NSMethodSignature *m = [super methodSignatureForSelector:s];
  return m ?: [NSMethodSignature signatureWithObjCTypes:"v@:@@@@"];
}
- (void)forwardInvocation:(NSInvocation *)inv { LOG("host <- UNHANDLED %s", sel_getName(inv.selector)); }
@end

// ---------------------------------------------------------------- fake BSServiceConnection (also acts as its own config)
@interface SRFakeConnection : NSObject
@property (strong) id localTarget, queue, interface, serviceQuality, activationHandler, interruptionHandler, invalidationHandler, batchingHandler;
@end
@implementation SRFakeConnection
- (void)configure:(void (^)(id))block { if (block) block(self); }
- (void)activate { LOG("conn activate"); }
- (void)invalidate { LOG("conn invalidate"); }
- (id)remoteTarget { return gHost; }
- (id)immediateMessagingRemoteTargetWithLaunchingAssertionAttributes:(id)a { return gHost; }
- (id)activeMessageBatch { return nil; }
- (id)remoteToken { return nil; }
- (id)remoteProcess { return nil; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
  NSMethodSignature *m = [super methodSignatureForSelector:s];
  return m ?: [NSMethodSignature signatureWithObjCTypes:"@@:@@@@"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
  LOG("conn <- UNHANDLED %s", sel_getName(inv.selector));
  id nilv = nil; if (inv.methodSignature.methodReturnLength == sizeof(id)) [inv setReturnValue:&nilv];
}
@end

// ---------------------------------------------------------------- scene settings
static void SRApplySettings(id<SRMutableSceneSettings> s, CGFloat w, CGFloat h, BOOL foreground, UIInterfaceOrientation orient) {
  [s setFrame:CGRectMake(0, 0, w, h)];
  [s setLevel:1];
  [s setInterfaceOrientation:orient];
  [s setForeground:foreground];
  if ([(id)s respondsToSelector:@selector(setDeactivationReasons:)]) {
    [s setDeactivationReasons:0];
    [s setDeviceOrientation:orient];
    [s setUserInterfaceStyle:UIUserInterfaceStyleLight];
    [s setCanShowAlerts:YES];
    [s setStatusBarHeight:62];
    [s setDefaultStatusBarHeight:62 forOrientation:UIInterfaceOrientationPortrait];
    [s setSafeAreaInsetsPortrait:UIEdgeInsetsMake(62, 0, 34, 0)];
    [s setSafeAreaInsetsPortraitUpsideDown:UIEdgeInsetsMake(34, 0, 62, 0)];
    [s setSafeAreaInsetsLandscapeLeft:UIEdgeInsetsMake(0, 62, 21, 62)];
    [s setSafeAreaInsetsLandscapeRight:UIEdgeInsetsMake(0, 62, 21, 62)];
    [s setPersistenceIdentifier:gSceneID];
  }
}

static void SRCreateScene(void);
// Integrator API: create the scene yourself (set SCENES_NO_AUTOCREATE=1 to disable the automatic one). Size in points
// (portrait / display-native coordinates). Safe to call from any thread once UIApplicationMain has started.
__attribute__((visibility("default"))) void SRScenesCreate(CGFloat w, CGFloat h) {
  gW = w; gH = h;
  [[gWorkspace valueForKey:@"_queue"] performAsync:^{ SRCreateScene(); }];
}

static void SRCreateScene(void) {
  Class SpecC = NSClassFromString(@"UIApplicationSceneSpecification");
  Class ParamsC = NSClassFromString(@"FBSMutableSceneParameters");
  Class IdentityC = NSClassFromString(@"FBSSceneIdentity");
  Class TCC = NSClassFromString(@"UIApplicationSceneTransitionContext");
  id spec = [SpecC specification];
  id params = [ParamsC parametersForSpecification:spec];
  // When a render server exists UIScreen.mainScreen is backed by an FBSDisplayConfiguration; the scene must use the
  // same display identity. Without one, mainScreen has displayIdentity nil and a nil display config maps to it.
  id dc = [[UIScreen mainScreen] displayConfiguration];
  if (dc) [params setDisplay:dc];
  [params updateSettingsWithBlock:^(id s) { SRApplySettings(s, gW, gH, YES, UIInterfaceOrientationPortrait); }];
  gCurrentSettings = [[params settings] copy];
  id identity = gIdentity = [IdentityC identityForIdentifier:gSceneID workspaceIdentifier:@"com.apple.frontboard.systemappservices"];
  id tc = [TCC new];
  LOG("createScene %s %gx%g@%g display=%s", gSceneID.UTF8String, gW, gH, gScale, dc ? "main" : "nil");
  [gScenesClient createSceneWithIdentity:identity parameters:params transitionContext:tc completion:^(id err) {
    LOG("createScene completion err=%s", [[err description] UTF8String]);
  }];
}

// Public helper for the integrator: change the scene's size / foreground / orientation (call on any thread).
__attribute__((visibility("default")))
void SRScenesUpdate(CGFloat w, CGFloat h, BOOL foreground, long orient) {
  [[gWorkspace valueForKey:@"_queue"] performAsync:^{
    id m = [gCurrentSettings mutableCopy];
    SRApplySettings(m, w, h, foreground, orient);
    id newSettings = [m copy];
    id diff = [NSClassFromString(@"FBSSceneSettingsDiff") diffFromSettings:gCurrentSettings toSettings:newSettings];
    gCurrentSettings = newSettings;
    LOG("updateScene %gx%g fg=%d orient=%ld", w, h, foreground, (long)orient);
    [gScenesClient sceneID:gIdentity updateWithSettingsDiff:diff
         transitionContext:[NSClassFromString(@"UIApplicationSceneTransitionContext") new]
                completion:^(id err) { if (err) LOG("updateScene err=%s", [[err description] UTF8String]); }];
  }];
}

static void SRSetIvar(id obj, const char *name, id value) {
  Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
  if (!iv) { LOG("missing ivar %s on %s", name, object_getClassName(obj)); abort(); }
  object_setIvarWithStrongDefault(obj, iv, value);
}

// ---------------------------------------------------------------- FBSWorkspaceInitialize hook
extern id FBSWorkspaceInitialize(id options);
static id my_FBSWorkspaceInitialize(id options) {
  id ws = FBSWorkspaceInitialize(options);
  if (getenv("SCENES_DISABLE")) return ws;
  gWorkspace = ws;
  // No render server: UIScreen's main screen was built with a nil FBSDisplayConfiguration (bounds 0x0, scale 1).
  // Give it a synthesized one (UIScreen +initialize calls its designated init directly, so patch afterwards).
  if (gNoRenderServer && !getenv("SCENES_NO_SYNTH_DISPLAY") && ![[UIScreen mainScreen] displayConfiguration])
    [[UIScreen mainScreen] _updateDisplayConfiguration:SRSynthMainDisplayConfiguration()];
  id q = [ws valueForKey:@"_queue"];          // BSServiceDispatchQueue "com.apple.frontboardservices.workspace"
  id cq = [ws valueForKey:@"_callOutQueue"];  // UIKit's main-thread callout queue
  gHost = [SRFakeHost new];
  gConn = [SRFakeConnection new];
  // FBSWorkspaceScenesClient's initializers, queue_activate and _queue_sendHandshake are objc_direct (not callable
  // via objc_msgSend), so build the object by hand: alloc + ivars exactly as
  // -_initWithIdentifier:connection:queue:calloutQueue:workspace: and a completed handshake would leave them.
  Class IdC = NSClassFromString(@"FBSWorkspaceScenesClientIdentifier");
  id ident = [IdC new];
  // FBSSceneIdentityToken needs a non-nil host endpoint; a BoardServices "null endpoint" for the workspace service
  // is a valid object that never connects (nothing ever connects it here anyway).
  id ep = [NSClassFromString(@"BSServiceConnectionEndpoint")
      nullEndpointForService:[NSClassFromString(@"FBSWorkspaceServiceSpecification") identifier] instance:nil];
  SRSetIvar(ident, "_hostEndpoint", ep);
  SRSetIvar(ident, "_description", @"simrun-local-host");
  id c = class_createInstance(NSClassFromString(@"FBSWorkspaceScenesClient"), 0);
  SRSetIvar(c, "_workspace", ws);
  SRSetIvar(c, "_workspaceDelegate", [ws delegate]);
  SRSetIvar(c, "_queue", q);
  SRSetIvar(c, "_callOutQueue", cq);
  SRSetIvar(c, "_connection", gConn);
  SRSetIvar(c, "_identifier", ident);
  SRSetIvar(c, "_scenesByIdentity", [NSMutableDictionary dictionary]);
  SRSetIvar(c, "_clientSettingsByIdentity", [NSMutableDictionary dictionary]);
  SRSetIvar(c, "_reconnectingScenes", [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory]);
  SRSetIvar(c, "_pendedSendBlocks", nil); // nil == handshake done (sends go straight to the remote target)
  SRSetIvar(c, "_hostEvent_pendingEvents", [NSMutableArray array]);
  SRSetIvar(c, "_reportingLock_scenesByIdentity", [NSMutableDictionary dictionary]);
  SRSetIvar(c, "_handshakeLock_remoteTarget", gHost);
  *(BOOL *)((char *)(__bridge void *)c + ivar_getOffset(class_getInstanceVariable(object_getClass(c), "_activated"))) = YES;
  gScenesClient = c;
  [ws _registerSource:c]; // -> -[FBSWorkspace _queue_registerSource:] on the workspace queue
  [gHost handshakeWithRemnants:nil];
  LOG("local scenes source registered: %s", [[gScenesClient description] UTF8String]);
  const char *delay = getenv("SCENES_CREATE_DELAY"); // seconds; exercises SRScenesCreate() from the main queue
  if (delay) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ SRScenesCreate(gW, gH); });
  else if (!getenv("SCENES_NO_AUTOCREATE")) [q performAsync:^{ SRCreateScene(); }];
  if (getenv("SCENES_DEMO_UPDATES")) { // exercise SRScenesUpdate: resize, rotate, background, foreground
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SRScenesUpdate(600, 800, YES, UIInterfaceOrientationPortrait); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SRScenesUpdate(402, 874, YES, UIInterfaceOrientationLandscapeRight); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SRScenesUpdate(402, 874, NO, UIInterfaceOrientationLandscapeRight); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SRScenesUpdate(402, 874, YES, UIInterfaceOrientationPortrait); });
  }
  return ws;
}

// ---------------------------------------------------------------- BackBoard display services stub
extern Boolean BKSDisplayServicesStart(void);
extern void GSSetMainScreenInfo(double pixelW, double pixelH, float scale, float orientation);
static Boolean my_BKSDisplayServicesStart(void) {
  GSSetMainScreenInfo(gW * gScale, gH * gScale, (float)gScale, 0.0f);
  LOG("BKSDisplayServicesStart stubbed (main screen %gx%g px @%g)", gW * gScale, gH * gScale, gScale);
  return 1;
}

// ---------------------------------------------------------------- logging fix
// libxpc's initializer calls os_trace_set_mode(0x100 = disabled) when it runs in null-bootstrap mode (no
// launchd_sim); that kills os_log/NSLog entirely, even with OS_ACTIVITY_DT_MODE. Drop that bit.
extern void os_trace_set_mode(uint32_t mode);
static void my_os_trace_set_mode(uint32_t mode) { os_trace_set_mode(mode & ~0x100u); }

__attribute__((used, section("__DATA,__interpose"))) static struct { void *n, *o; } interposers[] = {
  { (void *)my_BKSDisplayServicesStart, (void *)BKSDisplayServicesStart },
  { (void *)my_os_trace_set_mode, (void *)os_trace_set_mode },
  { (void *)my_FBSWorkspaceInitialize, (void *)FBSWorkspaceInitialize },
};

// ---------------------------------------------------------------- no render server: skip CA's 5 s display query
extern mach_port_t CARenderServerGetServerPort(void);
static id sr_empty_displays(id self, SEL _cmd) { return @[]; }
static id sr_nil_display(id self, SEL _cmd) { return nil; }
// UIKit requires +[CAContext remoteContextWithOptions:] to succeed (else "Failed to create remote render context"
// assertion). Without a render server, fall back to a local context so the scene/window lifecycle can proceed.
static IMP gOrigRemoteContext;
static id sr_remoteContextWithOptions(id self, SEL _cmd, NSDictionary *opts) {
  id c = ((id (*)(id, SEL, NSDictionary *))gOrigRemoteContext)(self, _cmd, opts);
  if (!c) {
    static int once; if (!once++) LOG("no render server: remoteContextWithOptions -> localContextWithOptions (nothing will be displayed)");
    c = ((id (*)(id, SEL, NSDictionary *))objc_msgSend)(self, NSSelectorFromString(@"localContextWithOptions:"), opts);
  }
  return c;
}

// BKSHIDEventDeliveryManager / BKSHIDEventObserver (used by UIKit's key-window / event-deferring code during
// -makeKeyAndVisible) need a live BSServiceConnection to "com.apple.backboard.hid-services.xpc": a nil endpoint is a
// hard assert, and an invalidated connection makes BKSHIDEventObserver exit() ("backboardd must have unloaded").
// When the Mach service can't be resolved we hand out an endpoint for an in-process *anonymous* XPC listener that
// accepts connections and swallows every message ("sink"). The HID/input workstream replaces this with a real
// in-process BackBoard HID service.
#include <xpc/xpc.h>
static NSMutableArray *gSinkPeers;
static id SRSinkEndpoint(NSString *mach, NSString *service, NSString *instance) {
  static xpc_connection_t listener; static dispatch_queue_t q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gSinkPeers = [NSMutableArray array];
    q = dispatch_queue_create("dev.simrun.scenes.sink", DISPATCH_QUEUE_SERIAL);
    listener = xpc_connection_create(NULL, q); // anonymous listener, no launchd needed
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
      if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
      [gSinkPeers addObject:peer];
      xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
        if (getenv("SCENES_VERBOSE")) { char *d = xpc_copy_description(msg); LOG("sink <- %.300s", d); free(d); }
      });
      xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
  });
  id x = class_createInstance(NSClassFromString(@"BSXPCServiceConnectionEndpoint"), 0);
  SRSetIvar(x, "_xpcEndpoint", (id)xpc_endpoint_create(listener));
  SRSetIvar(x, "_targetDescription", [@"sink:" stringByAppendingString:mach]);
  id e = class_createInstance(NSClassFromString(@"BSServiceConnectionEndpoint"), 0);
  SRSetIvar(e, "_service", service);
  SRSetIvar(e, "_instance", instance);
  SRSetIvar(e, "_underlyingEndpoint", x);
  return e;
}
static IMP gOrigEndpointForMachName;
static id sr_endpointForMachName(id self, SEL _cmd, NSString *mach, NSString *service, NSString *instance) {
  id e = ((id (*)(id, SEL, id, id, id))gOrigEndpointForMachName)(self, _cmd, mach, service, instance);
  if (!e && [mach isEqualToString:@"com.apple.backboard.hid-services.xpc"] && !getenv("SCENES_NO_SINK")) {
    LOG("no %s: in-process sink endpoint for BS service %s", mach.UTF8String, service.UTF8String);
    e = SRSinkEndpoint(mach, service, instance);
  }
  return e;
}

// No runningboardd: -[RBSConnection acquireAssertion:error:] retries forever, sleeping between tries, while the reply
// is NSXPCConnectionReplyInvalid (4101) — which the first attempt on a connection to the missing service sometimes
// returns, depending on timing. UIKit acquires its launch background task this way, and the main thread waits for
// that (_UIApplicationWaitForBackgroundAssertionsToFlush): ~100 ms of most launches. Fail at once, with the error the
// retried attempt ends with anyway.
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *out);
static IMP gOrigAcquireAssertion;
static id sr_acquireAssertion(id self, SEL _cmd, id assertion, NSError **error) {
  static BOOL missing; static dispatch_once_t once;
  dispatch_once(&once, ^{
    mach_port_t p = MACH_PORT_NULL;
    missing = bootstrap_look_up(bootstrap_port, "com.apple.runningboard", &p) != KERN_SUCCESS;
    if (p) mach_port_deallocate(mach_task_self(), p);
  });
  if (!missing) return ((id (*)(id, SEL, id, NSError **))gOrigAcquireAssertion)(self, _cmd, assertion, error);
  if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSXPCConnectionInvalid
                                      userInfo:@{ NSLocalizedFailureReasonErrorKey: @"no runningboardd (SimRun)" }];
  return nil;
}

// No LaunchServices (lsd and its containermanagerd chain don't run): UTType resolves only the built-in core types, so
// +[UTType typeWithIdentifier:] (even _typeWithIdentifier:allowUndeclared:YES) returns nil for anything else, e.g.
// UIKit's own com.apple.uikit.useractivity. Callers that assume a type, like the drag statistics logged when a drag
// begins, then hit -conformsToType:'s "type != nil" assertion and crash the app. A type that can't be resolved
// conforms to nothing.
static IMP gOrigConformsToType;
static BOOL sr_conformsToType(id self, SEL _cmd, id type) {
  return type ? ((BOOL (*)(id, SEL, id))gOrigConformsToType)(self, _cmd, type) : NO;
}

// Without a render server UIKit creates the main UIScreen with a nil FBSDisplayConfiguration -> bounds {0,0},
// scale 1. Synthesize a main-display configuration (what FrontBoardServices would build from the main CADisplay) so
// UIScreen / trait displayScale are right. Only used when CADisplay has no displays.
static id SRSynthMainDisplayConfiguration(void) {
  static id cfg; if (cfg) return cfg;
  unsigned long long pw = (unsigned long long)(gW * gScale), ph = (unsigned long long)(gH * gScale);
  id ident = ((id (*)(id, SEL, long long, BOOL, unsigned, long long, unsigned, int, BOOL, id, BOOL, BOOL, id))objc_msgSend)(
      [NSClassFromString(@"FBSDisplayIdentity") alloc],
      NSSelectorFromString(@"_initWithType:UIKitMainLike:displayID:connectionType:connectionSeed:pid:external:uniqueIdentifier:secure:alwaysConnected:root:"),
      0 /*main*/, YES, 1, 0, 0, 0, NO, nil, NO, YES, nil);
  id mode = ((id (*)(id, SEL, unsigned long long, unsigned long long, unsigned long long, double, double, long long, long long, long long, BOOL, long long))objc_msgSend)(
      [NSClassFromString(@"FBSDisplayMode") alloc],
      NSSelectorFromString(@"_initWithWidth:height:preferredScale:scaleOverride:refreshRate:gamut:hdr:rotation:virtual:validityCheck:"),
      pw, ph, (unsigned long long)gScale, 0.0, 60.0, 0, 0, 0, NO, 0);
  id density = ((id (*)(id, SEL, double, double))objc_msgSend)([NSClassFromString(@"FBSDisplayPixelDensity") alloc],
      NSSelectorFromString(@"initWithHorizontalPixelsPerInch:verticalPixelsPerInch:"), 460.0, 460.0);
  cfg = ((id (*)(id, SEL, id, id, id, id, unsigned, BOOL, long long, id, id, id, BOOL, BOOL, long long, CGSize, CGSize, CGRect, CGRect, id, double, id, long long))objc_msgSend)(
      [NSClassFromString(@"FBSDisplayConfiguration") alloc],
      NSSelectorFromString(@"_initWithIdentity:hardwareIdentifier:name:deviceName:seed:comparable:tags:currentMode:preferredMode:otherModes:cloningSupported:overscanned:overscanCompensation:safeOverscanRatio:pixelSize:nativeBounds:bounds:pixelDensity:latency:originatingConfiguration:validityCheck:"),
      ident, nil, @"Main", @"SimRun", 1, YES, 0, mode, mode, [NSSet set], NO, NO, 0,
      CGSizeMake(1, 1), CGSizeMake(pw, ph), CGRectMake(0, 0, pw, ph), CGRectMake(0, 0, gW, gH), density, 0.0, nil, 0);
  LOG("synthesized main display configuration: %s", [[cfg description] UTF8String]);
  return cfg;
}
__attribute__((constructor)) static void scenes_init(void) {
  {
    Method m = class_getClassMethod(NSClassFromString(@"BSServiceConnectionEndpoint"), NSSelectorFromString(@"endpointForMachName:service:instance:"));
    gOrigEndpointForMachName = method_setImplementation(m, (IMP)sr_endpointForMachName);
    Method a = class_getInstanceMethod(NSClassFromString(@"RBSConnection"), NSSelectorFromString(@"acquireAssertion:error:"));
    if (a) gOrigAcquireAssertion = method_setImplementation(a, (IMP)sr_acquireAssertion);
    Method c = class_getInstanceMethod(NSClassFromString(@"UTType"), @selector(conformsToType:));
    if (c) gOrigConformsToType = method_setImplementation(c, (IMP)sr_conformsToType);
  }
  const char *e;
  if ((e = getenv("SCENES_W"))) gW = atof(e);
  if ((e = getenv("SCENES_H"))) gH = atof(e);
  if ((e = getenv("SCENES_SCALE"))) gScale = atof(e);
  gSceneID = [NSString stringWithFormat:@"sceneID:%@-default", NSBundle.mainBundle.bundleIdentifier ?: @"app"];
  // +[CADisplay displays] retries a missing render server for 5 s (usleep loop) and then returns @[] anyway.
  // If there is no render server, short-circuit it (same result, no delay). The render workstream replaces this.
  if (!getenv("SCENES_KEEP_CADISPLAY") && CARenderServerGetServerPort() == MACH_PORT_NULL) {
    Class meta = object_getClass(NSClassFromString(@"CADisplay"));
    method_setImplementation(class_getClassMethod(NSClassFromString(@"CADisplay"), @selector(displays)), (IMP)sr_empty_displays);
    Method m = class_getClassMethod(NSClassFromString(@"CADisplay"), NSSelectorFromString(@"mainDisplay"));
    if (m) method_setImplementation(m, (IMP)sr_nil_display);
    Method rc = class_getClassMethod(NSClassFromString(@"CAContext"), NSSelectorFromString(@"remoteContextWithOptions:"));
    gOrigRemoteContext = method_setImplementation(rc, (IMP)sr_remoteContextWithOptions);
    (void)meta;
    gNoRenderServer = YES;
    LOG("no CARenderServer: +[CADisplay displays] -> @[]");
  }
}
