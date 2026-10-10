// environment.h — what scripts/simrun.sh does, natively: the environment a sim process expects from launchd_sim,
// plus where SimRun's own pieces live (inside SimRun.app, or next to a plain build in build/bin).
#pragma once
#import <Foundation/Foundation.h>

@interface SREnvironment : NSObject
// The iOS Simulator runtime root (SIMRUN_RUNTIME_ROOT, else the newest installed iOS runtime); nil if none.
+ (NSString *)runtimeRoot;
// Variables a sim process needs (DYLD_ROOT_PATH, HOME = the simulated device's data dir, SIMULATOR_*, ...).
+ (NSDictionary<NSString *, NSString *> *)simulatorVariables;
// The simulated device's data directory (the apps' HOME): SIMRUN_DATA, else ~/Library/Developer/SimRun/data.
+ (NSString *)dataDirectory;
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
