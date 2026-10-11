// layerinspector.m — see layerinspector.h. One read-only text view, rebuilt when the selection or the selected layer
// changes: label and value columns by tab stops, colors as swatches, the contents as their picture.
#import "layerinspector.h"
#import "layermirror.h"

@implementation SRLayerInspector {
  NSView *_view;
  NSTextView *_text;
}

- (instancetype)init {
  if (!(self = [super init])) return nil;
  NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 500)];
  sv.hasVerticalScroller = YES; sv.autohidesScrollers = YES; sv.drawsBackground = NO;
  _text = [[NSTextView alloc] initWithFrame:sv.bounds];
  _text.editable = NO; _text.selectable = YES; _text.drawsBackground = NO;
  _text.textContainerInset = NSMakeSize(10, 10);
  _text.autoresizingMask = NSViewWidthSizable;
  sv.documentView = _text;
  _view = sv;
  return self;
}
- (NSView *)view { return _view; }

static NSString *Fmt(id v) {
  double d = [v doubleValue];
  return [NSString stringWithFormat:@"%g", round(d * 100) / 100];
}
static NSString *PointText(NSArray *a) { return a.count == 2 ? [NSString stringWithFormat:@"(%@, %@)", Fmt(a[0]), Fmt(a[1])] : @"—"; }
static NSString *RectText(CGRect r) {
  return [NSString stringWithFormat:@"(%@, %@)  %@ × %@", Fmt(@(r.origin.x)), Fmt(@(r.origin.y)), Fmt(@(r.size.width)), Fmt(@(r.size.height))];
}

- (void)showNode:(NSNumber *)nid of:(SRLayerMirror *)mirror {
  NSMutableAttributedString *out = [NSMutableAttributedString new];
  NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
  para.tabStops = @[ [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:96 options:@{}],
                     [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:104 options:@{}] ];
  para.headIndent = 104; para.paragraphSpacing = 2;
  NSFont *small = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  NSDictionary *label = @{ NSFontAttributeName: small, NSForegroundColorAttributeName: NSColor.secondaryLabelColor, NSParagraphStyleAttributeName: para };
  NSDictionary *value = @{ NSFontAttributeName: small, NSForegroundColorAttributeName: NSColor.labelColor, NSParagraphStyleAttributeName: para };
  void (^section)(NSString *) = ^(NSString *title) {
    if (out.length) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:[title stringByAppendingString:@"\n"] attributes:@{
      NSFontAttributeName: [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize], NSForegroundColorAttributeName: NSColor.secondaryLabelColor }]];
  };
  void (^row)(NSString *, id) = ^(NSString *name, id v) {
    if (!v) return;
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\t%@\t", name] attributes:label]];
    if ([v isKindOfClass:NSAttributedString.class]) [out appendAttributedString:v];
    else [out appendAttributedString:[[NSAttributedString alloc] initWithString:[v description] attributes:value]];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:value]];
  };
  // a color: a swatch in it, then its hex
  NSAttributedString *(^color)(id) = ^NSAttributedString *(id c) {
    NSArray *a = c;
    if (![a isKindOfClass:NSArray.class] || a.count != 4) return [[NSAttributedString alloc] initWithString:@"none" attributes:value];
    NSColor *ns = [NSColor colorWithSRGBRed:[a[0] doubleValue] green:[a[1] doubleValue] blue:[a[2] doubleValue] alpha:[a[3] doubleValue]];
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:@"■ " attributes:@{ NSFontAttributeName: small, NSForegroundColorAttributeName: ns }];
    NSMutableString *hex = [NSMutableString stringWithString:@"#"];
    for (NSNumber *v in a) [hex appendFormat:@"%02X", (int)lround(MAX(0, MIN(1, v.doubleValue)) * 255)];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:hex attributes:value]];
    return s;
  };

  SRMirrorNode *n = nid ? mirror.nodes[nid] : nil;
  if (!n) {
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"Click a layer, in the tree or in the view." attributes:@{
      NSFontAttributeName: small, NSForegroundColorAttributeName: NSColor.tertiaryLabelColor }]];
    [_text.textStorage setAttributedString:out];
    return;
  }
  NSDictionary *p = n.props;

  section(@"Object");
  row(@"Class", SRReadableClassName(p[@"class"]));
  if ([p[@"class"] hasPrefix:@"_Tt"]) row(@"Runtime name", p[@"class"]);
  row(@"View", p[@"view"] ? SRReadableClassName(p[@"view"]) : nil);
  row(@"Node", [NSString stringWithFormat:@"#%@", nid]);
  row(@"Name", SRReadableText(p[@"name"]));

  section(@"Layout");
  NSArray *b = p[@"bounds"]; CGRect bounds = b.count == 4 ? CGRectMake([b[0] doubleValue], [b[1] doubleValue], [b[2] doubleValue], [b[3] doubleValue]) : CGRectZero;
  NSArray *pos = p[@"position"], *ap = p[@"anchorPoint"] ?: @[ @0.5, @0.5 ];
  if (pos.count == 2)
    row(@"Frame", RectText(CGRectMake([pos[0] doubleValue] - [ap[0] doubleValue] * bounds.size.width, [pos[1] doubleValue] - [ap[1] doubleValue] * bounds.size.height,
                                      bounds.size.width, bounds.size.height)));
  CGRect onScreen = [mirror screenRectOfNode:nid];
  if (!CGRectIsNull(onScreen)) row(@"On screen", RectText(onScreen));
  if (bounds.origin.x || bounds.origin.y) row(@"Bounds origin", PointText(@[ @(bounds.origin.x), @(bounds.origin.y) ]));
  row(@"Position", PointText(pos));
  if (p[@"anchorPoint"]) row(@"Anchor point", PointText(ap));
  if (p[@"zPosition"]) row(@"z position", Fmt(p[@"zPosition"]));
  for (NSString *k in @[ @"transform", @"sublayerTransform" ]) {
    NSArray *m = p[k];
    if (m.count != 16) continue;
    NSMutableArray *rows = [NSMutableArray array];
    for (int r = 0; r < 4; r++) [rows addObject:[NSString stringWithFormat:@"%@ %@ %@ %@", Fmt(m[r * 4]), Fmt(m[r * 4 + 1]), Fmt(m[r * 4 + 2]), Fmt(m[r * 4 + 3])]];
    row([k isEqual:@"transform"] ? @"Transform" : @"Sublayer transform", [rows componentsJoinedByString:@"\n"]);
  }

  section(@"Appearance");
  row(@"Hidden", [p[@"hidden"] boolValue] ? @"yes" : @"no");
  row(@"Opacity", p[@"opacity"] ? Fmt(p[@"opacity"]) : @"1");
  row(@"Clips", [p[@"masksToBounds"] boolValue] ? @"yes (masksToBounds)" : @"no");
  row(@"Background", color(p[@"backgroundColor"]));
  if (p[@"borderWidth"]) {
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:[Fmt(p[@"borderWidth"]) stringByAppendingString:@" pt  "] attributes:value];
    [s appendAttributedString:color(p[@"borderColor"])];
    row(@"Border", s);
  }
  if (p[@"cornerRadius"]) row(@"Corner radius", [NSString stringWithFormat:@"%@%@", Fmt(p[@"cornerRadius"]), [p[@"cornerCurve"] isEqual:@"continuous"] ? @", continuous" : @""]);
  if (p[@"maskedCorners"]) row(@"Masked corners", p[@"maskedCorners"]);
  if (p[@"shadowOpacity"]) {
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"opacity %@, radius %@, offset %@  ",
                                    Fmt(p[@"shadowOpacity"]), Fmt(p[@"shadowRadius"]), PointText(p[@"shadowOffset"])] attributes:value];
    [s appendAttributedString:color(p[@"shadowColor"])];
    row(@"Shadow", s);
  }
  if (p[@"mask"]) row(@"Mask", [NSString stringWithFormat:@"#%@", p[@"mask"]]);
  if ([p[@"colors"] count]) {
    NSMutableAttributedString *s = [NSMutableAttributedString new];
    for (id c in p[@"colors"]) { [s appendAttributedString:color(c)]; [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:value]]; }
    row(@"Gradient", s);
    row(@"From / to", [NSString stringWithFormat:@"%@ → %@", PointText(p[@"startPoint"]), PointText(p[@"endPoint"])]);
  }
  if (p[@"path"]) {
    row(@"Path", [NSString stringWithFormat:@"%lu elements", (unsigned long)[p[@"path"] count]]);
    row(@"Fill", color(p[@"fillColor"] ?: @[ @0, @0, @0, @1 ]));
    if (p[@"strokeColor"]) row(@"Stroke", color(p[@"strokeColor"]));
  }

  if (p[@"contents"]) {
    section(@"Contents");
    row(@"Kind", p[@"contents"]);
    CGImageRef img = [mirror imageNamed:p[@"contentsImage"]];
    if (img) row(@"Picture", [NSString stringWithFormat:@"%zu × %zu px", CGImageGetWidth(img), CGImageGetHeight(img)]);
    else if (p[@"contentsImage"]) row(@"Picture", @"missing");
    row(@"Scale", p[@"contentsScale"] ? Fmt(p[@"contentsScale"]) : nil);
    row(@"Gravity", p[@"contentsGravity"]);
    if (img) {   // the picture itself, up to 220 points wide, on a checkerboard-free plain background
      CGFloat scale = MAX(1, [p[@"contentsScale"] doubleValue]);
      NSSize size = NSMakeSize(CGImageGetWidth(img) / scale, CGImageGetHeight(img) / scale);
      if (size.width > 220) size = NSMakeSize(220, size.height * 220 / size.width);
      NSTextAttachment *att = [NSTextAttachment new];
      att.image = [[NSImage alloc] initWithCGImage:img size:size];
      NSMutableAttributedString *pic = [[NSAttributedString attributedStringWithAttachment:att] mutableCopy];
      [pic addAttributes:@{ NSParagraphStyleAttributeName: para } range:NSMakeRange(0, pic.length)];
      [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\t\t" attributes:value]];
      [out appendAttributedString:pic];
      [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:value]];
    }
  }

  NSDictionary *extras = [mirror extrasOfNode:nid];
  if (extras.count || p[@"filters"] || p[@"backgroundFilters"] || p[@"compositingFilter"]) {
    section(@"Filters and special properties");
    NSString *(^describe)(id) = ^NSString *(id f) {
      NSString *d = [f description];
      NSRange semi = [d rangeOfString:@"; "];   // "<CAFilter: 0x…; name = …>": drop the address
      return semi.location != NSNotFound && [d hasPrefix:@"<"] ? [@"<" stringByAppendingString:[d substringFromIndex:NSMaxRange(semi)]] : d;
    };
    for (NSString *k in @[ @"filters", @"backgroundFilters" ]) {
      NSArray *fs = extras[k];
      if (!fs.count) { if (p[k]) row(k, [p[k] componentsJoinedByString:@", "]); continue; }
      NSMutableArray *lines = [NSMutableArray array];
      for (id f in fs) [lines addObject:describe(f)];
      row(k, [lines componentsJoinedByString:@"\n"]);
    }
    if (extras[@"compositingFilter"] || p[@"compositingFilter"]) row(@"compositingFilter", extras[@"compositingFilter"] ? describe(extras[@"compositingFilter"]) : p[@"compositingFilter"]);
    for (NSString *k in [extras.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if ([@[ @"filters", @"backgroundFilters", @"compositingFilter" ] containsObject:k]) continue;
      id v = extras[k];
      if ([v isKindOfClass:NSDictionary.class] && v[@"$type"]) v = [NSString stringWithFormat:@"(%@, %lu bytes)", v[@"$type"], (unsigned long)[v[@"$bytes"] length]];
      row(k, describe(v));
    }
    if (p[@"portalSource"]) row(@"Portal source", [NSString stringWithFormat:@"#%@", p[@"portalSource"]]);
  }
  [_text.textStorage setAttributedString:out];
}
@end
