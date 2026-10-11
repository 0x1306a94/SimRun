// appdetail.h — the launcher's app pane: the selected app's icon, name and details, then its tabs. Profiles lists its
// data containers (its default one and its profiles) with what each runs as and its running instances, and creates
// new profiles. With no app selected, the pane says how to add apps.
#pragma once
#import <Cocoa/Cocoa.h>
#import "launcher.h"

@interface SRAppDetailController : NSViewController
- (instancetype)initWithDelegate:(id<SRLauncherDelegate>)delegate;
@property (nonatomic) SRAppInfo *app;                       // nil: the empty state
@property (nonatomic) BOOL libraryEmpty;                    // the empty state offers to add apps (else "No App Selected")
@property (copy) void (^onAddApp)(void), (^onAddXcodeBuilds)(void);
@property (copy) void (^onDrop)(NSArray<NSString *> *paths);   // .app bundles dropped on the pane

// The profile selected in the Profiles outline (nil: the default one, also when none is selected), and selecting one.
@property (readonly) NSString *selectedProfile;
- (void)selectProfile:(NSString *)profile;
@property (copy) void (^onSelectProfile)(void);             // the selection changed
@property (copy) void (^onOpenProfile)(NSString *profile);  // a profile was double-clicked
// The context menu of the outline's rows; profileForMenu: gives the row it is open for (NO: none, e.g. empty space).
@property (nonatomic) NSMenu *profileMenu;
- (BOOL)profileForMenu:(NSString **)profile;
// Asks whether to delete `profile` (its data container and launch options), then does. Not the default profile, and
// not while the app runs in it.
- (BOOL)canDeleteProfile:(NSString *)profile;
- (void)deleteProfile:(NSString *)profile;

- (void)reloadInfo;    // the app's launch options changed (or anything else in its details)
- (void)reloadState;   // an instance of it started or exited, or a container changed
@end
