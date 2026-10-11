// layerwindow.h — App ▸ Show Layers: the app's screen redrawn on the Mac from a live copy of its layer tree
// (layermirror.h), next to the app's own window, to compare. One window per running app.
#pragma once
#import <Cocoa/Cocoa.h>

@class SRSession;

@interface SRLayerWindow : NSWindowController <NSWindowDelegate>
// Shows (creating if need be) the layer window of `session`; beeps if the app can't be inspected.
+ (void)showForSession:(SRSession *)session;
@end
