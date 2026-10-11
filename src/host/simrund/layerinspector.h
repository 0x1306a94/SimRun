// layerinspector.h — the layer window's inspector: everything about the selected layer, in sections (object, layout,
// appearance, contents with its picture, filters and the special classes' properties), kept up to date as it changes.
#pragma once
#import <Cocoa/Cocoa.h>

@class SRLayerMirror;

@interface SRLayerInspector : NSObject
@property (readonly) NSView *view;
// Shows `nid` of `mirror` (nil: nothing selected).
- (void)showNode:(NSNumber *)nid of:(SRLayerMirror *)mirror;
@end
