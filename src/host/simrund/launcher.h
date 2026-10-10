// launcher.h — the launcher window: the app library, drag-and-drop, launch/quit.
#pragma once
#import <Cocoa/Cocoa.h>
#import "library.h"

typedef NS_ENUM(NSInteger, SRAppState) {
  SRAppStateStopped,
  SRAppStateLaunching,   // process started, no frame yet (window still hidden)
  SRAppStateRunning,     // window shown
};

@protocol SRLauncherDelegate <NSObject>
- (void)launchApp:(SRAppInfo *)app;           // launches, or brings the running instance to the front
- (SRAppState)stateForApp:(SRAppInfo *)app;
- (void)quitApp:(SRAppInfo *)app;
- (void)showLogForApp:(SRAppInfo *)app;
- (void)resetDataForApp:(SRAppInfo *)app;      // deletes its data container (the app isn't running)
@end

@interface SRLauncher : NSObject
- (instancetype)initWithDelegate:(id<SRLauncherDelegate>)delegate;
- (void)show;
- (void)reloadState;                           // an app's state changed
// Validates, adds to the library and launches the given .app paths; reports problems in an alert.
- (void)openPaths:(NSArray<NSString *> *)paths;
- (void)addAppWithPanel;
- (void)addXcodeBuilds;
@end
