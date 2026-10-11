// ui.m — what scripts do to the app and learn about its screen, beyond accessibility (native.ui, used by js/app.js):
// touches, keys and text through hid.dylib (the same path as the window's mouse and keyboard, hid.md), how many frames
// have been presented (SimFramebuffer; the UI has settled once that stops moving), the screen's size, and a dump of
// the view hierarchy.
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include "script.h"

UIWindowScene *SRActiveScene(void) {
  UIWindowScene *any = nil;
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
    if (![s isKindOfClass:UIWindowScene.class]) continue;
    if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
    any = (UIWindowScene *)s;
  }
  return any;
}
NSArray<UIWindow *> *SRWindows(void) {   // back to front
  return [SRActiveScene().windows sortedArrayUsingComparator:^NSComparisonResult(UIWindow *x, UIWindow *y) {
    return x.windowLevel < y.windowLevel ? NSOrderedAscending : x.windowLevel > y.windowLevel ? NSOrderedDescending : NSOrderedSame;
  }];
}

static NSString *SRRect(CGRect r) { return [NSString stringWithFormat:@"(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height]; }
static void SRDumpView(UIView *v, int depth, NSMutableString *out) {
  if (v.hidden || v.alpha == 0) return;
  [out appendFormat:@"%*s%@ %@", depth * 2, "", NSStringFromClass(v.class), SRRect([v convertRect:v.bounds toView:nil])];
  if (v.accessibilityIdentifier.length) [out appendFormat:@" id=%@", v.accessibilityIdentifier];
  [out appendString:@"\n"];
  for (UIView *s in v.subviews) SRDumpView(s, depth + 1, out);
}

static uint64_t (*SRFrameCountFunction(void))(void) {
  static uint64_t (*f)(void);
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char *fw = getenv("SIMULATOR_FRAMEBUFFER_FRAMEWORK");
    void *h = fw ? dlopen(fw, RTLD_NOW | RTLD_NOLOAD) : NULL;
    f = h ? dlsym(h, "SimRunFBFrameCount") : NULL;
    if (!f) VLOG("no SimRunFBFrameCount: settling falls back to waiting");
  });
  return f;
}

void SRInstallUIBindings(JSValue *native) {
  Class V = SRJSValueClass();
  JSValue *ui = [V valueWithNewObjectInContext:native.context];
  // touch(finger, phase, x, y): phase 1 began, 2 moved, 3 ended, 4 cancelled (hid.h); scene points
  ui[@"touch"] = ^JSValue *(int finger, int phase, double x, double y) {
    void (*touch)(int, int, float, float) = dlsym(RTLD_DEFAULT, "SRHIDTouchFinger");
    if (!touch) return SRThrow(@"no touch input: hid.dylib isn't loaded");
    touch(finger, phase, (float)x, (float)y);
    return [V valueWithUndefinedInContext:SRCurrentContext()];
  };
  // key(usage, down): a key by its HID usage (page 7), e.g. 0x28 Return, 0xE3 left Command
  ui[@"key"] = ^JSValue *(uint32_t usage, BOOL down) {
    void (*key)(uint32_t, bool) = dlsym(RTLD_DEFAULT, "SRHIDKeyUsage");
    if (!key) return SRThrow(@"no keyboard input: hid.dylib isn't loaded");
    key(usage, down);
    return [V valueWithUndefinedInContext:SRCurrentContext()];
  };
  // text(string): key presses for each character, into whatever has keyboard focus
  ui[@"text"] = ^JSValue *(NSString *text) {
    void (*type)(const char *) = dlsym(RTLD_DEFAULT, "SRHIDText");
    if (!type) return SRThrow(@"no keyboard input: hid.dylib isn't loaded");
    type(text.UTF8String);
    return [V valueWithUndefinedInContext:SRCurrentContext()];
  };
  // frameCount(): frames presented so far, or -1 if SimRun's SimFramebuffer isn't there to ask
  ui[@"frameCount"] = ^double(void) {
    uint64_t (*f)(void) = SRFrameCountFunction();
    return f ? (double)f() : -1;
  };
  ui[@"screen"] = ^NSDictionary *(void) {
    UIWindowScene *scene = SRActiveScene();
    CGRect b = scene.coordinateSpace.bounds;
    return @{ @"width": @(b.size.width), @"height": @(b.size.height), @"scale": @(scene.screen.scale) };
  };
  ui[@"views"] = ^NSString *(void) {
    NSMutableString *out = [NSMutableString string];
    for (UIWindow *w in SRWindows()) SRDumpView(w, 0, out);
    return out;
  };
  native[@"ui"] = ui;
}
