// mirrorwindow.h — an iPhone Mirroring–style window: by default only the device screen is visible (device-shaped
// rounded corners, shadow, no title bar); hovering near the top grows a window frame with the traffic lights around
// it — the screen itself never moves — and moving the mouse away shrinks it back.
#pragma once
#import <Cocoa/Cocoa.h>

@interface SRMirrorWindow : NSWindow
// `screenView` shows the device screen; `cornerRadius` is the device's screen corner radius in points.
- (instancetype)initWithScreenView:(NSView *)screenView size:(NSSize)size cornerRadius:(CGFloat)cornerRadius;
@property (nonatomic) NSSize screenSize;               // device screen size in points (keeps the screen's top-left)
@property (readonly) NSRect screenFrame;               // device screen in screen coordinates
- (void)setScreenTopLeft:(NSPoint)topLeft;             // positions the (collapsed) window
@property (nonatomic, readonly, getter=isExpanded) BOOL expanded;
@end

// The device screen corner radius from a device type's capabilities.plist (DeviceCornerRadius); 55 if unknown.
CGFloat SRDeviceCornerRadius(NSString *capabilitiesPath);
