// catest (SIM platform, UIKit-free): starts an in-process CA render server whose display is the fake SimFramebuffer,
// creates a REMOTE CAContext exactly like UIKit does (+[CAContext remoteContextWithOptions:]), commits a layer tree,
// and writes presented frames to PNG files ($CATEST_OUT, default ./frames).
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
#include "simfb.h"
#if CATEST_UIKIT
#import <UIKit/UIKit.h>
#endif

@interface CAContext : NSObject
+ (instancetype)remoteContextWithOptions:(NSDictionary *)o;
@property (strong) CALayer *layer;
@property (readonly) uint32_t contextId;
@property float level;
@end
@interface CALayerHost : CALayer
@property uint32_t contextId;
@end
@interface CAWindowServer : NSObject
+ (instancetype)serverWithOptions:(NSDictionary *)o;
- (NSArray *)displays;
@end
extern NSString *kCAContextDisplayable;

static CGColorRef rgb(CGFloat r, CGFloat g, CGFloat b) { CGFloat c[4] = { r, g, b, 1 }; return CGColorCreate(CGColorSpaceCreateDeviceRGB(), c); }

// Copy the framebuffer synchronously (inside the frame handler), encode the PNG later on another queue.
static void write_png(IOSurfaceRef s, NSString *path, dispatch_queue_t q) {
  IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
  size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
  NSData *px = [NSData dataWithBytes:IOSurfaceGetBaseAddress(s) length:bpr * h];
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  uint32_t sid = IOSurfaceGetID(s);
  dispatch_async(q, ^{
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)px);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img = CGImageCreate(w, h, 8, 32, bpr, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, dp, NULL, false, kCGRenderingIntentDefault);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL); bool ok = CGImageDestinationFinalize(dst);
    CFRelease(dst); CGImageRelease(img); CGColorSpaceRelease(cs); CGDataProviderRelease(dp);
    fprintf(stderr, "[catest] wrote %s (%zux%zu, surface id %u) %s\n", path.lastPathComponent.UTF8String, w, h, sid, ok ? "" : "FAILED");
  });
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *out = @(getenv("CATEST_OUT") ?: "frames");
    [NSFileManager.defaultManager createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];

    // 1. frame hook in the fake SimFramebuffer (same image SimFramebufferClient will dlopen)
    void *fb = dlopen(getenv("SIMULATOR_FRAMEBUFFER_FRAMEWORK"), RTLD_NOW);
    void (*setHandler)(dispatch_queue_t, SimRunFBFrameHandler) = fb ? dlsym(fb, "SimRunFBSetFrameHandler") : NULL;
    if (!setHandler) { fprintf(stderr, "[catest] fake SimFramebuffer not loaded: %s\n", dlerror()); return 1; }
    __block int nframes = 0; __block uint64_t lastSeq = 0;
    dispatch_queue_t fq = dispatch_queue_create("png", DISPATCH_QUEUE_SERIAL);
    setHandler(NULL, ^(IOSurfaceRef s, uint64_t seq) {   // synchronous on CA's display thread
      nframes++; lastSeq = seq;
      if (nframes <= 3 || seq % 30 == 0) write_png(s, [out stringByAppendingFormat:@"/frame_%04llu.png", seq], fq);
    });

    // 2. in-process render server + displays (what backboardd does via BKDisplay -> CAWindowServer)
    CAWindowServer *ws = [CAWindowServer serverWithOptions:@{}];
    NSLog(@"[catest] CAWindowServer %@", ws);
    // client-side view of the displays (what UIScreen/BackBoard query through the CARenderServer port)
    Class CADisplayC = NSClassFromString(@"CADisplay"); id md = [CADisplayC valueForKey:@"mainDisplay"];
    NSLog(@"[catest] CADisplay.displays=%@", [CADisplayC valueForKey:@"displays"]);
    NSLog(@"[catest] CADisplay.mainDisplay=%@ name=%@ uniqueId=%@ bounds=%@ pointScale=%@ displayId=%@", md, [md valueForKey:@"name"],
          [md valueForKey:@"uniqueId"], [md valueForKey:@"bounds"], [md valueForKey:@"pointScale"], [md valueForKey:@"displayId"]);

    // 3. client side, like UIKit's _UIContextBinder / UIWindow
    // CATEST_MODE=direct (default): the content context is displayable and shown directly on the display.
    // CATEST_MODE=hosted: content context is NOT displayable (like an app window whose scene is hosted elsewhere);
    //   a second, displayable "host" context shows it through a CALayerHost (what SpringBoard/FrontBoard scene hosting does).
    BOOL hosted = getenv("CATEST_MODE") && !strcmp(getenv("CATEST_MODE"), "hosted");
    CAContext *ctx = [CAContext remoteContextWithOptions:hosted ? @{} : @{ kCAContextDisplayable: @YES }];
    NSLog(@"[catest] remote context %@ id=%u", ctx, ctx.contextId);
    CGFloat W = 402, H = 874;   // points (1206x2622 @3x)
    CALayer *root = [CALayer layer];
    root.anchorPoint = CGPointZero; root.bounds = CGRectMake(0, 0, W, H); root.position = CGPointZero;
    root.backgroundColor = rgb(0.10, 0.12, 0.30);
    // The server renders in display pixels; UIKit scales each window's layer by the screen scale the same way.
    root.transform = CATransform3DMakeScale(3, 3, 1);
    CALayer *box = [CALayer layer];
    box.frame = CGRectMake(40, 120, W - 80, 260); box.backgroundColor = rgb(0.95, 0.35, 0.25); box.cornerRadius = 32;
    [root addSublayer:box];
    CATextLayer *t = [CATextLayer layer];
    t.string = @"Hello from an in-process\nsim CA render server"; t.fontSize = 26; t.contentsScale = 3;
    t.frame = CGRectMake(24, 80, W - 128, 100); t.foregroundColor = rgb(1, 1, 1); t.alignmentMode = kCAAlignmentCenter;
    [box addSublayer:t];
    CALayer *spin = [CALayer layer];
    spin.frame = CGRectMake(W / 2 - 60, 520, 120, 120); spin.backgroundColor = rgb(0.2, 0.85, 0.45); spin.cornerRadius = 16;
    [root addSublayer:spin];
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    a.fromValue = @0; a.toValue = @(2 * M_PI); a.duration = 2; a.repeatCount = HUGE_VALF;
    [spin addAnimation:a forKey:@"spin"];
#if CATEST_UIKIT
    // UIKit views WITHOUT UIApplicationMain (no BackBoard/FrontBoard): their layers go into our remote context.
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(24, 680, W - 48, 160)];
    panel.backgroundColor = UIColor.systemBackgroundColor; panel.layer.cornerRadius = 20;
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, W - 80, 40)];
    lbl.text = @"UILabel (UIKit, no UIApplication)"; lbl.font = [UIFont boldSystemFontOfSize:18]; lbl.textColor = UIColor.labelColor;
    [panel addSubview:lbl];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(16, 70, 0, 0)]; sw.on = YES; [panel addSubview:sw];
    UIProgressView *pv = [[UIProgressView alloc] initWithFrame:CGRectMake(100, 86, W - 170, 8)]; pv.progress = 0.66; [panel addSubview:pv];
    [panel layoutIfNeeded];
    [root addSublayer:panel.layer];
#endif
    ctx.layer = root;
    [CATransaction flush];
    CAContext *hostCtx = nil;
    if (hosted) {
      hostCtx = [CAContext remoteContextWithOptions:@{ kCAContextDisplayable: @YES }];
      CALayer *hr = [CALayer layer]; hr.frame = CGRectMake(0, 0, 1206, 2622); hr.backgroundColor = rgb(0.3, 0.3, 0.3);
      CALayerHost *lh = [CALayerHost layer]; lh.contextId = ctx.contextId; lh.anchorPoint = CGPointZero;
      lh.frame = CGRectMake(0, 0, 1206, 2622);
      lh.transform = CATransform3DMakeScale(0.8, 0.8, 1); lh.position = CGPointMake(120, 262);  // visibly "hosted"
      [hr addSublayer:lh]; hostCtx.layer = hr;
      [CATransaction flush];
      NSLog(@"[catest] host context id=%u hosting content context id=%u", hostCtx.contextId, ctx.contextId);
    }

    double secs = getenv("CATEST_SECONDS") ? atof(getenv("CATEST_SECONDS")) : 3;
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
    dispatch_sync(fq, ^{});
    fprintf(stderr, "[catest] %d frames presented (last seq %llu) -> %s/\n", nframes, lastSeq, out.UTF8String);
    return nframes > 0 ? 0 : 3;
  }
}
