// layertree.h — the layer window's tree: the app's views (or all its layers) as an outline, live, with a filter field at
// the bottom (and the views/all layers toggle at its end), as in Xcode's navigators. Made to sit in a sidebar.
// Rows are node ids (layermirror.h), so expansion and selection survive the tree being reloaded as the app changes.
#pragma once
#import <Cocoa/Cocoa.h>

@class SRLayerMirror;

@interface SRLayerTree : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate>
@property (readonly) NSView *view;                  // the outline over the filter field
@property (nonatomic, strong) SRLayerMirror *mirror;
@property (nonatomic) BOOL showsAllLayers;          // NO: only layers that belong to a view (and windows), as Xcode;
                                                    // the toggle at the filter's end flips it
@property (copy) void (^onSelect)(NSNumber *nid);   // the user picked a row (nil: none)
// After a batch (SRLayerMirror -applyBatch:'s result): reloads, at most ~8 times a second, when the tree's shape changed.
- (void)mirrorChanged:(NSDictionary *)changes;
// Selects the row of `nid` (or, if it has none, of the nearest node above it that has), expanding down to it; returns
// the node selected. Doesn't call onSelect.
- (NSNumber *)selectNode:(NSNumber *)nid;
@end
