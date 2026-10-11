// filepanel.h — the Mac's open and save panels as SRDP_SERVICE (include/docpicker.h): where every app's docpicker.dylib
// has its UIDocumentPickerViewController pick files.
#pragma once
#import <Cocoa/Cocoa.h>
#include <mach/mach.h>

@interface SRDocumentPickerHost : NSObject
// `windowForPid` gives the window of the app with that pid (its panels are sheets on it), or nil.
- (instancetype)initWithWindowForPid:(NSWindow * (^)(pid_t pid))windowForPid;
// Starts the sim2host listener. Returns a send right to its port (register it in simns as SRDP_SERVICE), or 0.
- (mach_port_t)start;
@end
