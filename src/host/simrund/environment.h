// environment.h — what scripts/simrun.sh does, natively: the environment a sim process expects from launchd_sim,
// plus where SimRun's own pieces live (inside SimRun.app, or next to a plain build in build/bin).
#pragma once
#import <Foundation/Foundation.h>

// An iOS Simulator runtime: its RuntimeRoot and version.
@interface SRRuntime : NSObject
@property (readonly) NSString *root, *version, *build;   // ".../RuntimeRoot", "27.1", "24A94401"
@property (readonly) NSString *name;                     // "iOS 27.1 (24A94401)"
+ (instancetype)runtimeAtRoot:(NSString *)root;          // nil if it has no SystemVersion.plist
@end

@interface SREnvironment : NSObject
// The installed iOS Simulator runtimes, newest first, as CoreSimulator lists them (`simctl list runtimes`; cached for
// 30 s, reloadInstalledRuntimes forgets that); the one with this build version, or nil.
+ (NSArray<SRRuntime *> *)installedRuntimes;
+ (void)reloadInstalledRuntimes;
+ (SRRuntime *)installedRuntimeWithBuild:(NSString *)build;
// The runtime chosen in SimRun ▸ iOS Runtime (its build version; nil = the newest installed). Takes effect the next
// time SimRun starts: runtimeRoot is read once.
@property (class, copy) NSString *preferredRuntimeBuild;
// This process's runtime, which its shared simns and daemons run on and apps use unless they have their own:
// SIMRUN_RUNTIME_ROOT, else the preferred runtime, else the newest installed one; nil if none.
+ (NSString *)runtimeRoot;
+ (BOOL)runtimeRootFromEnvironment;   // SIMRUN_RUNTIME_ROOT chose it
// The variables that select a runtime (DYLD_ROOT_PATH, SIMULATOR_ROOT, SIMULATOR_RUNTIME_VERSION, ...).
+ (NSDictionary<NSString *, NSString *> *)runtimeVariablesForRoot:(NSString *)root;
// Variables a sim process needs (DYLD_ROOT_PATH, HOME = the simulated device's data dir, SIMULATOR_*, ...), for
// `root` or this process's runtime.
+ (NSDictionary<NSString *, NSString *> *)simulatorVariablesForRoot:(NSString *)root;
+ (NSDictionary<NSString *, NSString *> *)simulatorVariables;
// The simulated device's shared data directory (the daemons' HOME, SIMULATOR_SHARED_RESOURCES_DIRECTORY for apps):
// SIMRUN_DATA, else ~/Library/Developer/SimRun/data. Holds what is managed centrally: the keychain, device-wide
// preferences, app group containers, daemon state.
+ (NSString *)dataDirectory;
// Each app's own data container — its HOME, like an iOS sandbox container: <data>/Containers/Data/Application/<id>,
// <id> being the app's bundle identifier (the executable's name for a bare binary).
+ (NSString *)containerIdentifierForExecutable:(NSString *)executable;
+ (NSString *)containerPathForIdentifier:(NSString *)identifier;
+ (NSString *)createContainerForIdentifier:(NSString *)identifier;   // the path, with Documents/, Library/, tmp/ made
// `base` ("KEY=VALUE" strings, e.g. this process's environment) with `overrides` applied.
+ (NSArray<NSString *> *)environment:(NSArray<NSString *> *)base withOverrides:(NSDictionary<NSString *, NSString *> *)overrides;
+ (NSArray<NSString *> *)processEnvironment;
// SIMRUN_HOST_INTL value: the Mac's language & region preferences as JSON (null for a key the Mac doesn't set); nil if
// they can't be read.
+ (NSString *)hostInternationalSettings;

+ (NSString *)simnsPath;                 // the simns helper
+ (NSString *)libraryDirectory;          // rshim/glue/scenes/hid/pboard/drag/keychain dylibs + SimFramebuffer
+ (NSString *)injectedLibraries;         // SIMNS_INSERT value for apps
+ (NSString *)framebufferFramework;      // SIMULATOR_FRAMEBUFFER_FRAMEWORK value
@end
