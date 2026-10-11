# inspect — the layer tree, live

**Status: steps 1 and 2 of 5 work.** SimRun keeps a live copy of a running app's layer tree on the Mac, without
pausing the app. The copy is made of real Mac `CALayer`s with the app's geometry, colors, borders, corners, shadows,
masks, gradients and shapes, so the Mac's Core Animation draws it as the app's does. App ▸ Show Layers (⌥⌘I) shows the
copy next to the app's window; `simrun inspect` prints it as text.

What isn't copied yet is what layers *drew* (text, images, `drawRect:`): those layers get a blue stand-in. Layers the
Mac can't draw at all (blur and other backdrops, portals, Liquid Glass SDF layers, Metal, video) get an orange one.

The plan, toward a view debugger like Xcode's but live:

1. ✅ The data: the whole tree, then what changed after each commit.
2. ✅ The flat copy on the Mac, next to the real window (the best check that the data is right).
3. Explode it in 3D: each layer as a `CATransformLayer` node holding a "skin" layer and its children, spread out in
   depth, with a camera, picking, and clipping as a toggle (3D can't flatten, so clipping and group opacity are done
   by hand).
4. Contents: the backing stores' IOSurfaces shown without copying, images copied once.
5. The tree and inspector panels, editing, animations.

```bash
simrun inspect Showcase                 # the tree as text
simrun inspect Showcase --png copy.png  # and the copy as the Mac draws it
simrun inspect Showcase --watch         # then a line per update, until Ctrl-C
simrun inspect Showcase --check         # does the live copy match a fresh one from the app?
```

```
- Screen #1 (0,0 466x678)
  - UIWindowLayer #2 (UIWindow) (0,0 466x678) name="UIWindow (dev.simrun.showcase)"
    - CALayer #3 (UITransitionView) (0,0 466x678)
      …
                      - CALayer #15 (SwiftUI.HostingScrollView) (0,0 466x678) origin=(0,-168) clips
                        - CALayer #16 (_TtCC7SwiftUI17HostingScrollView22PlatformGroupContainer) (0,0 466x995.3)
                          - CALayer #21 (16,99.3 211x164.7) bg=#FFFFFFFF radius=22 continuous
                          - SwiftUI.GradientLayer #22 (30,113.3 40x40) radius=11.2 continuous gradient=3 colors
                          - _TtC7SwiftUIP33_863CCF9D…CGDrawingLayer #24 (30,173.3 94.7x20.3) contents=backingStore
```

Each line: the layer's class and node id, the view it belongs to, its frame in its superlayer (ignoring transforms),
and what isn't at its default: bounds origin (a scroll offset), hidden, alpha, transform, clips (`masksToBounds`),
background, border, corner radius, shadow, contents, gradient, path, filters. Masks are listed under their layer as
`mask:`.

## How it works

### In the app: which layers changed

script.dylib's `inspect.m` does the app's half. It starts on SimRun's `SR_MSG_INSPECT_START` (protocol.h), sent to the
script port with a port of SimRun's own, and sends `SR_MSG_INSPECT_BATCH` messages back to that port. A batch is a
binary property list.

**Which layers changed comes from Core Animation.** A commit calls `-[CALayer _copyRenderLayer:layerFlags:commitFlags:]`
on every layer whose state it sends to the render server, and on the layers above it. On the first START, inspect.m
swizzles that method to note the layer (`^v36@0:8^v16I24^I28` on iOS 27.1; it checks for no floating-point or struct
arguments before swizzling). After the commit, on the main thread, the noted layers are compared with what was last
sent. If the method isn't there, the whole tree is compared four times a second instead.

**What changed is worked out in the app**, by reading the properties a Mac `CALayer` can show and comparing them with
what was last sent. Core Animation's own flags (`commitFlags` comes back with bits such as `0x2020a018`) say what kind
of change it sends, but they are private and may mean something else on another runtime.

Measured on Showcase (iOS 27.1): the whole tree (82 layers) in 4 ms; a push to another page, 226 noted layers and 133
changed nodes in 4–7 ms; a tap or a scroll step, 0.1–1 ms. Nothing is noted while no one is watching, and the method
isn't swizzled until someone first does.

### A batch

```
{ full: YES (replaces everything; the first batch),
  nodes: [ { id: 21, bounds: [16, 99.3, 211, 164.7], backgroundColor: [1, 1, 1, 1], cornerRadius: 22, … },
           { id: 7, sublayers: [8, 9, 10] },
           { id: 30, opacity: 0.5, unset: ["hidden"] } ] }
```

- Node 1 is the screen: its bounds, scale, and as sublayers the windows' layers, back to front (the active scene's
  windows by window level). A node's id stays the layer's for as long as the layer lives.
- A node is sent whole the first time; after that, only the properties that changed, and `unset` for those back at
  their default. A property at its default is left out.
- Sublayers and masks are node ids. Colors are `[r, g, b, a]` in extended sRGB; colors whose default is opaque black
  (border, shadow, a shape's fill) are always sent, `[]` for none. Paths are `[element type, coordinates…]` arrays.
- `kind` says what the Mac can make of the layer: `layer`, `gradient`, `shape`, `transform`, `text`, or one it can only
  stand in for (`backdrop`, `portal`, `host`, `sdf`, `metal`, `video`, `emitter`, `replicator`).
- `contents` is `image` (a CGImage, with `contentsSize` in pixels), `backingStore` (what the layer drew:
  `CABackingStore`, a CF type), or another class (`CATintedImage`, an SF Symbol's image).

### Keeping the two sides in step

The Mac side drops every node the screen can no longer reach through sublayers and masks, after each batch. The app
side must forget exactly the same nodes, so that a layer that comes back later is sent whole again. Getting this
wrong shows up as `(missing #12)` in the tree.

The rule that works: after any batch in which a sublayer or mask went away, the app computes what node 1 can reach in
**the tree as it was sent**, not in its own current tree. They differ when a layer leaves together with its
superlayer. For example, UIKit removes the previous page's view from its wrapper view in the same commit that removes
the wrapper. The wrapper is no longer reachable, so it isn't compared, and its sent record still lists the page's
view. The Mac drops both. On the way back, the page's view is re-attached, and the app must know to send it whole.

Layers that aren't in the tree when noted (not attached yet, or in a window SimRun doesn't show) aren't sent. They
are sent once they are attached, as part of their new superlayer's change.

If SimRun ever falls behind (its port's queue is full), the app drops that batch and sends the whole tree again 100 ms
later: sends never wait on the app's main thread.

`simrun inspect --check` tests all of this: it asks the app for its whole tree again and compares it with the live
copy. Both regression scripts (`tests/scripts`), run twice under a live copy, plus visits to other Showcase pages
(about 2,000 updates), end with the copies matching.

### On the Mac: the copy

`SRLayerMirror` (layermirror.m) keeps one node per app layer: the properties last received, and a `CALayer` of the
right class (`CAGradientLayer`, `CAShapeLayer`, `CATransformLayer`, `CATextLayer`, else `CALayer`). After a batch it
puts each changed node's properties on its layer (defaults for those left out), then sets sublayers and masks, then
drops what the screen can't reach. All of this happens in one `CATransaction` with actions disabled.

- **Orientation.** The screen layer is `geometryFlipped`, so everything under it is y-down as on iOS. Gradient points,
  paths and shadow offsets need no conversion.
- **Stand-ins.** These are an extra first sublayer of the layer, so they draw where its contents would (above its
  background, under its sublayers).
- **Sharing.** The copy belongs to the app's session (session.m) and is shared by everyone watching it: the layer
  window and `simrun inspect` clients. The first watcher starts the stream, and the last one stops it: destroying the
  port reaches the app as a dead-name notification.
- **`--png`** draws the copy with `-[CALayer renderInContext:]` at 2x.

## Findings

- **Commits include the path to each change.** `_copyRenderLayer:` is called for each changed layer and for the
  layers above it. Those ancestors come with `layerFlags` `0x4811` or `0x4011` and `commitFlags` `0x20200000`. They
  usually show no property change, so they cost a comparison but send nothing.
- **Animations don't commit.** They run in the render server, so the copy shows the model values (where a layer is
  going), as an Elements panel should.
- **SwiftUI's layers.** Text and SF Symbols are mostly `CGDrawingLayer`s with a backing store. Some symbols are
  `ColorShapeLayer` (a `CAShapeLayer`), which the Mac draws for real. Gradients are `SwiftUI.GradientLayer` (a
  `CAGradientLayer`).
- **Liquid Glass.** It is `CASDFLayer`, `CABackdropLayer` and `CAPortalLayer`, plus filters such as `displacementMap`
  and `opacityPair`, all of which only the simulator's render server can draw.
- **First action after launch.** With the default 5 s timeout, the first scripted action in an app could run out of
  time while UIKit's accessibility loaded (4–5 s). The timeout then fired during the stability check, so the error
  said "keeps moving". `internal.poll` now does that one-time load before its clock starts (scripting.md).

## Next steps

- Step 3, the 3D view. Picking needs our own ray-quad intersection, since `hitTest:` doesn't handle 3D transforms.
- Step 4, contents. Getting a backing store's IOSurface, and whether Core Animation can draw into a surface we're
  still showing, are questions for IDA.
- Demangling SwiftUI class names in the tree.
- Filters: names only for now. The Mac's `CIFilter`s could stand in for blur.
- Steps 1 and 2 were tested on iOS 27.1 only.
