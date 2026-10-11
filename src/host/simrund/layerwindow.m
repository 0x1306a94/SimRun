// layerwindow.m — see layerwindow.h. The copy's root layer (the screen, in points) sits in a layer scaled to fit the
// window; a bar underneath has the stand-ins switch and how big the copy is.
#import "layerwindow.h"
#import "layermirror.h"
#import "session.h"

// A layer-hosting view that keeps `fit` (the screen) centered and scaled to fit as it resizes.
@interface SRLayerCanvas : NSView
@property (strong) CALayer *fit;
@property NSSize screenSize;
@end
@implementation SRLayerCanvas
- (instancetype)initWithFrame:(NSRect)r {
  if (!(self = [super initWithFrame:r])) return nil;
  self.layer = [CALayer layer];   // layer-hosting: set before wantsLayer
  self.wantsLayer = YES;
  self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
  _fit = [CALayer layer];
  [self.layer addSublayer:_fit];
  return self;
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self refit]; }
- (void)refit {
  if (!_screenSize.width || !_screenSize.height) return;
  NSSize b = self.bounds.size;
  CGFloat s = MIN((b.width - 24) / _screenSize.width, (b.height - 24) / _screenSize.height);
  [CATransaction begin]; [CATransaction setDisableActions:YES];
  _fit.bounds = CGRectMake(0, 0, _screenSize.width, _screenSize.height);
  _fit.position = CGPointMake(b.width / 2, b.height / 2);
  _fit.transform = CATransform3DMakeScale(MAX(s, 0.05), MAX(s, 0.05), 1);
  [CATransaction commit];
}
@end

static NSMapTable<SRSession *, SRLayerWindow *> *gWindows;
static NSMutableSet<SRLayerWindow *> *gOpen;   // kept while their window is open, even after the app has gone

@implementation SRLayerWindow {
  __weak SRSession *_session;
  id _token;
  SRLayerMirror *_mirror;
  SRLayerCanvas *_canvas;
  NSButton *_placeholders;
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

- (instancetype)initWithSession:(SRSession *)session {
  NSRect appFrame = session.window.frame;
  CGFloat h = MAX(NSHeight(appFrame), 500), w = MAX(round(h * 0.5), 320);
  NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
      backing:NSBackingStoreBuffered defer:NO];
  win.title = [NSString stringWithFormat:@"%@ — Layers", session.title];
  win.releasedWhenClosed = NO;
  win.minSize = NSMakeSize(240, 300);
  if (!(self = [super initWithWindow:win])) return nil;
  _session = session;
  win.delegate = self;

  NSView *content = win.contentView;
  const CGFloat bar = 32;
  _canvas = [[SRLayerCanvas alloc] initWithFrame:NSMakeRect(0, bar, w, h - bar)];
  _canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [content addSubview:_canvas];
  _placeholders = [NSButton checkboxWithTitle:@"Stand-ins" target:self action:@selector(togglePlaceholders:)];
  _placeholders.state = NSControlStateValueOn;
  _placeholders.toolTip = @"Blue: what a layer drew or shows (not copied yet). Orange: layers the Mac can't draw (blur, portals, Metal…).";
  _placeholders.frame = NSMakeRect(10, 6, 110, 20);
  [content addSubview:_placeholders];
  _status = [NSTextField labelWithString:@"Waiting for the app…"];
  _status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  _status.textColor = NSColor.secondaryLabelColor;
  _status.alignment = NSTextAlignmentRight;
  _status.frame = NSMakeRect(120, 8, w - 130, 16);
  _status.autoresizingMask = NSViewWidthSizable;
  [content addSubview:_status];

  __weak SRLayerWindow *weakSelf = self;
  _token = [session addLayerObserver:^(SRLayerMirror *mirror, NSDictionary *changes) { [weakSelf mirror:mirror changed:changes]; }];
  if (!_token) return nil;
  // beside the app's window
  [win setFrameTopLeftPoint:NSMakePoint(NSMaxX(appFrame) + 16, NSMaxY(appFrame))];
  return self;
}

- (void)mirror:(SRLayerMirror *)mirror changed:(NSDictionary *)changes {
  if (!changes) {   // the app went away: keep showing the last copy
    _token = nil;
    _status.stringValue = @"The app has quit";
    self.window.title = [self.window.title stringByAppendingString:@" (exited)"];
    return;
  }
  if (mirror != _mirror) {
    [_mirror.rootLayer removeFromSuperlayer];
    _mirror = mirror;
    _mirror.showsPlaceholders = _placeholders.state == NSControlStateValueOn;
    [_canvas.fit addSublayer:mirror.rootLayer];
  }
  NSSize screen = mirror.rootLayer.bounds.size;
  if (!NSEqualSizes(screen, _canvas.screenSize)) { _canvas.screenSize = screen; [_canvas refit]; }
  _status.stringValue = [NSString stringWithFormat:@"%lu layers · %lu updates", (unsigned long)mirror.nodeCount, (unsigned long)mirror.batchCount];
}

- (void)togglePlaceholders:(NSButton *)b { _mirror.showsPlaceholders = b.state == NSControlStateValueOn; }

- (void)windowWillClose:(NSNotification *)n {
  [_session removeLayerObserver:_token];   // the last watcher stops the stream
  _token = nil;
  SRSession *s = _session;
  if (s) [gWindows removeObjectForKey:s];
  dispatch_async(dispatch_get_main_queue(), ^{ [gOpen removeObject:self]; });
}
@end
