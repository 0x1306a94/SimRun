// layermirror.h — a Mac copy of a sim app's layer tree, built from the batches script.dylib's inspect.m sends
// (inspect.md): real CALayers with the app's geometry, colors, borders, corners, shadows, masks, gradients and shapes,
// so Core Animation draws them as the app's do.
#pragma once
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

@interface SRLayerMirror : NSObject
// The screen. Its sublayers are the windows' layers, back to front; its geometry is flipped (y down, as on iOS) and its
// bounds are the screen in points.
@property (readonly) CALayer *rootLayer;
@property (readonly) NSUInteger nodeCount, batchCount;
// Stand-ins for what isn't copied: a blue tint where a layer has contents (what it drew, images), an orange one on
// layers the Mac can't draw at all (backdrops, portals, SDF, Metal, video…). On by default.
@property (nonatomic) BOOL showsPlaceholders;
// Applies a batch (a dictionary from the app). Returns what changed: { full: YES (it replaced everything),
// added: [ids], changed: { id: [properties] }, removed: [ids] }.
- (NSDictionary *)applyBatch:(NSDictionary *)batch;
// The tree as text, one layer per line, indented under its superlayer.
- (NSString *)treeDescription;
// A line about what applyBatch: returned.
- (NSString *)describeChanges:(NSDictionary *)changes;
// The copy drawn by Core Animation (CALayer -renderInContext:) at `scale` pixels per point; nil before the first batch.
- (NSData *)PNGWithScale:(CGFloat)scale;
@end
