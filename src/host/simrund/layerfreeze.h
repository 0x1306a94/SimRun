// layerfreeze.h — the layer window's freeze options, a popover from the snowflake at the end of its bar (as Xcode's
// Capture Options): freeze now, after the app's next N updates, or N seconds from now. Remembered between uses.
#pragma once
#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, SRFreezeWhen) {
  SRFreezeNow,
  SRFreezeAfterUpdates,   // after N batches from the app (each a Core Animation commit that changed something)
  SRFreezeAfterSeconds,
};

@interface SRFreezeOptions : NSViewController
// The Freeze button was pressed (`count` is 0 for SRFreezeNow).
@property (copy) void (^onFreeze)(SRFreezeWhen when, NSInteger count);
@end
