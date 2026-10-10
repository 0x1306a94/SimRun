// launchsheet.h — the Launch With… sheet: an app's launch options (launchoptions.h) in four tabs, like a scheme's Run
// action in Xcode: Info (runtime, device), Arguments (arguments, environment variables), Options (language & region,
// SimRun services) and Diagnostics (logging, tracing).
#pragma once
#import <Cocoa/Cocoa.h>
#import "library.h"

@interface SRLaunchSheet : NSObject
// Shows `app`'s options as a sheet on `window`. Launch (Relaunch if `running`) saves them and calls `launch`; Cancel
// discards the edits.
+ (void)beginForApp:(SRAppInfo *)app running:(BOOL)running window:(NSWindow *)window launch:(void (^)(void))launch;
@end
