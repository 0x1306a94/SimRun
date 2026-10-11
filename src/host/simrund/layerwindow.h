// layerwindow.h — App ▸ Show Layers: a live view debugger, next to the app's own window. The tree of its views or layers
// (a sidebar), its screen redrawn on the Mac from a live copy of its layer tree (layermirror.h), flat or in 3D, and an
// inspector for the selected layer. One window per running app.
#pragma once
#import <Cocoa/Cocoa.h>

@class SRSession;

@interface SRLayerWindow : NSWindowController <NSWindowDelegate, NSToolbarDelegate>
// Shows (creating if need be) the layer window of `session`; beeps if the app can't be inspected.
+ (void)showForSession:(SRSession *)session;
@end
