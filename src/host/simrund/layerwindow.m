// layerwindow.m — see layerwindow.h. The canvas holds the flat copy (the mirror's root layer, in a layer scaled to fit)
// and the 3D scene's camera (layerscene.h); one of them shows. Underneath, a bar with the mode, the 3D switches and a
// line about the selected layer (click one, in either mode).
#import "layerwindow.h"
#import "layermirror.h"
#import "layerscene.h"
#import "session.h"

// ---------------------------------------------------------------- canvas: layer-hosting, passes the mouse on
@interface SRLayerCanvas : NSView
@property (strong) CALayer *fit;   // the flat copy's parent: the screen, scaled to fit and centered
@property NSSize screenSize;
@property (copy) void (^onResize)(NSSize size);
@property (copy) void (^onClick)(CGPoint p, NSInteger clicks);   // p in the canvas layer's coordinates
@property (copy) void (^onDrag)(CGFloat dx, CGFloat dy);
@property (copy) void (^onScroll)(CGFloat dx, CGFloat dy);
@property (copy) void (^onMagnify)(CGFloat m);
@end
@implementation SRLayerCanvas {
  NSPoint _down; BOOL _dragged;
}
- (instancetype)initWithFrame:(NSRect)r {
  if (!(self = [super initWithFrame:r])) return nil;
  self.layer = [CALayer layer];   // layer-hosting: set before wantsLayer
  self.wantsLayer = YES;
  self.layer.backgroundColor = [NSColor colorWithWhite:0.93 alpha:1].CGColor;
  _fit = [CALayer layer];
  [self.layer addSublayer:_fit];
  return self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self refit]; if (self.onResize) self.onResize(size); }
- (void)refit {
  if (!_screenSize.width || !_screenSize.height) return;
  NSSize b = self.bounds.size;
  CGFloat s = MAX(0.05, MIN((b.width - 24) / _screenSize.width, (b.height - 24) / _screenSize.height));
  [CATransaction begin]; [CATransaction setDisableActions:YES];
  _fit.bounds = CGRectMake(0, 0, _screenSize.width, _screenSize.height);
  _fit.position = CGPointMake(b.width / 2, b.height / 2);
  _fit.transform = CATransform3DMakeScale(s, s, 1);
  self.layer.sublayerTransform = SRScenePerspective(b);
  [CATransaction commit];
}
- (void)mouseDown:(NSEvent *)e { _down = e.locationInWindow; _dragged = NO; }
- (void)mouseDragged:(NSEvent *)e {
  if (!_dragged && hypot(e.locationInWindow.x - _down.x, e.locationInWindow.y - _down.y) < 3) return;
  _dragged = YES;
  if (self.onDrag) self.onDrag(e.deltaX, e.deltaY);
}
- (void)mouseUp:(NSEvent *)e {
  // a layer-hosting view's coordinates are its layer's
  if (!_dragged && self.onClick) self.onClick(NSPointToCGPoint([self convertPoint:e.locationInWindow fromView:nil]), e.clickCount);
}
- (void)scrollWheel:(NSEvent *)e { if (self.onScroll) self.onScroll(e.scrollingDeltaX, e.scrollingDeltaY); }
- (void)magnifyWithEvent:(NSEvent *)e { if (self.onMagnify) self.onMagnify(e.magnification); }
@end

// ---------------------------------------------------------------- window
static NSMapTable<SRSession *, SRLayerWindow *> *gWindows;
static NSMutableSet<SRLayerWindow *> *gOpen;   // kept while their window is open, even after the app has gone

static const CGFloat kYaw = -0.55, kPitch = 0.3;   // the 3D view's starting angle: turned left, tilted back

@implementation SRLayerWindow {
  __weak SRSession *_session;
  id _token;
  SRLayerMirror *_mirror;
  SRLayerScene *_scene;      // made the first time 3D is shown
  BOOL _sceneStale;          // batches came while flat
  BOOL _threeD;
  NSNumber *_selected;
  CALayer *_highlight;       // the selection, in flat mode
  SRLayerCanvas *_canvas;
  NSSegmentedControl *_mode;
  NSSlider *_spacing;
  NSButton *_clip, *_wireframes, *_placeholders;
  NSTextField *_status;
}

+ (void)showForSession:(SRSession *)session {
  if (!gWindows) gWindows = [NSMapTable weakToStrongObjectsMapTable];
  SRLayerWindow *w = [gWindows objectForKey:session];
  if (!w) {
    w = [[self alloc] initWithSession:session];
    if (!w) { NSBeep(); return; }
    [gWindows setObject:w forKey:session];
    if (!gOpen) gOpen = [NSMutableSet set];
    [gOpen addObject:w];
  }
  [w showWindow:nil];
}

static NSButton *Check(NSString *title, id target, SEL action, NSString *tip) {
  NSButton *b = [NSButton checkboxWithTitle:title target:target action:action];
  b.state = NSControlStateValueOn; b.toolTip = tip;
  b.controlSize = NSControlSizeSmall; b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  [b sizeToFit];
  return b;
}

- (instancetype)initWithSession:(SRSession *)session {
  NSRect appFrame = session.window.frame;
  CGFloat h = MAX(NSHeight(appFrame), 560), w = MAX(round(h * 0.62), 420);
  NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
      backing:NSBackingStoreBuffered defer:NO];
  win.title = [NSString stringWithFormat:@"%@ — Layers", session.title];
  win.releasedWhenClosed = NO;
  win.minSize = NSMakeSize(420, 360);
  if (!(self = [super initWithWindow:win])) return nil;
  _session = session;
  win.delegate = self;

  NSView *content = win.contentView;
  const CGFloat bar = 54;
  _canvas = [[SRLayerCanvas alloc] initWithFrame:NSMakeRect(0, bar, w, h - bar)];
  _canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [content addSubview:_canvas];

  _mode = [NSSegmentedControl segmentedControlWithLabels:@[ @"Flat", @"3D" ] trackingMode:NSSegmentSwitchTrackingSelectOne
                                                  target:self action:@selector(modeChanged:)];
  _mode.selectedSegment = 0; _mode.controlSize = NSControlSizeSmall;
  _mode.toolTip = @"3D: drag to turn, pinch to zoom, scroll to pan, double-click to reset";
  [_mode sizeToFit];
  _mode.frame = (NSRect){ NSMakePoint(10, 28), _mode.frame.size };
  [content addSubview:_mode];
  CGFloat x = NSMaxX(_mode.frame) + 12;
  _spacing = [NSSlider sliderWithValue:12 minValue:2 maxValue:60 target:self action:@selector(spacingChanged:)];
  _spacing.controlSize = NSControlSizeSmall; _spacing.toolTip = @"Space between planes";
  _spacing.frame = NSMakeRect(x, 28, 90, 20);
  [content addSubview:_spacing];
  x = NSMaxX(_spacing.frame) + 10;
  _clip = Check(@"Clip", self, @selector(clipChanged:), @"Hide what a superlayer clips (masksToBounds)");
  _wireframes = Check(@"Outlines", self, @selector(wireframesChanged:), @"An outline around every layer");
  _placeholders = Check(@"Stand-ins", self, @selector(placeholdersChanged:),
                        @"Blue: what a layer drew or shows (not copied yet). Orange: layers the Mac can't draw (blur, portals, Metal…).");
  for (NSButton *b in @[ _clip, _wireframes, _placeholders ]) {
    b.frame = (NSRect){ NSMakePoint(x, 29), b.frame.size };
    [content addSubview:b];
    x = NSMaxX(b.frame) + 8;
  }
  _status = [NSTextField labelWithString:@"Waiting for the app…"];
  _status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  _status.textColor = NSColor.secondaryLabelColor;
  _status.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _status.selectable = YES;
  _status.frame = NSMakeRect(12, 6, w - 24, 16);
  _status.autoresizingMask = NSViewWidthSizable;
  [content addSubview:_status];
  [self updateControls];

  __weak SRLayerWindow *weakSelf = self;
  _canvas.onResize = ^(NSSize size) { SRLayerWindow *s = weakSelf; if (s) [s->_scene layoutInSize:size]; };
  _canvas.onClick = ^(CGPoint p, NSInteger clicks) { [weakSelf clickAt:p clicks:clicks]; };
  _canvas.onDrag = ^(CGFloat dx, CGFloat dy) {
    SRLayerWindow *s = weakSelf;
    if (!s || !s->_threeD) return;
    s->_scene.yaw += dx * 0.01;
    s->_scene.pitch += dy * 0.01;
  };
  _canvas.onScroll = ^(CGFloat dx, CGFloat dy) {
    SRLayerWindow *s = weakSelf;
    if (s && s->_threeD) s->_scene.pan = CGPointMake(s->_scene.pan.x + dx, s->_scene.pan.y - dy);
  };
  _canvas.onMagnify = ^(CGFloat m) { SRLayerWindow *s = weakSelf; if (s && s->_threeD) s->_scene.zoom *= 1 + m; };

  _token = [session addLayerObserver:^(SRLayerMirror *mirror, NSDictionary *changes) { [weakSelf mirror:mirror changed:changes]; }];
  if (!_token) return nil;
  [win setFrameTopLeftPoint:NSMakePoint(NSMaxX(appFrame) + 16, NSMaxY(appFrame))];   // beside the app's window
  return self;
}

// ---------------------------------------------------------------- updates from the app
- (void)mirror:(SRLayerMirror *)mirror changed:(NSDictionary *)changes {
  if (!changes) {   // the app went away: keep showing the last copy
    _token = nil;
    _status.stringValue = @"The app has quit";
    self.window.title = [self.window.title stringByAppendingString:@" (exited)"];
    return;
  }
  if (mirror != _mirror) {
    [_mirror.rootLayer removeFromSuperlayer];
    [_scene.cameraLayer removeFromSuperlayer]; _scene = nil;
    _mirror = mirror;
    _mirror.showsPlaceholders = _placeholders.state == NSControlStateValueOn;
    [_canvas.fit addSublayer:mirror.rootLayer];
    if (_threeD) [self showScene];
  } else if (_scene) {
    if (_threeD) { [_scene updateWithChanges:changes]; _spacing.doubleValue = _scene.spacing; }   // a full batch may choose a new spacing
    else _sceneStale = YES;
  }
  NSSize screen = mirror.rootLayer.bounds.size;
  if (!NSEqualSizes(screen, _canvas.screenSize)) { _canvas.screenSize = screen; [_canvas refit]; [_scene layoutInSize:_canvas.bounds.size]; }
  if (_selected && !mirror.nodes[_selected]) [self select:nil];
  else [self showSelection];
}

// ---------------------------------------------------------------- modes and switches
- (void)showScene {
  if (!_mirror) return;
  if (!_scene) {
    _scene = [[SRLayerScene alloc] initWithMirror:_mirror];
    _scene.clipsContent = _clip.state == NSControlStateValueOn;
    _scene.showsWireframes = _wireframes.state == NSControlStateValueOn;
    _scene.showsPlaceholders = _placeholders.state == NSControlStateValueOn;
    _scene.selectedNode = _selected;
    _spacing.doubleValue = _scene.spacing;
  } else if (_sceneStale) [_scene updateWithChanges:@{ @"full": @YES }];
  _sceneStale = NO;
  _spacing.doubleValue = _scene.spacing;
  [CATransaction begin]; [CATransaction setDisableActions:YES];
  if (!_scene.cameraLayer.superlayer) [_canvas.layer addSublayer:_scene.cameraLayer];
  _canvas.fit.hidden = YES;
  _scene.cameraLayer.hidden = NO;
  _scene.yaw = 0; _scene.pitch = 0; _scene.zoom = 1; _scene.pan = CGPointZero;
  [_scene layoutInSize:_canvas.bounds.size];
  [CATransaction commit];
  [_scene animate:^{ self->_scene.yaw = kYaw; self->_scene.pitch = kPitch; }];   // swing round from straight on
}
- (void)modeChanged:(NSSegmentedControl *)c {
  _threeD = c.selectedSegment == 1;
  if (_threeD) [self showScene];
  else {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _scene.cameraLayer.hidden = YES; _canvas.fit.hidden = NO;
    [CATransaction commit];
  }
  [self updateControls];
  [self showSelection];
}
- (void)updateControls { for (NSControl *c in @[ _spacing, _clip, _wireframes ]) c.enabled = _threeD; }
- (void)spacingChanged:(NSSlider *)s { _scene.spacing = s.doubleValue; }
- (void)clipChanged:(NSButton *)b { _scene.clipsContent = b.state == NSControlStateValueOn; }
- (void)wireframesChanged:(NSButton *)b { _scene.showsWireframes = b.state == NSControlStateValueOn; }
- (void)placeholdersChanged:(NSButton *)b {
  BOOL on = b.state == NSControlStateValueOn;
  _mirror.showsPlaceholders = on; _scene.showsPlaceholders = on;
}

// ---------------------------------------------------------------- selection
- (void)clickAt:(CGPoint)p clicks:(NSInteger)clicks {
  if (_threeD && clicks == 2) {   // double-click: back to the starting angle
    [_scene animate:^{ self->_scene.yaw = kYaw; self->_scene.pitch = kPitch; self->_scene.zoom = 1; self->_scene.pan = CGPointZero; }];
    return;
  }
  NSNumber *n = _threeD ? [_scene nodeAtPoint:p fromLayer:_canvas.layer] : [_mirror nodeAtPoint:p fromLayer:_canvas.layer];
  [self select:[n isEqual:@1] ? nil : n];
}
- (void)select:(NSNumber *)nid {
  _selected = nid;
  _scene.selectedNode = nid;
  [self showSelection];
}
// The flat mode's highlight, and the line underneath.
- (void)showSelection {
  [CATransaction begin]; [CATransaction setDisableActions:YES];
  CGRect r = _selected ? [_mirror screenRectOfNode:_selected] : CGRectNull;
  if (!_threeD && !CGRectIsNull(r) && _mirror.rootLayer.superlayer) {
    if (!_highlight) {
      _highlight = [CALayer layer];
      _highlight.borderColor = NSColor.systemBlueColor.CGColor;
      _highlight.backgroundColor = [NSColor.systemBlueColor colorWithAlphaComponent:0.15].CGColor;
    }
    if (_highlight.superlayer != _canvas.fit) [_canvas.fit addSublayer:_highlight];
    _highlight.frame = [_canvas.fit convertRect:r fromLayer:_mirror.rootLayer];
    CGFloat scale = _canvas.fit.transform.m11 ?: 1;
    _highlight.borderWidth = 2 / scale;
    _highlight.hidden = NO;
  } else _highlight.hidden = YES;
  [CATransaction commit];
  NSString *line = _selected ? [_mirror describeNode:_selected] : nil;
  _status.stringValue = line ?: [NSString stringWithFormat:@"%lu layers · %lu updates%@", (unsigned long)_mirror.nodeCount,
                                 (unsigned long)_mirror.batchCount, _threeD ? [NSString stringWithFormat:@" · %ld levels", (long)_scene.levels] : @""];
  _status.toolTip = line;
}

- (void)windowWillClose:(NSNotification *)n {
  [_session removeLayerObserver:_token];   // the last watcher stops the stream
  _token = nil;
  SRSession *s = _session;
  if (s) [gWindows removeObjectForKey:s];
  dispatch_async(dispatch_get_main_queue(), ^{ [gOpen removeObject:self]; });
}
@end
