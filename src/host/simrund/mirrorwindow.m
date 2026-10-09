// mirrorwindow.m — see mirrorwindow.h.
//
// The window is titled (real window behaviour: key/main, ⌘W, miniaturize) with a full-size content view and a clear
// background, but the system title bar is hidden: SimRun draws its own frame. Its frame is either exactly the device
// screen ("collapsed": all corners = device radius) or that rect grown by a margin on the sides/bottom and a title strip
// on top ("expanded": a frame background and our own traffic lights fade in; top corners = the system window radius,
// bottom corners = device radius + margin). The device screen's position on screen is the anchor: every animation step
// sets the window frame and the screen view's offset inside it together, so the screen never moves while the frame
// grows around it.
#import "mirrorwindow.h"
#import <QuartzCore/QuartzCore.h>

@interface NSWindow (SRPrivate)
- (CGFloat)_topCornerRadius;      // AppKit private: corner mask (and shadow shape) radii
- (CGFloat)_bottomCornerRadius;
- (void)_cornerMaskChanged;
@end

static const CGFloat kMargin = 8;              // frame margin around the screen (sides and bottom) when expanded
static const CGFloat kStrip = 40;              // title strip above the screen when expanded
static const CGFloat kLightsLeft = 13;         // traffic lights: left inset and vertical centre within the strip
static const CGFloat kLightsCenterY = 20;
static const CGFloat kHotZone = 44;            // hovering this close to the top of the screen reveals the frame
static const NSTimeInterval kDuration = 0.24;
static const NSTimeInterval kCollapseDelay = 0.35;

CGFloat SRDeviceCornerRadius(NSString *capabilitiesPath) {
  NSDictionary *caps = capabilitiesPath ? [NSDictionary dictionaryWithContentsOfFile:capabilitiesPath] : nil;
  NSNumber *r = caps[@"capabilities"][@"DeviceCornerRadius"];
  return [r isKindOfClass:NSNumber.class] && r.doubleValue > 0 ? r.doubleValue : 55;
}

// A rounded rect with separate top and bottom corner radii (non-flipped coordinates).
static NSBezierPath *RoundedPath(NSRect r, CGFloat top, CGFloat bottom) {
  top = MIN(top, MIN(NSWidth(r), NSHeight(r)) / 2); bottom = MIN(bottom, MIN(NSWidth(r), NSHeight(r)) / 2);
  NSBezierPath *p = [NSBezierPath bezierPath];
  [p moveToPoint:NSMakePoint(NSMinX(r) + bottom, NSMinY(r))];
  [p appendBezierPathWithArcFromPoint:NSMakePoint(NSMaxX(r), NSMinY(r)) toPoint:NSMakePoint(NSMaxX(r), NSMaxY(r)) radius:bottom];
  [p appendBezierPathWithArcFromPoint:NSMakePoint(NSMaxX(r), NSMaxY(r)) toPoint:NSMakePoint(NSMinX(r), NSMaxY(r)) radius:top];
  [p appendBezierPathWithArcFromPoint:NSMakePoint(NSMinX(r), NSMaxY(r)) toPoint:NSMakePoint(NSMinX(r), NSMinY(r)) radius:top];
  [p appendBezierPathWithArcFromPoint:NSMakePoint(NSMinX(r), NSMinY(r)) toPoint:NSMakePoint(NSMaxX(r), NSMinY(r)) radius:bottom];
  [p closePath];
  return p;
}

// ---------------------------------------------------------------- traffic lights
// Standard window buttons only show their ×/–/+ glyphs while the pointer is over the button group. On current macOS
// they ask the window's theme frame (NSThemeFrame -_mouseInGroup:, set by -mouseEnteredLeftButtonGroup /
// -mouseExitedLeftButtonGroup); older systems asked the buttons' superview (-_mouseInGroup: here). mouseInside is
// driven by the window's hover tracking: this view starts hidden, so a tracking area of its own is never installed.
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
    x += NSWidth(b.frame) + 6; h = MAX(h, NSHeight(b.frame));   // 6 pt gap, like the system title bar
  }
  [self setFrameSize:NSMakeSize(x - 6, h)];
  return self;
}
- (BOOL)_mouseInGroup:(NSButton *)button { return self.mouseInside; }
- (void)setMouseInside:(BOOL)inside {
  if (_mouseInside == inside) return;
  _mouseInside = inside;
  // The widgets ask the window's theme frame whether the pointer is in the button group; tell it.
  NSView *themeFrame = self.window.contentView.superview;
  SEL sel = inside ? NSSelectorFromString(@"mouseEnteredLeftButtonGroup") : NSSelectorFromString(@"mouseExitedLeftButtonGroup");
  if ([themeFrame respondsToSelector:sel]) ((void (*)(id, SEL))[themeFrame methodForSelector:sel])(themeFrame, sel);
  SEL refresh = NSSelectorFromString(@"mouseEnteredOrExited");   // _NSThemeWidget: re-reads the group hover state
  for (NSView *b in self.subviews) {
    if ([b respondsToSelector:refresh]) ((void (*)(id, SEL))[b methodForSelector:refresh])(b, refresh);
    b.needsDisplay = YES;
  }
}
@end

// ---------------------------------------------------------------- root view
// Hosts the frame background, the screen view and the traffic lights; reports hover; dragging the frame moves the window.
@interface SRMirrorRootView : NSView
@property (weak) SRMirrorWindow *mirror;
@end

@interface SRMirrorWindow ()
- (void)hoverAt:(NSPoint)p;
- (void)hoverExited;
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
  return [v isKindOfClass:NSVisualEffectView.class] ? self : v;   // the frame background is just a drag surface
}
- (void)mouseDown:(NSEvent *)e { [self.window performWindowDragWithEvent:e]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
@end

// ---------------------------------------------------------------- window
@implementation SRMirrorWindow {
  SRMirrorRootView *_root;
  NSVisualEffectView *_frameBackground;
  SRTrafficLights *_lights;
  NSView *_screen;
  CGFloat _radius, _systemRadius;
  CGFloat _topRadius, _bottomRadius;   // current corner radii (what -_topCornerRadius/-_bottomCornerRadius report)
  NSRect _anchor;                       // device screen, screen coordinates
  CGFloat _progress;                    // 0 collapsed … 1 expanded
  CGFloat _from, _to; CFTimeInterval _animStart;
  CADisplayLink *_link;
  BOOL _inLayout;
  NSTimer *_collapseTimer;
}

- (instancetype)initWithScreenView:(NSView *)screenView size:(NSSize)size cornerRadius:(CGFloat)cornerRadius {
  NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView;
  if (!(self = [super initWithContentRect:NSMakeRect(0, 0, size.width, size.height) styleMask:style backing:NSBackingStoreBuffered defer:NO])) return nil;
  _radius = cornerRadius;
  _systemRadius = [super respondsToSelector:@selector(_topCornerRadius)] ? [super _topCornerRadius] : 16;
  if (_systemRadius <= 0 || _systemRadius > 40) _systemRadius = 16;
  _topRadius = _bottomRadius = _radius;
  self.titlebarAppearsTransparent = YES;
  self.titleVisibility = NSWindowTitleHidden;
  self.opaque = NO;
  self.backgroundColor = NSColor.clearColor;
  self.hasShadow = YES;
  self.releasedWhenClosed = NO;
  // the system title bar would sit invisibly over the top of the device screen: SimRun draws its own
  NSView *titlebarContainer = [self standardWindowButton:NSWindowCloseButton].superview.superview;
  titlebarContainer.hidden = YES;

  _root = [[SRMirrorRootView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
  _root.mirror = self; _root.wantsLayer = YES;
  _frameBackground = [[NSVisualEffectView alloc] initWithFrame:_root.bounds];
  _frameBackground.material = NSVisualEffectMaterialWindowBackground;
  _frameBackground.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  _frameBackground.state = NSVisualEffectStateActive;
  _frameBackground.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _frameBackground.alphaValue = 0;
  _screen = screenView;
  _screen.wantsLayer = YES;
  _screen.layer.cornerRadius = _radius; _screen.layer.cornerCurve = kCACornerCurveContinuous; _screen.layer.masksToBounds = YES;
  _lights = [[SRTrafficLights alloc] initWithStyleMask:style];
  _lights.alphaValue = 0; _lights.hidden = YES;
  [_root addSubview:_frameBackground];
  [_root addSubview:_screen];
  [_root addSubview:_lights];
  self.contentView = _root;

  _anchor = NSMakeRect(0, 0, size.width, size.height);
  [self applyProgress:0];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didMove:) name:NSWindowDidMoveNotification object:self];
  return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_link invalidate]; [_collapseTimer invalidate]; }

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
// AppKit builds the window's corner mask and shadow from these.
- (CGFloat)_topCornerRadius { return _topRadius; }
- (CGFloat)_bottomCornerRadius { return _bottomRadius; }

// ---------------------------------------------------------------- geometry
- (NSRect)screenFrame { return _anchor; }
- (BOOL)isExpanded { return _to > 0.5; }
- (NSSize)screenSize { return _anchor.size; }
- (void)setScreenSize:(NSSize)size {
  if (NSEqualSizes(size, _anchor.size)) return;
  CGFloat top = NSMaxY(_anchor);
  _anchor.size = size; _anchor.origin.y = top - size.height;   // keep the top-left
  [self applyProgress:_progress];
}
- (void)setScreenTopLeft:(NSPoint)topLeft {
  _anchor.origin = NSMakePoint(topLeft.x, topLeft.y - NSHeight(_anchor));
  [self applyProgress:_progress];
}
// Window moved by the user (dragging the frame): the screen moves with it.
- (void)didMove:(NSNotification *)n {
  if (_inLayout) return;
  CGFloat m = kMargin * _progress;
  _anchor.origin = NSMakePoint(NSMinX(self.frame) + m, NSMinY(self.frame) + m);
}

static CGFloat Ease(CGFloat t) { return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2; }   // ease-in-out cubic
static CGFloat Lerp(CGFloat a, CGFloat b, CGFloat t) { return a + (b - a) * t; }

- (void)applyProgress:(CGFloat)p {
  _progress = p;
  CGFloat m = kMargin * p, strip = kStrip * p;
  NSRect frame = NSMakeRect(NSMinX(_anchor) - m, NSMinY(_anchor) - m, NSWidth(_anchor) + 2 * m, NSHeight(_anchor) + m + strip);
  _topRadius = Lerp(_radius, _systemRadius, p);
  _bottomRadius = _radius + m;
  _inLayout = YES;
  [self setFrame:frame display:YES];
  _inLayout = NO;
  _screen.frame = NSMakeRect(m, m, NSWidth(_anchor), NSHeight(_anchor));
  // traffic lights ride with the top edge; vertically centred in the strip once it is fully open
  NSSize ls = _lights.frame.size;
  [_lights setFrameOrigin:NSMakePoint(Lerp(0, kLightsLeft, p), NSHeight(frame) - kLightsCenterY - ls.height / 2)];
  _lights.alphaValue = p; _lights.hidden = p < 0.01;
  _frameBackground.alphaValue = p;
  _frameBackground.maskImage = [self maskImage];
  if ([self respondsToSelector:@selector(_cornerMaskChanged)]) [self _cornerMaskChanged];
  if (p == 0 || p == 1) [self invalidateShadow];
}

- (NSImage *)maskImage {
  CGFloat top = _topRadius, bottom = _bottomRadius, w = MAX(top, bottom) * 2 + 1;
  NSImage *img = [NSImage imageWithSize:NSMakeSize(w, top + bottom + 1) flipped:NO drawingHandler:^BOOL(NSRect rect) {
    [NSColor.blackColor setFill];
    [RoundedPath(rect, top, bottom) fill];
    return YES;
  }];
  img.capInsets = NSEdgeInsetsMake(top, MAX(top, bottom), bottom, MAX(top, bottom));
  img.resizingMode = NSImageResizingModeStretch;
  return img;
}

// ---------------------------------------------------------------- animation
- (void)animateTo:(CGFloat)target {
  if (_to == target && (_link || _progress == target)) return;
  _from = _progress; _to = target; _animStart = CACurrentMediaTime();
  if (!_link) {
    _link = [_root displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  }
}
- (void)tick:(CADisplayLink *)link {
  CGFloat span = fabs(_to - _from);
  CGFloat t = span > 0 ? MIN(1, (CACurrentMediaTime() - _animStart) / (kDuration * span)) : 1;
  [self applyProgress:_from + (_to - _from) * Ease(t)];
  if (t >= 1) { [_link invalidate]; _link = nil; }
}

// ---------------------------------------------------------------- hover
- (BOOL)isHotPoint:(NSPoint)p {
  NSRect screen = _screen.frame;
  if (!NSPointInRect(p, NSInsetRect(_root.bounds, -1, -1))) return NO;
  if (!NSPointInRect(p, screen)) return _progress > 0;                 // over the revealed frame
  return p.y >= NSMaxY(screen) - kHotZone;                               // near the top of the screen
}
- (void)hoverAt:(NSPoint)p {
  _lights.mouseInside = !_lights.hidden && NSPointInRect(p, NSInsetRect(_lights.frame, -2, -2));
  if (NSEvent.pressedMouseButtons) return;   // a drag on the screen is a touch, not hover
  if ([self isHotPoint:p]) { [_collapseTimer invalidate]; _collapseTimer = nil; [self animateTo:1]; }
  else [self scheduleCollapse];
}
- (void)hoverExited { _lights.mouseInside = NO; if (!NSEvent.pressedMouseButtons) [self scheduleCollapse]; }
- (void)scheduleCollapse {
  if (_to == 0 || _collapseTimer) return;
  __weak SRMirrorWindow *weakSelf = self;
  _collapseTimer = [NSTimer scheduledTimerWithTimeInterval:kCollapseDelay repeats:NO block:^(NSTimer *t) {
    SRMirrorWindow *w = weakSelf; if (!w) return;
    w->_collapseTimer = nil;
    NSPoint p = [w->_root convertPoint:[w mouseLocationOutsideOfEventStream] fromView:nil];
    if (![w isHotPoint:p]) [w animateTo:0];
  }];
}
@end
