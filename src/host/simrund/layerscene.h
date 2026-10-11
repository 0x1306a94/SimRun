// layerscene.h — the 3D view of a layer copy (layermirror.h), as in Xcode's view debugger but live: every layer a
// plane, spread out in depth, seen through a camera that turns, zooms and pans.
//
// A plane moves forward only as far as it must: one level above its superlayer's, and above every plane before it
// (in drawing order) that it overlaps; so siblings side by side share a level. Live, levels go up at once but come
// down only once the app has been quiet for a moment, and changes slide, so the stack holds still. Each node is a CATransformLayer (its
// geometry, so the depth survives down the tree) holding a flat plane (the layer's look, and an outline) and the
// nodes of its sublayers. A 3D tree can't be flattened, so what flattening does is done by hand: opacity is
// multiplied down the tree, and a superlayer's masksToBounds clips the planes under it (`clipsContent`).
#pragma once
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

@class SRLayerMirror;

@interface SRLayerScene : NSObject
- (instancetype)initWithMirror:(SRLayerMirror *)mirror;
// The camera, holding the scene; add it to a layer whose sublayerTransform has perspective (SRScenePerspective), and
// call -layoutInSize: with that layer's size.
@property (readonly) CALayer *cameraLayer;
@property (nonatomic) CGFloat yaw, pitch;   // radians: turned about the vertical axis, then tilted
@property (nonatomic) CGFloat zoom;         // the only thing that scales the view (1: about 60% of it)
@property (nonatomic) CGPoint pan;          // points, in the view
@property (nonatomic) CGFloat topInset;     // the top of the view under a (translucent) toolbar: fit and center below it
@property (nonatomic) CGFloat spacing;      // points between levels; until set, chosen when the scene is built (the
                                            // stack about as deep as the screen is tall)
@property (nonatomic) BOOL clipsContent;    // planes clipped by their superlayers' masksToBounds (default YES)
@property (nonatomic) BOOL showsWireframes; // an outline around every plane (default YES)
@property (nonatomic) BOOL showsPlaceholders;
@property (nonatomic, copy) NSNumber *selectedNode;
@property (readonly) NSInteger levels;
- (void)layoutInSize:(CGSize)size;
// Camera and spacing changes made in `changes` animate (everything else is immediate).
- (void)animate:(void (^)(void))changes;
// After the mirror applied a batch (its -applyBatch: result).
- (void)updateWithChanges:(NSDictionary *)changes;
// The frontmost plane at `p` (in `layer`'s coordinates); nil for none.
- (NSNumber *)nodeAtPoint:(CGPoint)p fromLayer:(CALayer *)layer;
// The scene drawn offscreen by Core Animation (CARenderer: real 3D, unlike -renderInContext:) as PNG; `spacing` 0
// for the one the scene chooses.
+ (NSData *)PNGOfMirror:(SRLayerMirror *)mirror size:(CGSize)size yaw:(CGFloat)yaw pitch:(CGFloat)pitch spacing:(CGFloat)spacing;
@end

// The perspective for a view of `size` (a sublayerTransform).
CATransform3D SRScenePerspective(CGSize size);
