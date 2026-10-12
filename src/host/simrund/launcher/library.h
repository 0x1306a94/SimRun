// library.h — the launcher's list of iOS-Simulator apps (persisted in user defaults) and how to inspect an .app.
#pragma once
#import <Cocoa/Cocoa.h>

@interface SRAppInfo : NSObject
@property (readonly) NSString *path, *name, *bundleIdentifier, *executablePath;
@property (readonly) NSImage *icon;
@property (readonly) BOOL deviceBuild;   // built for iPhone/iPad devices: SimRun runs a converted copy (devicebuild.h)
// nil if `path` is an arm64 iOS-Simulator app bundle, or a device build SimRun can convert; otherwise why it can't be
// launched.
+ (NSString *)problemWithAppAtPath:(NSString *)path;
+ (instancetype)infoWithPath:(NSString *)path;
// The minimum iOS version an executable's arm64 slice was built for ("26.0"), as dyld enforces it; nil if unknown.
+ (NSString *)minimumOSVersionOfExecutable:(NSString *)path;
@end

@interface SRLibrary : NSObject
@property (readonly) NSArray<SRAppInfo *> *apps;
+ (instancetype)shared;
- (SRAppInfo *)addPath:(NSString *)path;   // returns the (new or existing) entry
- (void)removePath:(NSString *)path;
// Simulator builds Xcode left in DerivedData (Build/Products/*-iphonesimulator/*.app).
+ (NSArray<NSString *> *)xcodeSimulatorBuilds;
@end

extern NSNotificationName const SRLibraryDidChangeNotification;
