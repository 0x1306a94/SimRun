// launcher.m — see launcher.h.
#import "launcher.h"
#import "keychainwindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// ---------------------------------------------------------------- row view: icon, name, path, running dot
@interface SRAppCell : NSTableCellView
@property NSTextField *subtitle; @property NSView *runningDot; @property NSProgressIndicator *spinner; @property NSView *status;
- (void)setState:(SRAppState)state;
@end
@implementation SRAppCell
- (instancetype)initWithFrame:(NSRect)f {
  if (!(self = [super initWithFrame:f])) return nil;
  NSImageView *iv = [NSImageView new]; iv.imageScaling = NSImageScaleProportionallyUpOrDown; iv.translatesAutoresizingMaskIntoConstraints = NO;
  NSTextField *title = [NSTextField labelWithString:@""]; title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  title.translatesAutoresizingMaskIntoConstraints = NO; title.lineBreakMode = NSLineBreakByTruncatingTail;
  NSTextField *sub = [NSTextField labelWithString:@""]; sub.font = [NSFont systemFontOfSize:11]; sub.textColor = NSColor.secondaryLabelColor;
  sub.translatesAutoresizingMaskIntoConstraints = NO; sub.lineBreakMode = NSLineBreakByTruncatingMiddle;
  sub.allowsExpansionToolTips = YES;
  NSView *dot = [NSView new]; dot.wantsLayer = YES; dot.layer.cornerRadius = 4; dot.layer.backgroundColor = NSColor.systemGreenColor.CGColor;
  dot.translatesAutoresizingMaskIntoConstraints = NO; dot.toolTip = @"Running";
  NSProgressIndicator *spin = [NSProgressIndicator new];
  spin.style = NSProgressIndicatorStyleSpinning; spin.controlSize = NSControlSizeSmall; spin.displayedWhenStopped = NO;
  spin.translatesAutoresizingMaskIntoConstraints = NO; spin.toolTip = @"Launching…";
  // three columns: icon | name + path (stacked) | status (running dot or launch spinner). The status column is hidden
  // (and takes no space) while the app isn't running, so the titles use the full width.
  NSStackView *titles = [NSStackView stackViewWithViews:@[ title, sub ]];
  titles.orientation = NSUserInterfaceLayoutOrientationVertical; titles.alignment = NSLayoutAttributeLeading; titles.spacing = 2;
  for (NSTextField *f in @[ title, sub ]) [f setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSView *status = [NSView new]; status.translatesAutoresizingMaskIntoConstraints = NO;
  [status addSubview:dot]; [status addSubview:spin];
  NSStackView *row = [NSStackView stackViewWithViews:@[ iv, titles, status ]];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal; row.alignment = NSLayoutAttributeCenterY; row.spacing = 10;
  row.detachesHiddenViews = YES; row.translatesAutoresizingMaskIntoConstraints = NO;
  [row setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [titles setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self addSubview:row];
  self.imageView = iv; self.textField = title; self.subtitle = sub; self.runningDot = dot; self.spinner = spin; self.status = status;
  [NSLayoutConstraint activateConstraints:@[
    [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8], [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
    [row.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [iv.widthAnchor constraintEqualToConstant:36], [iv.heightAnchor constraintEqualToConstant:36],
    [status.widthAnchor constraintEqualToConstant:18], [status.heightAnchor constraintEqualToConstant:18],
    [dot.centerXAnchor constraintEqualToAnchor:status.centerXAnchor], [dot.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
    [dot.widthAnchor constraintEqualToConstant:8], [dot.heightAnchor constraintEqualToConstant:8],
    [spin.centerXAnchor constraintEqualToAnchor:status.centerXAnchor], [spin.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
  ]];
  return self;
}
- (void)setState:(SRAppState)state {
  self.status.hidden = state == SRAppStateStopped;
  self.runningDot.hidden = state != SRAppStateRunning;
  if (state == SRAppStateLaunching) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
}
@end

// Content view that accepts .app drops anywhere in the window (also over the empty-state hint).
@interface SRDropView : NSView
@property (copy) BOOL (^onDrop)(NSArray<NSString *> *paths);
@end
@implementation SRDropView
- (NSArray<NSString *> *)appPaths:(id<NSDraggingInfo>)info {
  NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
  NSMutableArray *paths = [NSMutableArray array];
  for (NSURL *u in urls) if ([u.pathExtension isEqualToString:@"app"]) [paths addObject:u.path];
  return paths;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [self appPaths:info].count ? NSDragOperationCopy : NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info { NSArray *p = [self appPaths:info]; return p.count && self.onDrop && self.onDrop(p); }
@end

// ---------------------------------------------------------------- launcher
@interface SRLauncher () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
@end

@implementation SRLauncher {
  __weak id<SRLauncherDelegate> _delegate;
  NSWindow *_window; NSTableView *_table; NSTextField *_emptyHint;
}

- (instancetype)initWithDelegate:(id<SRLauncherDelegate>)delegate {
  if ((self = [super init])) {
    _delegate = delegate;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:SRLibraryDidChangeNotification object:nil];
  }
  return self;
}

- (void)buildWindow {
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 480)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
      backing:NSBackingStoreBuffered defer:NO];
  _window.title = @"SimRun"; _window.releasedWhenClosed = NO; _window.minSize = NSMakeSize(320, 260);
  _window.frameAutosaveName = @"SRLauncherWindow";
  if (!_window.frameAutosaveName.length || ![_window setFrameUsingName:@"SRLauncherWindow"]) [_window center];

  SRDropView *root = [[SRDropView alloc] initWithFrame:_window.contentView.bounds];
  [root registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
  __weak SRLauncher *weakSelf = self;
  root.onDrop = ^BOOL(NSArray<NSString *> *paths) { [weakSelf openPaths:paths]; return YES; };
  _window.contentView = root;

  _table = [NSTableView new];
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"app"]; col.resizingMask = NSTableColumnAutoresizingMask;
  col.minWidth = 100; col.width = 100;   // grows to the table's width (sizeLastColumnToFit / autoresizing), never beyond
  [_table addTableColumn:col];
  _table.headerView = nil; _table.rowHeight = 52; _table.style = NSTableViewStyleInset;
  _table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;   // the column always spans the table
  _table.dataSource = self; _table.delegate = self;
  _table.target = self; _table.doubleAction = @selector(launchSelected:);
  [_table registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
  [_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
  NSMenu *menu = [NSMenu new]; menu.delegate = self; _table.menu = menu;

  NSScrollView *scroll = [NSScrollView new];
  scroll.documentView = _table; scroll.hasVerticalScroller = YES; scroll.hasHorizontalScroller = NO; scroll.drawsBackground = NO;
  scroll.automaticallyAdjustsContentInsets = NO;
  scroll.contentInsets = NSEdgeInsetsMake(0, 0, 12, 0);
  scroll.translatesAutoresizingMaskIntoConstraints = NO;

  _emptyHint = [NSTextField wrappingLabelWithString:@"Drop iOS Simulator apps here\n\nBuild your app for an iOS Simulator destination in Xcode, then drag the .app from Build/Products/Debug-iphonesimulator onto this window."];
  _emptyHint.alignment = NSTextAlignmentCenter; _emptyHint.textColor = NSColor.secondaryLabelColor;
  _emptyHint.translatesAutoresizingMaskIntoConstraints = NO;

  for (NSView *v in @[ scroll, _emptyHint ]) [root addSubview:v];
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:root.topAnchor], [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor], [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    [_emptyHint.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor], [_emptyHint.centerYAnchor constraintEqualToAnchor:scroll.centerYAnchor],
    [_emptyHint.widthAnchor constraintEqualToAnchor:scroll.widthAnchor multiplier:0.75],
  ]];
  [self reload];
}

- (void)show {
  if (!_window) [self buildWindow];
  [_window layoutIfNeeded];
  [_table sizeLastColumnToFit];
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)reload {
  if (!_window) return;
  NSInteger sel = _table.selectedRow;
  [_table reloadData];
  if (sel >= 0 && sel < _table.numberOfRows) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:sel] byExtendingSelection:NO];
  _emptyHint.hidden = SRLibrary.shared.apps.count > 0;
}
- (void)reloadState { [self reload]; }
- (SRAppInfo *)selectedApp {
  NSInteger r = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
  return r >= 0 && r < (NSInteger)SRLibrary.shared.apps.count ? SRLibrary.shared.apps[r] : nil;
}

// ---------------------------------------------------------------- actions
- (void)launchSelected:(id)sender { SRAppInfo *a = [self selectedApp]; if (a) [_delegate launchApp:a]; }

- (void)openPaths:(NSArray<NSString *> *)paths {
  NSMutableArray *problems = [NSMutableArray array];
  SRAppInfo *last = nil;
  for (NSString *p in paths) {
    NSString *why = [SRAppInfo problemWithAppAtPath:p];
    if (why) { [problems addObject:[NSString stringWithFormat:@"%@: %@", p.lastPathComponent, why]]; continue; }
    last = [SRLibrary.shared addPath:p];
    [_delegate launchApp:last];
  }
  if (last) {
    NSUInteger i = [SRLibrary.shared.apps indexOfObject:last];
    if (i != NSNotFound && _window) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
  }
  if (problems.count) {
    [self show];
    NSAlert *al = [NSAlert new];
    al.messageText = problems.count == 1 ? @"This app can't run in SimRun" : @"Some apps can't run in SimRun";
    al.informativeText = [problems componentsJoinedByString:@"\n\n"];
    [al beginSheetModalForWindow:_window completionHandler:nil];
  }
}

- (void)addAppWithPanel {
  [self show];
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.allowedContentTypes = @[ UTTypeApplicationBundle ]; p.allowsMultipleSelection = YES; p.treatsFilePackagesAsDirectories = NO;
  p.message = @"Choose iOS Simulator app bundles (built for an iOS Simulator destination).";
  [p beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
    if (r != NSModalResponseOK) return;
    NSMutableArray *paths = [NSMutableArray array]; for (NSURL *u in p.URLs) [paths addObject:u.path];
    [self openPaths:paths];
  }];
}

- (void)addXcodeBuilds {
  [self show];
  NSArray *builds = [SRLibrary xcodeSimulatorBuilds];
  NSUInteger before = SRLibrary.shared.apps.count;
  for (NSString *p in builds) [SRLibrary.shared addPath:p];
  NSUInteger added = SRLibrary.shared.apps.count - before;
  NSAlert *al = [NSAlert new];
  al.messageText = added ? [NSString stringWithFormat:@"Added %lu app%@ from Xcode", (unsigned long)added, added == 1 ? @"" : @"s"]
                         : @"No new iOS Simulator builds found";
  al.informativeText = builds.count ? @"Found in ~/Library/Developer/Xcode/DerivedData." :
      @"Build a project for an iOS Simulator destination in Xcode first; SimRun looks in ~/Library/Developer/Xcode/DerivedData.";
  [al beginSheetModalForWindow:_window completionHandler:nil];
}

- (void)showInFinder:(id)sender { SRAppInfo *a = [self selectedApp]; if (a) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:a.path] ]]; }
- (void)removeSelected:(id)sender { SRAppInfo *a = [self selectedApp]; if (a) [SRLibrary.shared removePath:a.path]; }
- (void)quitSelected:(id)sender { SRAppInfo *a = [self selectedApp]; if (a) [_delegate quitApp:a]; }
- (void)logSelected:(id)sender { SRAppInfo *a = [self selectedApp]; if (a) [_delegate showLogForApp:a]; }
- (void)keychainSelected:(id)sender { SRAppInfo *a = [self selectedApp]; if (a) [SRKeychainWindow.shared showWithFilter:a.bundleIdentifier ?: @""]; }

- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];
  SRAppInfo *a = [self selectedApp];
  if (!a) return;
  SRAppState st = [_delegate stateForApp:a];
  if (st != SRAppStateLaunching)
    [menu addItemWithTitle:st == SRAppStateRunning ? @"Show" : @"Launch" action:@selector(launchSelected:) keyEquivalent:@""].target = self;
  if (st != SRAppStateStopped) [menu addItemWithTitle:@"Quit App" action:@selector(quitSelected:) keyEquivalent:@""].target = self;
  [menu addItemWithTitle:@"Show Log" action:@selector(logSelected:) keyEquivalent:@""].target = self;
  [menu addItemWithTitle:@"Show Keychain Items" action:@selector(keychainSelected:) keyEquivalent:@""].target = self;
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItemWithTitle:@"Show in Finder" action:@selector(showInFinder:) keyEquivalent:@""].target = self;
  [menu addItemWithTitle:@"Remove from SimRun" action:@selector(removeSelected:) keyEquivalent:@""].target = self;
}

// ---------------------------------------------------------------- table
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return SRLibrary.shared.apps.count; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
  SRAppCell *cell = [t makeViewWithIdentifier:@"cell" owner:self];
  if (!cell) { cell = [[SRAppCell alloc] initWithFrame:NSZeroRect]; cell.identifier = @"cell"; }
  SRAppInfo *a = SRLibrary.shared.apps[row];
  cell.imageView.image = a.icon;
  cell.textField.stringValue = a.name;
  cell.subtitle.stringValue = a.bundleIdentifier.length ? [NSString stringWithFormat:@"%@ - %@", a.bundleIdentifier, a.path.stringByAbbreviatingWithTildeInPath] : a.path.stringByAbbreviatingWithTildeInPath;
  [cell setState:[_delegate stateForApp:a]];
  return cell;
}
- (NSDragOperation)tableView:(NSTableView *)t validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op {
  [t setDropRow:-1 dropOperation:NSTableViewDropOn];   // whole-table highlight
  NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
  for (NSURL *u in urls) if ([u.pathExtension isEqualToString:@"app"]) return NSDragOperationCopy;
  return NSDragOperationNone;
}
- (BOOL)tableView:(NSTableView *)t acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {
  NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
  NSMutableArray *paths = [NSMutableArray array]; for (NSURL *u in urls) if ([u.pathExtension isEqualToString:@"app"]) [paths addObject:u.path];
  [self openPaths:paths];
  return paths.count > 0;
}
@end
