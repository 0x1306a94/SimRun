// mirrorwindow.m — see mirrorwindow.h. Modelled on iPhone Mirroring (ScreenContinuityUI + SwiftUI's AppKitWindow):
//
//   - The window frame never changes on hover. It is always the full chrome size: the device screen plus an 8 pt
//     margin on the sides and bottom and a T pt title strip on top.
//   - What animates is the window's *shape*, set with AppKit's private -_setCornerPath:. The path clips the window,
//     its shadow and system border, and is the window server's hit-test shape: while the chrome is hidden, clicks on
//     the (invisible) margins go to whatever is behind the window.
//       hidden:  the device-screen rect, all corners c (the device's screen corner radius)
//       shown:   the whole frame, top corners 20 pt, bottom corners c + 8 (concentric with the screen)
//     with continuous ("squircle") corners, interpolated by a critically damped spring (response 0.28 s).
//   - The title strip (traffic lights) fades in/out (springs 0.7 s / 0.14 s) and slides down by T when hidden.
//   - Hover: above the screen or within 10 pt of its top shows the chrome; moving onto the content (or away) hides it;
//     the margins keep it shown.
#import "mirrorwindow.h"
#import <QuartzCore/QuartzCore.h>

@interface NSWindow (SRPrivate)
- (void)_setCornerPath:(CGPathRef)path;          // window shape: clip, shadow, border, hit-testing
- (void)_setNeedsToResetDragMargins:(BOOL)reset;
@end

static const CGFloat kMargin = 8;                // chrome margin around the screen (sides and bottom)
static const CGFloat kStrip = 38;                // title strip height (iPhone Mirroring's title bar safe area)
static const CGFloat kTopRadius = 20;            // chrome top corners
static const CGFloat kStatusBarZone = 10;        // hovering this close to the top of the screen shows the chrome
static const CGFloat kLightsInset = 9, kLightsSpacing = 9;

CGFloat SRDeviceCornerRadius(NSString *capabilitiesPath) {
  NSDictionary *caps = capabilitiesPath ? [NSDictionary dictionaryWithContentsOfFile:capabilitiesPath] : nil;
  NSNumber *r = caps[@"capabilities"][@"DeviceCornerRadius"];
  return [r isKindOfClass:NSNumber.class] && r.doubleValue > 0 ? r.doubleValue : 55;
}

// Continuous-corner ("squircle") rounded rect with per-corner radii — the iOS/SwiftUI .continuous corner curve.
// Built in a top-left-origin space, then flipped into AppKit window coordinates (height `flipH`).
static CGPathRef CreateContinuousRect(CGRect r, CGFloat tl, CGFloat tr, CGFloat br, CGFloat bl, CGFloat flipH) {
  const CGFloat a = 1.52866483, b = 1.08849323, c = 0.86840689, d = 0.66993427, e = 0.06549600, f = 0.37282392, g = 0.16890344;
  CGFloat lim = MIN(r.size.width, r.size.height) / 2 / a;
  tl = MIN(tl, lim); tr = MIN(tr, lim); br = MIN(br, lim); bl = MIN(bl, lim);
  CGFloat x0 = r.origin.x, y0 = r.origin.y, x1 = x0 + r.size.width, y1 = y0 + r.size.height;
  CGMutablePathRef p = CGPathCreateMutable();
  CGAffineTransform t = CGAffineTransformMake(1, 0, 0, -1, 0, flipH);   // y down -> y up
  CGPathMoveToPoint(p, &t, x0 + a * tl, y0);
  CGPathAddLineToPoint(p, &t, x1 - a * tr, y0);
  CGPathAddCurveToPoint(p, &t, x1 - b * tr, y0, x1 - c * tr, y0, x1 - d * tr, y0 + e * tr);
  CGPathAddCurveToPoint(p, &t, x1 - f * tr, y0 + g * tr, x1 - g * tr, y0 + f * tr, x1 - e * tr, y0 + d * tr);
  CGPathAddCurveToPoint(p, &t, x1, y0 + c * tr, x1, y0 + b * tr, x1, y0 + a * tr);
  CGPathAddLineToPoint(p, &t, x1, y1 - a * br);
  CGPathAddCurveToPoint(p, &t, x1, y1 - b * br, x1, y1 - c * br, x1 - e * br, y1 - d * br);
  CGPathAddCurveToPoint(p, &t, x1 - g * br, y1 - f * br, x1 - f * br, y1 - g * br, x1 - d * br, y1 - e * br);
  CGPathAddCurveToPoint(p, &t, x1 - c * br, y1, x1 - b * br, y1, x1 - a * br, y1);
  CGPathAddLineToPoint(p, &t, x0 + a * bl, y1);
  CGPathAddCurveToPoint(p, &t, x0 + b * bl, y1, x0 + c * bl, y1, x0 + d * bl, y1 - e * bl);
  CGPathAddCurveToPoint(p, &t, x0 + f * bl, y1 - g * bl, x0 + g * bl, y1 - f * bl, x0 + e * bl, y1 - d * bl);
  CGPathAddCurveToPoint(p, &t, x0, y1 - c * bl, x0, y1 - b * bl, x0, y1 - a * bl);
  CGPathAddLineToPoint(p, &t, x0, y0 + a * tl);
  CGPathAddCurveToPoint(p, &t, x0, y0 + b * tl, x0, y0 + c * tl, x0 + e * tl, y0 + d * tl);
  CGPathAddCurveToPoint(p, &t, x0 + g * tl, y0 + f * tl, x0 + f * tl, y0 + g * tl, x0 + d * tl, y0 + e * tl);
  CGPathAddCurveToPoint(p, &t, x0 + c * tl, y0, x0 + b * tl, y0, x0 + a * tl, y0);
  CGPathCloseSubpath(p);
  return p;
}

// Spring integrated per display frame. stiffness = (2π/response)², damping = 4πζ/response (mass 1).
typedef struct { CGFloat value, velocity, target, k, d; } SRSpring;
static void SpringSetResponse(SRSpring *s, CGFloat response, CGFloat dampingFraction) {
  s->k = pow(2 * M_PI / response, 2); s->d = 4 * M_PI * dampingFraction / response;
}
static BOOL SpringStep(SRSpring *s, CGFloat dt) {   // returns YES while moving
  for (int i = 0; i < 8; i++) {
    CGFloat h = dt / 8, acc = -s->k * (s->value - s->target) - s->d * s->velocity;
    s->velocity += acc * h; s->value += s->velocity * h;
  }
  if (fabs(s->value - s->target) < 1e-4 && fabs(s->velocity) < 1e-3) { s->value = s->target; s->velocity = 0; return NO; }
  return YES;
}

// ---------------------------------------------------------------- traffic lights
// Standard window buttons only show their ×/–/+ glyphs while the pointer is over the button group. On current macOS
// they ask the window's theme frame (NSThemeFrame -_mouseInGroup:, set by -mouseEnteredLeftButtonGroup /
// -mouseExitedLeftButtonGroup), then refresh on -mouseEnteredOrExited; older systems asked the buttons' superview.
@interface SRTrafficLights : NSView
@property (nonatomic) BOOL mouseInside;
@end
@implementation SRTrafficLights
- (instancetype)initWithStyleMask:(NSWindowStyleMask)style {
  if (!(self = [super initWithFrame:NSZeroRect])) return nil;
  CGFloat x = 0, h = 0;
  for (NSNumber *t in @[ @(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton) ]) {
    NSButton *b = [NSWindow standardWindowButton:(NSWindowButton)t.integerValue forStyleMask:style];
    [b setFrameOrigin:NSMakePoint(x, 0)];
    [self addSubview:b];
    x += NSWidth(b.frame) + kLightsSpacing; h = MAX(h, NSHeight(b.frame));
  }
  [self setFrameSize:NSMakeSize(x - kLightsSpacing, h)];
  return self;
}
- (BOOL)_mouseInGroup:(NSButton *)button { return self.mouseInside; }
- (void)setMouseInside:(BOOL)inside {
  if (_mouseInside == inside) return;
  _mouseInside = inside;
  NSView *themeFrame = self.window.contentView.superview;
  SEL sel = NSSelectorFromString(inside ? @"mouseEnteredLeftButtonGroup" : @"mouseExitedLeftButtonGroup");
  if ([themeFrame respondsToSelector:sel]) ((void (*)(id, SEL))[themeFrame methodForSelector:sel])(themeFrame, sel);
  SEL refresh = NSSelectorFromString(@"mouseEnteredOrExited");
  for (NSView *b in self.subviews) {
    if ([b respondsToSelector:refresh]) ((void (*)(id, SEL))[b methodForSelector:refresh])(b, refresh);
    b.needsDisplay = YES;
  }
}
@end

// Title strip and margins: dragging them moves the window.
@interface SRDragView : NSView @end
@implementation SRDragView
- (void)mouseDown:(NSEvent *)e { [self.window performWindowDragWithEvent:e]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
@end

// Phone screen hairline, shown with the chrome.
@interface SRHairline : NSView @property CGFloat radius; @end
@implementation SRHairline
- (void)drawRect:(NSRect)r {
  CGPathRef p = CreateContinuousRect(NSInsetRect(self.bounds, 0.5, 0.5), _radius, _radius, _radius, _radius, NSHeight(self.bounds));
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  CGContextAddPath(ctx, p); CGContextSetStrokeColorWithColor(ctx, NSColor.quaternaryLabelColor.CGColor);
  CGContextSetLineWidth(ctx, 1); CGContextStrokePath(ctx); CGPathRelease(p);
}
- (NSView *)hitTest:(NSPoint)p { return nil; }
@end

// ---------------------------------------------------------------- root view: hover tracking
typedef NS_ENUM(NSInteger, SRHover) { SRHoverNone, SRHoverTitleBar, SRHoverStatusBar, SRHoverContent, SRHoverChrome };

@interface SRMirrorWindow ()
- (void)hoverAt:(NSPoint)p;
- (void)hoverExited;
@end

@interface SRMirrorRootView : SRDragView
@property (weak) SRMirrorWindow *mirror;
@end
@implementation SRMirrorRootView
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
      options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)e { [self.mirror hoverAt:[self convertPoint:e.locationInWindow fromView:nil]]; }
- (void)mouseMoved:(NSEvent *)e { [self.mirror hoverAt:[self convertPoint:e.locationInWindow fromView:nil]]; }
- (void)mouseExited:(NSEvent *)e { [self.mirror hoverExited]; }
- (NSView *)hitTest:(NSPoint)p {
  NSView *v = [super hitTest:p];
  return [v isKindOfClass:NSVisualEffectView.class] ? self : v;   // the material is a drag surface
}
@end

// ---------------------------------------------------------------- window
@implementation SRMirrorWindow {
  SRMirrorRootView *_root;
  NSVisualEffectView *_material;
  SRHairline *_hairline;
  SRDragView *_strip;
  SRTrafficLights *_lights;
  NSView *_screen;
  NSSize _size;            // device screen size (points)
  CGFloat _radius;         // device screen corner radius c
  SRSpring _shape, _stripAlpha;
  SRHover _hover;
  CADisplayLink *_link; CFTimeInterval _lastTick;
}

- (instancetype)initWithScreenView:(NSView *)screenView size:(NSSize)size cornerRadius:(CGFloat)cornerRadius {
  NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView;
  NSRect frame = NSMakeRect(0, 0, size.width + 2 * kMargin, size.height + kStrip + kMargin);
  if (!(self = [super initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO])) return nil;
  _size = size; _radius = cornerRadius;
  self.titlebarAppearsTransparent = YES;
  self.titleVisibility = NSWindowTitleHidden;
  self.opaque = NO;
  self.backgroundColor = NSColor.clearColor;
  self.hasShadow = YES;
  self.releasedWhenClosed = NO;
  // SimRun draws its own title strip; the system one would sit over it (and over the screen while hidden)
  [self standardWindowButton:NSWindowCloseButton].superview.superview.hidden = YES;

  _root = [[SRMirrorRootView alloc] initWithFrame:frame];
  _root.mirror = self; _root.wantsLayer = YES;
  _material = [[NSVisualEffectView alloc] initWithFrame:frame];   // the chrome background (SwiftUI .ultraThinMaterial)
  _material.material = NSVisualEffectMaterialUnderWindowBackground;
  _material.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  _material.state = NSVisualEffectStateActive;
  _material.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _screen = screenView;
  _screen.wantsLayer = YES;
  _screen.layer.cornerRadius = _radius; _screen.layer.cornerCurve = kCACornerCurveContinuous; _screen.layer.masksToBounds = YES;
  _hairline = [[SRHairline alloc] initWithFrame:NSZeroRect]; _hairline.radius = _radius;
  _strip = [[SRDragView alloc] initWithFrame:NSZeroRect];
  _lights = [[SRTrafficLights alloc] initWithStyleMask:style];
  [_strip addSubview:_lights];
  for (NSView *v in @[ _material, _screen, _hairline, _strip ]) [_root addSubview:v];
  self.contentView = _root;

  SpringSetResponse(&_shape, 0.28, 1);
  SpringSetResponse(&_stripAlpha, 0.7, 1);
  [self layoutViews];
  [self applyState];
  return self;
}

- (void)dealloc { [_link invalidate]; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }

// ---------------------------------------------------------------- geometry
- (NSRect)screenFrame { return NSMakeRect(NSMinX(self.frame) + kMargin, NSMinY(self.frame) + kMargin, _size.width, _size.height); }
- (BOOL)isExpanded { return _shape.target > 0.5; }
- (NSSize)screenSize { return _size; }
- (void)setScreenSize:(NSSize)size {
  if (NSEqualSizes(size, _size)) return;
  NSPoint topLeft = NSMakePoint(NSMinX(self.frame), NSMaxY(self.frame));   // keep the screen's top-left
  _size = size;
  NSRect f = NSMakeRect(topLeft.x, topLeft.y - (size.height + kStrip + kMargin), size.width + 2 * kMargin, size.height + kStrip + kMargin);
  [self setFrame:f display:YES];
  [self layoutViews];
  [self applyState];
}
- (void)setScreenTopLeft:(NSPoint)topLeft { [self setFrameTopLeftPoint:NSMakePoint(topLeft.x - kMargin, topLeft.y + kStrip)]; }

- (void)layoutViews {
  _screen.frame = NSMakeRect(kMargin, kMargin, _size.width, _size.height);
  _hairline.frame = _screen.frame;
  NSSize ls = _lights.frame.size;
  [_lights setFrameOrigin:NSMakePoint(kLightsInset, (kStrip - ls.height) / 2)];
  [_strip setFrameSize:NSMakeSize(NSWidth(_root.bounds), kStrip)];
}

static CGFloat Lerp(CGFloat a, CGFloat b, CGFloat t) { return a + (b - a) * t; }

// Shape, strip and hairline for the current spring values.
- (void)applyState {
  CGFloat p = _shape.value, alpha = MAX(0, MIN(1, _stripAlpha.value));
  NSRect b = _root.bounds;
  // insets (top, sides, bottom) and radii interpolate between "just the screen" and "the whole frame"
  CGFloat top = Lerp(kStrip, 0, p), side = Lerp(kMargin, 0, p);
  CGFloat rTop = Lerp(_radius, kTopRadius, p), rBottom = Lerp(_radius, _radius + kMargin, p);
  CGRect shape = CGRectMake(side, top, NSWidth(b) - 2 * side, NSHeight(b) - top - side);   // top-left origin
  CGPathRef path = CreateContinuousRect(shape, rTop, rTop, rBottom, rBottom, NSHeight(b));
  if ([self respondsToSelector:@selector(_setCornerPath:)]) [self _setCornerPath:path];
  CGPathRelease(path);
  // the strip slides down by its height while hidden (it then sits, invisible, over the top of the screen)
  [_strip setFrameOrigin:NSMakePoint(0, NSHeight(b) - kStrip - kStrip * (1 - p))];
  _strip.alphaValue = alpha;
  _strip.hidden = alpha < 0.01 && p < 0.01;
  _hairline.alphaValue = p;
}

// ---------------------------------------------------------------- animation
- (void)setChromeVisible:(BOOL)visible {
  CGFloat target = visible ? 1 : 0;
  if (_shape.target == target) return;
  _shape.target = target; _stripAlpha.target = target;
  SpringSetResponse(&_stripAlpha, visible ? 0.7 : 0.14, 1);
  if (!_link) {
    _link = [_root displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    _lastTick = CACurrentMediaTime();
  }
}
- (void)tick:(CADisplayLink *)link {
  CFTimeInterval now = CACurrentMediaTime();
  CGFloat dt = MIN(0.05, MAX(0.001, now - _lastTick)); _lastTick = now;
  BOOL a = SpringStep(&_shape, dt), b = SpringStep(&_stripAlpha, dt);
  [self applyState];
  if (!a && !b) {
    [_link invalidate]; _link = nil;
    if ([self respondsToSelector:@selector(_setNeedsToResetDragMargins:)]) [self _setNeedsToResetDragMargins:YES];
    [self invalidateShadow];
  }
}

// ---------------------------------------------------------------- hover
- (SRHover)hoverForPoint:(NSPoint)p {
  NSRect r = _screen.frame;
  if (!NSPointInRect(p, _root.bounds)) return SRHoverNone;
  if (p.y >= NSMaxY(r)) return SRHoverTitleBar;
  if (NSPointInRect(p, r)) return p.y >= NSMaxY(r) - kStatusBarZone ? SRHoverStatusBar : SRHoverContent;
  return SRHoverChrome;
}
- (void)hoverAt:(NSPoint)p {
  _lights.mouseInside = !_strip.hidden && NSPointInRect([_strip convertPoint:p fromView:_root], NSInsetRect(_lights.frame, -2, -2));
  if (NSEvent.pressedMouseButtons) return;   // a drag on the screen is a touch, not hover
  SRHover h = [self hoverForPoint:p], prev = _hover;
  _hover = h;
  switch (h) {
    case SRHoverTitleBar: case SRHoverStatusBar: [self setChromeVisible:YES]; break;
    case SRHoverContent: case SRHoverNone: [self setChromeVisible:NO]; break;
    case SRHoverChrome:   // the margins keep the chrome only if the pointer came from it or from the top
      if (prev != SRHoverTitleBar && prev != SRHoverStatusBar && prev != SRHoverChrome) [self setChromeVisible:NO];
      break;
  }
}
- (void)hoverExited {
  _lights.mouseInside = NO;
  _hover = SRHoverNone;
  if (!NSEvent.pressedMouseButtons) [self setChromeVisible:NO];
}
@end
