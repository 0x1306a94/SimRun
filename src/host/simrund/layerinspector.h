// layerinspector.h — the layer window's inspector: everything about the selected layer, in sections (object, layout,
// appearance, contents with its picture, filters and the special classes' properties), kept up to date as it changes.
// The properties the app can change (session.h -editLayer:…) are controls: checkboxes, number fields, color wells.
#pragma once
#import <Cocoa/Cocoa.h>

@class SRLayerMirror;

@interface SRLayerInspector : NSObject <NSTextFieldDelegate>
@property (readonly) NSView *view;
// A control was changed: set `key` of node `nid` to `value` (nil: none, for a color).
@property (copy) void (^onEdit)(NSNumber *nid, NSString *key, id value);
// Shows `nid` of `mirror` (nil: nothing selected). While a field is being edited, the refresh waits until it's done.
- (void)showNode:(NSNumber *)nid of:(SRLayerMirror *)mirror;
@end
