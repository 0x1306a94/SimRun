# scenes/ — application lifecycle & UIWindowScene delivery without SpringBoard

Status: **working.** A scene-based sim UIKit app launched with `simrun.sh` (no launchd_sim, no backboardd, no
SpringBoard, no runningboardd) gets `application:didFinishLaunchingWithOptions:`, then
`scene:willConnectToSession:options:` with a `UIWindowScene` of the size we choose (default 402x874 pt @3x). It
then becomes foreground-active and the main run loop keeps going. Resize, rotation and foreground/background
transitions also work. Tested in null-bootstrap mode and under `launchd/simns`; also tested with the SwiftUI
`../sim2mac/SUI.app`.

```
./build.sh                    # builds Hello.app (app.m = ../main.m + lifecycle logging) and scenes.dylib
./run.sh                      # null-bootstrap mode (simrun.sh + DYLD_INSERT_LIBRARIES=scenes.dylib)
SCENES_NS=1 ./run.sh          # same, under ../launchd/simns
SCENES_DEMO_UPDATES=1 ./run.sh   # also resizes to 600x800, rotates to landscape, backgrounds, foregrounds
SCENES_W=390 SCENES_H=844 ./run.sh   # choose the scene/screen size (points); SCENES_SCALE (default 3)
./run.sh ../../sim2mac/SUI.app/SUI   # any other sim app binary
./dbg.sh script.lldb          # lldb with the dylib injected into the target only
```
Output from `sample_output.txt`:
```
[scenes] BKSDisplayServicesStart stubbed (main screen 1206x2622 px @3)
[scenes] local scenes source registered: <FBSWorkspaceScenesClient: 0x101875180>
[scenes] createScene sceneID:dev.cyan.hello-default 402x874@3 display=main
Hello[63369] didFinishLaunching
Hello[63369] scene willConnect: <UIWindowScene ...; persistentIdentifier: sceneID:dev.cyan.hello-default; ...> bounds={{0, 0}, {402, 874}} scale=3
[scenes] scene layers: 1, main CAContext id 0x3f39f436
Hello[63369] window {{0, 0}, {402, 874}} key=1
Hello[63369] heartbeat 1: appState=0 state=0 bounds={{0, 0}, {402, 874}} orient=1 screen={{0, 0}, {402, 874}} scale=3 traits.displayScale=3
```
The time from process start to willConnect is about 0.5 s.

## 1. How UIKit gets its scenes (sim UIKit 9127.0.85.27 / FrontBoardServices, iOS 27.1 sim runtime)

```
UIApplicationMain
 └ _UIApplicationMainPreparations
     BKSDisplayServicesStart()                      -> GSSetMainScreenInfo(pixelW, pixelH, scale, orientation)
     UIApplicationInstantiateSingleton
     opts = [FBSWorkspaceInitializationOptions optionsWithDelegate:UIApp]; opts.callOutQueue = main-thread BSServiceQueue
     FBSWorkspaceInitialize(opts)                   <- C export of FrontBoardServices, called cross-image: INTERPOSABLE
        -[FBSWorkspace _initWithCoupler:options:]   ivars: _queue (BSServiceDispatchQueue "com.apple.frontboardservices.workspace"),
                                                    _callOutQueue (main), _queue_identifierToScenesSource, _defaultShellEndpoint
        defaultShellEndpoint = BSServiceConnectionEndpoint for "com.apple.frontboard.systemappservices"
                               (fails without SpringBoard: "Failed to resolve default shell endpoint")
        else: a FBSWorkspaceScenesClient (one per host = "scenes source") over a BSServiceConnection
 └ -[UIApplication _run]
     scene-based apps: lifecycleWantsUnnecessaryDelayForSceneDelivery == NO
     -> _compellApplicationLaunchToCompleteUnconditionally -> _runWithMainScene:nil -> didFinishLaunchingWithOptions
        (this does NOT need a scene; we already got here before this work)
     -> GSEventRunModal (main run loop)
host (SpringBoard) -> app over XPC, protocol <FBSWorkspaceServiceServerInterface> (implemented by FBSWorkspaceScenesClient):
     -createSceneWithIdentity:parameters:transitionContext:completion:
        _createSceneWithIdentity:parameters: -> FBSScene _initWithUpdater:identityToken:identity:parameters:hostHandle:
        _callOutQueue_sendDidCreateForScene -> -[FBSScene _callOutQueue_didCreateWithTransitionContext:alternativeCreationCallout:completion:]
        -> agent (spec.clientAgentClass = UIApplicationSceneClientAgent) -scene:didInitializeWithEvent:completion:
        -> -[UIApplication workspace:didCreateScene:withTransitionContext:completion:]   (asserts main queue)
           settings.displayConfiguration -> +[UIScreen _FBSDisplayConfigurationConnected:andNotify:]
           settings.displayIdentity      -> +[UIScreen _screenWithFBSDisplayIdentity:]
           -_connectUISceneFromFBSScene:transitionContext: -> +[UIScene _sceneForFBSScene:create:withSession:connectionOptions:]
           -> UIApplicationDelegate configurationForConnectingSceneSession -> scene delegate -scene:willConnectToSession:options:
     -sceneID:updateWithSettingsDiff:transitionContext:completion:   (resize, orientation, foreground, ...)
     -sceneID:destroyWithTransitionContext:completion:, -sceneID:sendActions:..., -sendActions:..., -willTerminate...
app -> host, protocol <FBSWorkspaceServiceClientInterface> (sent to the connection's remoteTarget):
     -handshakeWithRemnants:, -sceneID:didUpdateClientSettingsWithDiff:transitionContext:completion: (layers = CAContext ids,
     status bar, etc.), -sceneID:didReceiveActions:forExtension:, -sceneID:invalidateWithContext:clientError:,
     -requestSceneWithOptions:completion:, -createSceneWithOptions:completion:, -workspaceID:sendActions:completion:, ...
```
This is the same entry point the Mac Catalyst backtrace showed (`FBSWorkspaceScenesClient
createSceneWithIdentity:...`). On Catalyst, AppKit plays the host role in-process. Note: **every `sceneID:` argument in
both protocols is an `FBSSceneIdentity`, not an NSString.**

## 2. Approach chosen: an in-process FrontBoard host (option 1, done at the FBS protocol level)

`scenes.dylib` (shim.m), interposing `FBSWorkspaceInitialize`:
1. Call the original, which returns the FBSWorkspace.
2. Build a `FBSWorkspaceScenesClient` **by hand**: `class_createInstance` plus ivars. Its initializers, `queue_activate`
   and `_queue_sendHandshake` are `objc_direct`, so they can't be messaged. The ivars are set exactly as
   `-_initWithIdentifier:connection:queue:calloutQueue:workspace:` and a completed handshake leave them:
   - `_connection` = `SRFakeConnection`. It answers `configure:` (by passing itself as the config), `activate`,
     `remoteTarget`, `immediateMessagingRemoteTargetWithLaunchingAssertionAttributes:` and `activeMessageBatch`, and
     logs anything else.
   - `_handshakeLock_remoteTarget` = `SRFakeHost`, an in-process `<FBSWorkspaceServiceClientInterface>`. With this set,
     outgoing messages skip the pending queue (`_pendedSendBlocks` = nil).
   - `_identifier` = `FBSWorkspaceScenesClientIdentifier` with `_hostEndpoint` =
     `+[BSServiceConnectionEndpoint nullEndpointForService:FBSWorkspaceServiceSpecification.identifier instance:nil]`.
     `FBSSceneIdentityToken` asserts a non-nil endpoint of that service. The endpoint is never connected.
   - `_queue`/`_callOutQueue` = the workspace's queues. `_workspaceDelegate` = UIApp. The dictionaries, hash table and
     arrays are fresh, and `_activated` = YES.
   - Register with `-[FBSWorkspace _registerSource:]`, which is an ObjC method.
3. On the workspace `_queue`, call `-[client createSceneWithIdentity:parameters:transitionContext:completion:]`:
   - identity: `+[FBSSceneIdentity identityForIdentifier:@"sceneID:<bundleid>-default" workspaceIdentifier:@"com.apple.frontboard.systemappservices"]`.
     A nil workspace identifier asserts in FBSSceneIdentityToken.
   - parameters: `+[FBSMutableSceneParameters parametersForSpecification:[UIApplicationSceneSpecification specification]]`
     - `setDisplay:[UIScreen mainScreen].displayConfiguration` (sets settings.displayConfiguration). The scene must
       carry the main screen's display identity, otherwise UIKit makes or uses another UIScreen.
     - `updateSettingsWithBlock:` on the `UIMutableApplicationSceneSettings`: frame {0,0,W,H}, level 1,
       interfaceOrientation, foreground YES, deactivationReasons 0, deviceOrientation, userInterfaceStyle,
       canShowAlerts, statusBarHeight / safe-area insets per orientation, and persistenceIdentifier (it becomes
       `UISceneSession.persistentIdentifier`).
   - transitionContext: `[UIApplicationSceneTransitionContext new]`. Actions (URL, shortcut, user activity) go here.
4. Updates: `SRScenesUpdate()` copies the last settings to a mutable copy and applies the changes. It then builds
   `+[FBSSceneSettingsDiff diffFromSettings:toSettings:]` and calls
   `-[client sceneID:<FBSSceneIdentity> updateWithSettingsDiff:transitionContext:completion:]` on the workspace queue.
   Verified results:

   | Change | Result |
   |---|---|
   | Size changed to 600x800 | `windowScene:didUpdateEffectiveGeometry:` → 600x800 |
   | Frame 402x874 with `interfaceOrientation` 3 (landscapeRight) | Scene bounds 874x402; screen bounds 874x402 |
   | foreground = NO | `sceneWillResignActive` → `sceneDidEnterBackground`; the scene's layers are removed from client settings |
   | foreground = YES | `sceneWillEnterForeground` → `sceneDidBecomeActive` |

   **The frame is in the display's native (portrait) space.** Rotation is expressed only through
   `interfaceOrientation`. Passing 874x402 together with landscape produces the wrong result.
5. Client settings from the app reach `SRFakeHost sceneID:didUpdateClientSettingsWithDiff:`. Its `layers` set holds
   `_FBSCapturedSceneLayer {type: context, contextID, renderID, level}`, i.e. **the CAContext id(s) a host must display**
   (CALayerHost.contextId). They are exported through `SRScenesSetLayersCallback` / `SRScenesGetMainContextID`.

Why this approach:
- It uses the exact client-side code path that SpringBoard's XPC messages drive, so all of UIKit's scene machinery
  runs for real: FBSScene, settings diffs, UIScene lifecycle, UIScreen/display mapping and state restoration ids.
  Later scene operations are the same calls with different arguments.
- It has no XPC, no Mach services and no launchd dependency, and it works in null-bootstrap mode and under simns.
- It needs only one interposed C function. Everything else uses public-in-runtime ObjC (alloc + ivars).

Alternatives considered:
- **(2) FrontBoard.framework server in-process.** This would need FBSceneManager, FBProcessManager, RunningBoard process
  identities, FBSystemShell/workspace-domain plumbing and a BSServiceConnection listener for the app's own workspace.
  That is far more surface for the same end result, which is the same createScene message.
- **A real BSServiceConnection over an anonymous XPC listener.** BoardServices supports anonymous domains, and
  `xpc_endpoint` wrapping works (it is used below for the HID sink). We would then implement the host side by
  encoding through BSXPC. This is possible, but it adds asynchronous XPC and BSXPC coding for nothing in the
  single-process case.
- **(3) UIKit-level hooks.** UIKit already completes launch without a scene (`_compellApplicationLaunchToCompleteUnconditionally`).
  There is no scene-less "headless" mode for UIScene apps; the iOS 27 SDK asserts UIScene adoption. Faking UIScene
  objects directly would bypass FBSScene, which UIWindowScene uses everywhere (settings, client settings, layers).
  Rejected.

## 3. Other launch blockers handled in scenes.dylib (keep or replace)

| What | Symptom without it | What scenes.dylib does | Owner long-term |
|---|---|---|---|
| `BKSDisplayServicesStart()` (BackBoardServices, called cross-image) | "unable to communicate with backboardd" → exit | `__interpose`: `GSSetMainScreenInfo(W*S, H*S, S, 0)`, return true. `GSSetMainScreenInfo(double pixelW, double pixelH, float scale, float orientation)` | backboard/display layer |
| `os_trace_set_mode(0x100)` from `_libxpc_initializer` in null-bootstrap mode | **all os_log/NSLog dropped, even with OS_ACTIVITY_DT_MODE=1** (`_os_trace_init_slow` returns early when the mode has the 0x100 "disabled" bit) | `__interpose`: drop bit 0x100. Not needed under simns | Mach-namespace layer |
| `com.apple.backboard.hid-services.xpc` BSService endpoint (`BKSHIDEventDeliveryManager`, `BKSHIDEventObserver`; first used by `-makeKeyAndVisible` → `_UIEventDeferringManager`) | nil endpoint → `_initWithConnectionFactory:` hard assert. A null endpoint invalidates → BKSHIDEventObserver logs "backboardd must have unloaded, exiting…" and **exits** | Swizzle `+[BSServiceConnectionEndpoint endpointForMachName:service:instance:]`: if nil for that mach name, return an endpoint for an **in-process anonymous XPC listener** that accepts and swallows everything. The endpoint is built by hand: BSXPCServiceConnectionEndpoint `_xpcEndpoint` = `xpc_endpoint_create(listener)` | HID/input workstream (a real in-process BKHIDEventDeliveryManager service) |
| No CARenderServer: `+[CADisplay displays]` | `query_displays()` usleep-retries for **5 s** on the main thread (in `+[UIScreen initialize]`), then returns @[] | Only if `CARenderServerGetServerPort()==0` at load: return @[] immediately (`+mainDisplay` → nil) | render workstream |
| No CARenderServer: UIScreen | main UIScreen built with nil FBSDisplayConfiguration → bounds 0x0, scale 1 | `[[UIScreen mainScreen] _updateDisplayConfiguration:synth]`, synth = FBSDisplayConfiguration(`_initWithIdentity:...`) with FBSDisplayIdentity(type 0 main, mainLike, displayID 1), FBSDisplayMode(W*S x H*S, scale S, 60 Hz). `+[UIScreen initialize]` calls the designated init directly, so swizzling `initWithDisplayConfiguration:forceMainScreen:` does nothing. | render workstream (real CADisplay → FBS builds this itself) |
| No CARenderServer: `+[CAContext remoteContextWithOptions:]` returns nil | `__UIKIT_DID_NOT_RECEIVE_A_REMOTE_CACONTEXT...` assertion in `-makeKeyAndVisible` | Fall back to `localContextWithOptions:` (nothing displayed) | render workstream |

With a render server the last three stay inactive automatically. `SRCreateScene` then passes the real
`[UIScreen mainScreen].displayConfiguration`, which UIKit builds from `_UIScreenInitialDisplayConfigurationLoader`
(see Open problems).

## 4. What is asked of each daemon during launch (Hello.app, from simns logs plus os_log)

| Service (kind) | Who / why | Effect when missing |
|---|---|---|
| com.apple.logd, com.apple.diagnosticd (lookup/endpoint) | libtrace | none (DT mode prints to stderr) |
| com.apple.system.notification_center | notify_* (e.g. BKSAccelerometer orientation token) | soft: "unable to create notifyd token" |
| com.apple.CARenderServer (lookup) | QuartzCore (CADisplay, remote CAContext) | 5 s stall plus a fatal assertion. Handled above |
| com.apple.backboard.display.services (MIG) | BKSDisplayServicesStart | fatal. Interposed |
| com.apple.cfprefsd.daemon (endpoint) | CFPreferences | soft: prefs not persisted |
| com.apple.frontboard.systemappservices (endpoint) | FBSWorkspace default shell endpoint; UIKit `_UIApplicationConfigurationLoader` / `DeviceConfigurationFetch` ("Failed to initialize application enviroment context", "Failed to load a device context") | scenes never arrive (solved by the local source). Configuration falls back to defaults |
| com.apple.runningboard (endpoint) | RBSConnection handshake; RBSAssertion for UIKit's launch background task and `alm_acquire_pageins_recording_assertion` | soft: "Error acquiring assertion", "Unexpectedly failed to create Launch Background Task". No process-state or suspension management (app stays running in background) |
| com.apple.iohideventsystem (lookup) | IOHIDEventSystemClient (hidd) | soft: "Unable to create event queue via hidd" |
| com.apple.backboard.hid-services.xpc (BSService endpoint: BKHIDEventDeliveryObserver, BKHIDEventDeliveryManager) | UIKit event deferring / key window | fatal (assert / exit). In-process sink |
| com.apple.backboard.hid.services (MIG lookup) | BKSetAccelerometerClientEventsEnabled | soft |
| com.apple.fontservicesd, com.apple.uiintelligencesupport.agent, com.apple.UIKit.KeyboardManagement.hosted (_UIRemoteKeyboards), com.apple.IOSurface.Remote | fonts, intelligence, keyboard, IOSurface | soft (logged) |
| routine 904 (simns) | libxpc | harmless |

## 5. Integrator hook points (scenes.h)
- Inject `scenes.dylib` (DYLD_INSERT_LIBRARIES / SIMNS_INSERT). It is self-contained and its interposers are
  `BKSDisplayServicesStart`, `os_trace_set_mode` and `FBSWorkspaceInitialize`. If another dylib also interposes these,
  merge the code instead (dyld uses one interposer per symbol).
- `void SRScenesCreate(CGFloat w, CGFloat h)` creates the main scene. This happens automatically unless
  `SCENES_NO_AUTOCREATE=1`. Use the manual call to wait until a render server or host window is ready.
- `void SRScenesUpdate(CGFloat w, CGFloat h, BOOL foreground, long orientation)` handles resize, rotation and
  foreground/background (host window resize, minimise, and so on).
- `SRScenesSetLayersCallback(cb, ctx)` / `SRScenesGetMainContextID()` report the scene's CAContext id(s) to put in a
  CALayerHost or render server display.
- The key private API, if the code is re-implemented elsewhere: the interposed `FBSWorkspaceInitialize`; ivars of
  `FBSWorkspace` (`_queue`, `_callOutQueue`) and `FBSWorkspaceScenesClient` (listed above);
  `-[FBSWorkspace _registerSource:]`; `-[FBSWorkspaceScenesClient createSceneWithIdentity:parameters:transitionContext:completion:]`;
  `-[FBSWorkspaceScenesClient sceneID:updateWithSettingsDiff:transitionContext:completion:]`;
  `+[FBSMutableSceneParameters parametersForSpecification:]`; `-setDisplay:`; `-updateSettingsWithBlock:`;
  `+[FBSSceneSettingsDiff diffFromSettings:toSettings:]`; `[UIApplicationSceneSpecification specification]`;
  `UIApplicationSceneTransitionContext`.

## 6. Open problems / next steps
- **Render server present.** This is not yet tested. UIKit then builds the main screen from
  `-[_UIScreenInitialDisplayConfigurationLoader initialDisplayContext]`:
  `+[UIApplication _expectsCADisplays]` and `[CADisplay displays].count` → `applicationInitializationContext.mainDisplayContext`
  (from FrontBoard, so it fails), then falls back to `[UISDisplayContext defaultContext]`. Check that
  `mainScreen.displayConfiguration` is non-nil and that its identity matches what we pass to `setDisplay:`.
  Also check the CAContext from `remoteContextWithOptions:` (displayId comes from the screen's display identity).
  The synthesized display uses displayID 1, and UIKit logs "Unable to find a CADisplay for decoded displayID 1"
  (harmless without CA).
- **Scene destruction / app termination.** `sceneID:destroyWithTransitionContext:completion:` and
  `willTerminateWithTransitionContext:` are not exercised yet.
- **Multiple scenes.** `requestSceneWithOptions:` from the app (e.g. `UIApplication requestSceneSessionActivation`)
  reaches SRFakeHost and is answered with nil. To support it, create another identity and call createScene from
  there. Hello has `UIApplicationSupportsMultipleScenes = NO`.
- **Launch options.** URL / shortcut / user activity at launch: put the right `UIApplicationSceneSpecification`
  actions in `transitionContext.actions` (not done).
- **Foreground/active details.** Only `foreground` and `deactivationReasons=0` are set. Other values (occlusion,
  underLock, idle/backlight `bls_*`, jetsam) are defaults. `UIApplication.applicationState` is Active (0).
  With no RunningBoard there is no suspension, so a backgrounded app keeps running.
- **Orientation.** Rotation works through settings. `deviceOrientation` and the accelerometer (BKSAccelerometer
  needs notifyd + backboard.hid.services) are not wired. `supportedInterfaceOrientations` from the app arrives only
  in client settings (`SRFakeHost`). Nothing acts on it.
- **Status bar / safe area.** The values are hard-coded for a 402x874 notch-less layout (top 62, bottom 34). They
  should come from the device profile.
- **Input.** The HID sink only keeps BKS from asserting or exiting. Real touch/key delivery and event deferring
  belong to the HID workstream, which should replace the sink with a real `BKHIDEventDeliveryManager` service.
- **lldb caveat.** Under lldb (debugserver), the inferior inherits the *host* bootstrap port, so lookups fail
  differently ("unknown service") and libxpc does not disable logging. Behaviour can differ from a plain run.

## Files
- `shim.m` → `scenes.dylib`: everything above, plus `scenes.h` (exported API).
- `app.m` → `Hello.app`: ../main.m plus logging for didFinishLaunching, willConnect (bounds/scale), the lifecycle
  callbacks and geometry changes, and a heartbeat that shows the main thread keeps running.
- `build.sh`, `run.sh`, `dbg.sh` (lldb), `sample_output.txt`.
- IDA databases / decompilations used: `~/Developer/SimRun-research/idb-scenes/` (UIKitCore.i64, FrontBoardServices.i64,
  BoardServices.i64, BackBoardServices.i64; `fbs_all.c`, `bs_all.c`, `bbs_all.c`, `uik*.c`; `fn.sh file.c 'name'` prints a function).
