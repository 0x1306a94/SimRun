// launchsheet.m — see launchsheet.h.
#import "launchsheet.h"
#import "launchoptions.h"
#import "environment.h"

// SimRun variables the Options and Diagnostics tabs switch: { variable, checkbox title, checked = variable unset }.
static NSArray<NSArray *> *ServiceSwitches(void) {
  return @[ @[ @"PBOARD_DISABLE", @"Pasteboard shared with the Mac", @YES ], @[ @"DRAG_DISABLE", @"Drag and drop", @YES ],
            @[ @"KEYCHAIN_DISABLE", @"SimRun keychain", @YES ], @[ @"WEBKIT_DISABLE", @"Web view helper processes", @YES ] ];
}
static NSArray<NSArray *> *TracingSwitches(void) {
  return @[ @[ @"HID_VERBOSE", @"Touch and keyboard", @NO ], @[ @"SCENES_VERBOSE", @"Scenes", @NO ],
            @[ @"SIMFB_VERBOSE", @"Rendering", @NO ], @[ @"PBOARD_VERBOSE", @"Pasteboard", @NO ],
            @[ @"DRAG_VERBOSE", @"Drag and drop", @NO ], @[ @"KEYCHAIN_VERBOSE", @"Keychain", @NO ],
            @[ @"WEBKIT_VERBOSE", @"Web views", @NO ], @[ @"RSHIM_VERBOSE", @"Runtime shims", @NO ] ];
}

static const CGFloat kLabelWidth = 170, kFieldWidth = 360;

// A tab of the sheet's tab bar: a borderless button on a pill tinted while selected, as in Xcode's scheme editor.
@interface SRTabPill : NSView
@property (nonatomic) BOOL selected;
@property NSButton *button;
@end
@implementation SRTabPill
- (void)setSelected:(BOOL)selected {
  _selected = selected;
  _button.contentTintColor = selected ? NSColor.controlAccentColor : NSColor.labelColor;
  self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)r {
  if (!_selected) return;
  [[NSColor.controlAccentColor colorWithAlphaComponent:0.15] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
}
@end

static NSTextField *Label(NSString *s) { return [NSTextField labelWithString:s]; }
static NSTextField *Note(NSString *s) {
  NSTextField *f = [NSTextField wrappingLabelWithString:s];
  f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize]; f.textColor = NSColor.secondaryLabelColor;
  f.preferredMaxLayoutWidth = kFieldWidth;
  return f;
}
static NSTextField *Value(NSString *s) {
  NSTextField *f = [NSTextField labelWithString:s ?: @""];
  f.selectable = YES; f.lineBreakMode = NSLineBreakByTruncatingMiddle; f.toolTip = s;
  [f setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  return f;
}
// A form: right-aligned labels, controls to their right; extra columns (`columns` > 2) split the control area.
static NSGridView *Form(NSArray<NSArray<NSView *> *> *rows, NSInteger columns) {
  NSGridView *g = [NSGridView gridViewWithViews:rows];
  g.translatesAutoresizingMaskIntoConstraints = NO;
  g.rowSpacing = 10; g.columnSpacing = 12; g.rowAlignment = NSGridRowAlignmentFirstBaseline;
  [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing; [g columnAtIndex:0].width = kLabelWidth;
  for (NSInteger c = 1; c < columns; c++) [g columnAtIndex:c].width = (kFieldWidth - (columns - 2) * g.columnSpacing) / (columns - 1);
  return g;
}

@interface SRLaunchSheet () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SRLaunchSheet {
  SRAppInfo *_app; SRLaunchOptions *_options; BOOL _running; void (^_launch)(void);
  NSWindow *_sheet, *_parent;
  NSArray<SRTabPill *> *_tabs; NSArray<NSView *> *_pages;
  NSPopUpButton *_runtime, *_device, *_locale;
  NSMutableArray<NSButton *> *_switchBoxes;
  NSTableView *_argsTable, *_envTable;
}

static NSMutableSet<SRLaunchSheet *> *gShown;   // a sheet keeps itself alive until it is dismissed

+ (void)beginForApp:(SRAppInfo *)app running:(BOOL)running window:(NSWindow *)window launch:(void (^)(void))launch {
  if (!window || window.attachedSheet) return;
  SRLaunchSheet *s = [SRLaunchSheet new];
  s->_app = app; s->_running = running; s->_launch = [launch copy]; s->_parent = window;
  s->_options = [SRLaunchOptions optionsForAppAtPath:app.path];
  [SREnvironment reloadInstalledRuntimes];
  s->_switchBoxes = [NSMutableArray array];
  [s build]; [s refresh];
  if (!gShown) gShown = [NSMutableSet set];
  [gShown addObject:s];
  [window beginSheet:s->_sheet completionHandler:^(NSModalResponse r) { [gShown removeObject:s]; }];
}

// ---------------------------------------------------------------- layout
- (void)build {
  _sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
  NSView *root = _sheet.contentView;

  NSImageView *icon = [NSImageView imageViewWithImage:_app.icon];
  NSTextField *title = Label(_app.name); title.font = [NSFont systemFontOfSize:15];
  NSStackView *header = [NSStackView stackViewWithViews:@[ icon, title ]]; header.spacing = 8;

  NSMutableArray *tabs = [NSMutableArray array];
  NSArray *names = @[ @"Info", @"Arguments", @"Options", @"Diagnostics" ];
  for (NSUInteger i = 0; i < names.count; i++) {
    SRTabPill *p = [SRTabPill new]; p.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *b = [NSButton buttonWithTitle:names[i] target:self action:@selector(selectTab:)];
    b.bordered = NO; b.tag = (NSInteger)i; b.font = [NSFont systemFontOfSize:13]; b.translatesAutoresizingMaskIntoConstraints = NO;
    [p addSubview:b]; p.button = b;
    [NSLayoutConstraint activateConstraints:@[
      [b.centerXAnchor constraintEqualToAnchor:p.centerXAnchor], [b.centerYAnchor constraintEqualToAnchor:p.centerYAnchor],
      [p.widthAnchor constraintEqualToAnchor:b.widthAnchor constant:18], [p.heightAnchor constraintEqualToConstant:26],
    ]];
    [tabs addObject:p];
  }
  _tabs = tabs;
  NSStackView *tabBar = [NSStackView stackViewWithViews:tabs]; tabBar.spacing = 12;

  _pages = @[ [self infoPage], [self argumentsPage], [self optionsPage], [self diagnosticsPage] ];
  NSView *pageArea = [NSView new];
  for (NSView *p in _pages) {
    p.translatesAutoresizingMaskIntoConstraints = NO; [pageArea addSubview:p];
    [NSLayoutConstraint activateConstraints:@[
      [p.topAnchor constraintEqualToAnchor:pageArea.topAnchor], [p.leadingAnchor constraintEqualToAnchor:pageArea.leadingAnchor],
      [p.trailingAnchor constraintEqualToAnchor:pageArea.trailingAnchor], [p.bottomAnchor constraintEqualToAnchor:pageArea.bottomAnchor],
    ]];
  }

  NSButton *restore = [NSButton buttonWithTitle:@"Restore Defaults" target:self action:@selector(restoreDefaults:)];
  NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
  cancel.keyEquivalent = @"\033";
  NSButton *launch = [NSButton buttonWithTitle:_running ? @"Relaunch" : @"Launch" target:self action:@selector(launch:)];
  launch.keyEquivalent = @"\r";
  NSBox *sep[3];
  for (int i = 0; i < 3; i++) { sep[i] = [NSBox new]; sep[i].boxType = NSBoxSeparator; }

  for (NSView *v in @[ header, tabBar, pageArea, restore, cancel, launch, sep[0], sep[1], sep[2] ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:v];
  }
  NSMutableArray *c = [NSMutableArray arrayWithArray:@[
    [root.widthAnchor constraintEqualToConstant:640],
    [icon.widthAnchor constraintEqualToConstant:24], [icon.heightAnchor constraintEqualToConstant:24],
    [header.topAnchor constraintEqualToAnchor:root.topAnchor constant:16], [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
    [sep[0].topAnchor constraintEqualToAnchor:header.bottomAnchor constant:14],
    [tabBar.topAnchor constraintEqualToAnchor:sep[0].bottomAnchor constant:8], [tabBar.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
    [sep[1].topAnchor constraintEqualToAnchor:tabBar.bottomAnchor constant:8],
    [pageArea.topAnchor constraintEqualToAnchor:sep[1].bottomAnchor constant:20],
    [pageArea.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [pageArea.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
    [pageArea.heightAnchor constraintEqualToConstant:300],
    [sep[2].topAnchor constraintEqualToAnchor:pageArea.bottomAnchor constant:12],
    [restore.topAnchor constraintEqualToAnchor:sep[2].bottomAnchor constant:14], [restore.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
    [root.bottomAnchor constraintEqualToAnchor:restore.bottomAnchor constant:16],
    [launch.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20], [launch.centerYAnchor constraintEqualToAnchor:restore.centerYAnchor],
    [cancel.trailingAnchor constraintEqualToAnchor:launch.leadingAnchor constant:-10], [cancel.centerYAnchor constraintEqualToAnchor:restore.centerYAnchor],
    [launch.widthAnchor constraintGreaterThanOrEqualToConstant:84], [cancel.widthAnchor constraintEqualToAnchor:launch.widthAnchor],
  ]];
  for (int i = 0; i < 3; i++)
    [c addObjectsFromArray:@[ [sep[i].leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [sep[i].trailingAnchor constraintEqualToAnchor:root.trailingAnchor] ]];
  [NSLayoutConstraint activateConstraints:c];
  [self selectTab:_tabs[0].button];
}

// A page holding `content` centered horizontally at its top.
static NSView *Page(NSView *content) {
  NSView *page = [NSView new];
  content.translatesAutoresizingMaskIntoConstraints = NO; [page addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.topAnchor constraintEqualToAnchor:page.topAnchor], [content.centerXAnchor constraintEqualToAnchor:page.centerXAnchor],
  ]];
  return page;
}

- (NSButton *)switchBox:(NSArray *)sw {
  NSButton *b = [NSButton checkboxWithTitle:sw[1] target:self action:@selector(switchToggled:)];
  b.identifier = sw[0]; b.tag = [sw[2] boolValue];
  [_switchBoxes addObject:b];
  return b;
}

- (NSView *)infoPage {
  _runtime = [NSPopUpButton new]; _runtime.target = self; _runtime.action = @selector(runtimeChanged:);
  NSTextField *note = Note(@"SimRun's own runtime is chosen in SimRun ▸ iOS Runtime. An app on another runtime gets that "
                            "runtime's system services; its data container stays the same.");
  _device = [NSPopUpButton new]; _device.target = self; _device.action = @selector(deviceChanged:);
  NSTextField *deviceNote = Note(@"The device types the runtime supports. The app gets that model's screen, safe areas and "
                                  "hardware features (Dynamic Island, home button, ...).");
  NSString *dir = _app.path.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
  NSGridView *g = Form(@[
    @[ Label(@"Runtime"), _runtime ], @[ NSGridCell.emptyContentView, note ],
    @[ Label(@"Device"), _device ], @[ NSGridCell.emptyContentView, deviceNote ],
    @[ Label(@"Executable"), Value(_app.path.lastPathComponent) ],
    @[ Label(@"Bundle Identifier"), Value(_app.bundleIdentifier.length ? _app.bundleIdentifier : @"—") ],
    @[ Label(@"Location"), Value(dir) ],
  ], 2);
  [g rowAtIndex:1].topPadding = [g rowAtIndex:3].topPadding = -4;
  [g rowAtIndex:2].topPadding = [g rowAtIndex:4].topPadding = 12;
  [_runtime.widthAnchor constraintEqualToConstant:kFieldWidth].active = YES;
  [_device.widthAnchor constraintEqualToConstant:kFieldWidth].active = YES;
  return Page(g);
}

- (NSView *)optionsPage {
  _locale = [NSPopUpButton new]; _locale.target = self; _locale.action = @selector(localeChanged:);
  [_locale addItemsWithTitles:@[ @"Same as the Mac", @"Keep the Device's Settings" ]];
  [_locale.widthAnchor constraintEqualToConstant:kFieldWidth].active = YES;
  NSMutableArray *rows = [NSMutableArray arrayWithArray:@[
    @[ Label(@"Language & Region"), _locale ],
    @[ NSGridCell.emptyContentView, Note(@"Keep the device's settings to test a language or region other than the Mac's.") ],
  ]];
  NSArray *services = ServiceSwitches();
  for (NSUInteger i = 0; i < services.count; i++)
    [rows addObject:@[ i ? NSGridCell.emptyContentView : Label(@"Services"), [self switchBox:services[i]] ]];
  [rows addObject:@[ NSGridCell.emptyContentView, Note(@"Turn a service off to see how the app behaves without what SimRun provides.") ]];
  NSGridView *g = Form(rows, 2);
  [g rowAtIndex:1].topPadding = -4;
  [g rowAtIndex:2].topPadding = 12;
  [g rowAtIndex:rows.count - 1].topPadding = -2;
  return Page(g);
}

- (NSView *)diagnosticsPage {
  NSArray *tracing = TracingSwitches();
  NSMutableArray *rows = [NSMutableArray arrayWithObject:
      @[ Label(@"Logging"), [self switchBox:@[ @"OS_ACTIVITY_DT_MODE", @"Mirror os_log and NSLog to the app's log", @NO ]], NSGridCell.emptyContentView ]];
  for (NSUInteger i = 0; i < tracing.count; i += 2)
    [rows addObject:@[ i ? NSGridCell.emptyContentView : Label(@"Tracing"), [self switchBox:tracing[i]], [self switchBox:tracing[i + 1]] ]];
  [rows addObject:@[ Label(@"Frames"), [self switchBox:@[ @"SIMFB_CHECK", @"Check presented frames for stale pixels", @NO ]], NSGridCell.emptyContentView ]];
  [rows addObject:@[ NSGridCell.emptyContentView, Note(@"Output goes to the app's log (App ▸ Show Log)."), NSGridCell.emptyContentView ]];
  NSGridView *g = Form(rows, 3);
  for (NSNumber *r in @[ @0, @(rows.count - 2), @(rows.count - 1) ])   // logging, frames, note: across both columns
    [g mergeCellsInHorizontalRange:NSMakeRange(1, 2) verticalRange:NSMakeRange(r.unsignedIntegerValue, 1)];
  [g rowAtIndex:1].topPadding = [g rowAtIndex:rows.count - 2].topPadding = 12;
  return Page(g);
}

// ---------------------------------------------------------------- Arguments tab: two editable lists
- (NSView *)argumentsPage {
  NSStackView *s = [NSStackView stackViewWithViews:@[
    [self listTitled:@"Arguments Passed On Launch" columns:@[ @"value" ] table:&_argsTable],
    [self listTitled:@"Environment Variables" columns:@[ @"name", @"value" ] table:&_envTable],
  ]];
  s.orientation = NSUserInterfaceLayoutOrientationVertical; s.spacing = 16;
  return Page(s);
}

- (NSView *)listTitled:(NSString *)title columns:(NSArray<NSString *> *)columns table:(NSTableView * __strong *)out {
  NSTextField *label = Label(title); label.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
  NSTableView *t = [NSTableView new];
  NSTableColumn *on = [[NSTableColumn alloc] initWithIdentifier:@"on"]; on.width = 22; on.minWidth = on.maxWidth = 22; on.title = @"";
  [t addTableColumn:on];
  for (NSString *ident in columns) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title = [ident isEqualToString:@"name"] ? @"Name" : @"Value"; col.width = 200; col.resizingMask = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
    [t addTableColumn:col];
  }
  if (columns.count == 1) t.headerView = nil;
  t.style = NSTableViewStyleFullWidth; t.usesAlternatingRowBackgroundColors = YES; t.rowHeight = 22;
  t.allowsMultipleSelection = YES; t.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  t.dataSource = self; t.delegate = self;
  NSScrollView *sv = [NSScrollView new];
  sv.documentView = t; sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
  NSSegmentedControl *pm = [NSSegmentedControl segmentedControlWithImages:@[ [NSImage imageNamed:NSImageNameAddTemplate], [NSImage imageNamed:NSImageNameRemoveTemplate] ]
                                                             trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(addOrRemove:)];
  pm.segmentStyle = NSSegmentStyleSmallSquare; pm.tag = columns.count;   // 1: arguments, 2: environment
  NSStackView *s = [NSStackView stackViewWithViews:@[ label, sv, pm ]];
  s.orientation = NSUserInterfaceLayoutOrientationVertical; s.alignment = NSLayoutAttributeLeading; s.spacing = 6;
  [s setCustomSpacing:0 afterView:sv];
  [NSLayoutConstraint activateConstraints:@[
    [sv.widthAnchor constraintEqualToConstant:kLabelWidth + 12 + kFieldWidth], [sv.heightAnchor constraintEqualToConstant:88],
  ]];
  [t sizeLastColumnToFit];
  *out = t;
  return s;
}

- (NSMutableArray<SRLaunchItem *> *)itemsOf:(NSTableView *)t { return t == _argsTable ? _options.arguments : _options.environment; }
- (NSTableView *)tableOf:(NSView *)v { return [v isDescendantOf:_argsTable] ? _argsTable : _envTable; }

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return [self itemsOf:t].count; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  SRLaunchItem *it = [self itemsOf:t][row];
  NSString *ident = col.identifier;
  NSTableCellView *cv = [t makeViewWithIdentifier:ident owner:self];
  if (!cv) {
    cv = [NSTableCellView new]; cv.identifier = ident;
    NSControl *ctl;
    if ([ident isEqualToString:@"on"]) ctl = [NSButton checkboxWithTitle:@"" target:self action:@selector(itemToggled:)];
    else {
      NSTextField *f = [NSTextField new];
      f.bordered = NO; f.drawsBackground = NO; f.editable = YES; f.lineBreakMode = NSLineBreakByTruncatingTail;
      f.target = self; f.action = @selector(itemEdited:); f.cell.sendsActionOnEndEditing = YES;
      cv.textField = f; ctl = f;
    }
    ctl.translatesAutoresizingMaskIntoConstraints = NO; [cv addSubview:ctl];
    [NSLayoutConstraint activateConstraints:@[
      [ctl.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
      [ctl.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:[ident isEqualToString:@"on"] ? 3 : 2],
    ]];
    if (cv.textField) [ctl.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-2].active = YES;
  }
  if ([ident isEqualToString:@"on"]) ((NSButton *)cv.subviews.firstObject).state = it.enabled ? NSControlStateValueOn : NSControlStateValueOff;
  else cv.textField.stringValue = ([ident isEqualToString:@"name"] ? it.name : it.value) ?: @"";
  return cv;
}

- (void)itemToggled:(NSButton *)b {
  NSTableView *t = [self tableOf:b]; NSInteger row = [t rowForView:b];
  if (row >= 0 && row < (NSInteger)[self itemsOf:t].count) [self itemsOf:t][row].enabled = b.state == NSControlStateValueOn;
}
- (void)itemEdited:(NSTextField *)f {
  NSTableView *t = [self tableOf:f]; NSInteger row = [t rowForView:f], col = [t columnForView:f];
  if (row < 0 || row >= (NSInteger)[self itemsOf:t].count || col < 0) return;
  SRLaunchItem *it = [self itemsOf:t][row];
  NSString *v = f.stringValue;
  if ([t.tableColumns[col].identifier isEqualToString:@"name"]) it.name = [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  else it.value = v;
}
- (void)addOrRemove:(NSSegmentedControl *)pm {
  NSTableView *t = pm.tag == 1 ? _argsTable : _envTable;
  NSMutableArray *items = [self itemsOf:t];
  [_sheet makeFirstResponder:nil];   // commit an edit in progress
  if (pm.selectedSegment == 0) {
    SRLaunchItem *it = [SRLaunchItem new]; it.enabled = YES; it.name = @""; it.value = @"";
    [items addObject:it];
    [t reloadData];
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:items.count - 1] byExtendingSelection:NO];
    [t editColumn:1 row:(NSInteger)items.count - 1 withEvent:nil select:YES];
  } else {
    NSIndexSet *sel = t.selectedRowIndexes;
    [items removeObjectsAtIndexes:[sel indexesPassingTest:^BOOL(NSUInteger i, BOOL *stop) { return i < items.count; }]];
    [t reloadData];
  }
}

// ---------------------------------------------------------------- state
- (void)refresh {
  [_runtime removeAllItems];
  SRRuntime *mine = [SRRuntime runtimeAtRoot:SREnvironment.runtimeRoot];
  [_runtime addItemWithTitle:mine ? [NSString stringWithFormat:@"Same as SimRun — %@", mine.name] : @"Same as SimRun"];
  [_runtime.menu addItem:NSMenuItem.separatorItem];
  NSString *want = _options.runtimeBuild;
  NSMenuItem *selected = nil;
  for (SRRuntime *r in SREnvironment.installedRuntimes) {
    NSMenuItem *it = [_runtime.menu addItemWithTitle:r.name action:nil keyEquivalent:@""];
    it.representedObject = r.build;
    if ([r.build isEqualToString:want]) selected = it;
  }
  if (want && !selected) {   // saved, but no longer installed
    selected = [_runtime.menu addItemWithTitle:[NSString stringWithFormat:@"%@ (Not Installed)", want] action:nil keyEquivalent:@""];
    selected.representedObject = want;
  }
  if (selected) [_runtime selectItem:selected]; else [_runtime selectItemAtIndex:0];
  [self refreshDevices];
  [_locale selectItemAtIndex:[_options.switches containsObject:@"LOCALE_DISABLE"] ? 1 : 0];
  for (NSButton *b in _switchBoxes) b.state = [_options.switches containsObject:b.identifier] != (b.tag != 0) ? NSControlStateValueOn : NSControlStateValueOff;
  [_argsTable reloadData]; [_envTable reloadData];
}

// The runtime the app would run on: its own, or SimRun's; nil if its own isn't installed.
- (SRRuntime *)selectedRuntime {
  return _options.runtimeBuild ? [SREnvironment installedRuntimeWithBuild:_options.runtimeBuild] : [SRRuntime runtimeAtRoot:SREnvironment.runtimeRoot];
}

// The Device menu: the selected runtime's default device type, then the others it supports, iPhones and iPads apart.
- (void)refreshDevices {
  [_device removeAllItems];
  SRRuntime *rt = [self selectedRuntime];
  NSArray<SRDeviceType *> *types = [SREnvironment deviceTypesForRuntime:rt];
  SRDeviceType *def = [SREnvironment defaultDeviceTypeForRuntime:rt];
  [_device addItemWithTitle:def ? [NSString stringWithFormat:@"Default — %@", def.name] : @"Default"];
  NSString *want = _options.deviceType, *family = nil;
  NSMenuItem *selected = nil;
  for (SRDeviceType *d in types) {
    if (![d.family isEqualToString:family]) { [_device.menu addItem:NSMenuItem.separatorItem]; family = d.family; }
    NSMenuItem *it = [_device.menu addItemWithTitle:d.name action:nil keyEquivalent:@""];
    it.representedObject = d.identifier;
    it.toolTip = [NSString stringWithFormat:@"%@ — %.0f×%.0f points @%gx", d.modelIdentifier ?: d.identifier,
                  d.screenWidth / d.screenScale, d.screenHeight / d.screenScale, d.screenScale];
    if ([d.identifier isEqualToString:want]) selected = it;
  }
  if (want && !selected) {   // saved, but the runtime doesn't support it (or it is no longer installed)
    NSString *name = [want componentsSeparatedByString:@"SimDeviceType."].lastObject;
    name = [name stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    [_device.menu addItem:NSMenuItem.separatorItem];
    selected = [_device.menu addItemWithTitle:rt ? [NSString stringWithFormat:@"%@ (Not Supported by %@)", name, rt.name]
                                                 : [NSString stringWithFormat:@"%@ (Not Available)", name]
                                       action:nil keyEquivalent:@""];
    selected.representedObject = want;
  }
  if (selected) [_device selectItem:selected]; else [_device selectItemAtIndex:0];
}

- (void)selectTab:(NSButton *)sender {
  for (NSUInteger i = 0; i < _tabs.count; i++) { _tabs[i].selected = (NSInteger)i == sender.tag; _pages[i].hidden = (NSInteger)i != sender.tag; }
}
- (void)runtimeChanged:(NSPopUpButton *)p {
  _options.runtimeBuild = p.selectedItem.representedObject;
  // a device type the new runtime doesn't support: back to its default
  if (_options.deviceType && ![SREnvironment deviceTypeWithIdentifier:_options.deviceType runtime:[self selectedRuntime]]) _options.deviceType = nil;
  [self refreshDevices];
}
- (void)deviceChanged:(NSPopUpButton *)p { _options.deviceType = p.selectedItem.representedObject; }
- (void)localeChanged:(NSPopUpButton *)p {
  if (p.indexOfSelectedItem == 1) [_options.switches addObject:@"LOCALE_DISABLE"]; else [_options.switches removeObject:@"LOCALE_DISABLE"];
}
- (void)switchToggled:(NSButton *)b {
  BOOL set = (b.state == NSControlStateValueOn) != (b.tag != 0);   // tag 1: the box is checked while the variable is unset
  if (set) [_options.switches addObject:b.identifier]; else [_options.switches removeObject:b.identifier];
}
- (void)restoreDefaults:(id)s { [_sheet makeFirstResponder:nil]; _options = [SRLaunchOptions new]; [self refresh]; }
- (void)cancel:(id)s { [_parent endSheet:_sheet]; }
- (void)launch:(id)s {
  [_sheet makeFirstResponder:nil];
  [_options saveForAppAtPath:_app.path];
  [_parent endSheet:_sheet];
  if (_launch) _launch();
}
@end
