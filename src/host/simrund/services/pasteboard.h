// pasteboard.h — the Mac pasteboard as SRPB_SERVICE (include/pboard.h): what every app's pboard.dylib (its fake
// pasted) reads and writes. Also tells the apps when a pasteboard changes behind their back, so UIKit drops its cache.
#pragma once
#import <Cocoa/Cocoa.h>
#include <mach/mach.h>

@interface SRPasteboardHost : NSObject
// Starts the sim2host listener. Returns a send right to its port (register it in simns as SRPB_SERVICE), or 0.
- (mach_port_t)start;
@end
