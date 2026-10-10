// environment.h — what scripts/simrun.sh does, natively: the environment a sim process expects from launchd_sim,
// plus where SimRun's own pieces live (inside SimRun.app, or next to a plain build in build/bin).
#pragma once
#import <Foundation/Foundation.h>

@interface SREnvironment : NSObject
// The iOS Simulator runtime root (SIMRUN_RUNTIME_ROOT, else the newest installed iOS runtime); nil if none.
+ (NSString *)runtimeRoot;
// Variables a sim process needs (DYLD_ROOT_PATH, HOME = the simulated device's data dir, SIMULATOR_*, ...).
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
