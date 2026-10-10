// environment.m — see environment.h. Keep in sync with scripts/simrun.sh.
#import "environment.h"
#include <mach-o/dyld.h>
#include <pwd.h>

extern char **environ;

static NSString *ExecutableDir(void) {
  char buf[PATH_MAX]; uint32_t n = sizeof buf; _NSGetExecutablePath(buf, &n);
  char real[PATH_MAX]; if (!realpath(buf, real)) strlcpy(real, buf, sizeof real);
  return [@(real) stringByDeletingLastPathComponent];
}
static BOOL InAppBundle(void) { return [NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"app"]; }
static NSString *RealHome(void) { struct passwd *pw = getpwuid(getuid()); return pw ? @(pw->pw_dir) : NSHomeDirectory(); }

@implementation SRRuntime
+ (instancetype)runtimeAtRoot:(NSString *)root {
  if (!root.length) return nil;
  NSDictionary *sv = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"System/Library/CoreServices/SystemVersion.plist"]];
  if (![sv[@"ProductVersion"] isKindOfClass:NSString.class]) return nil;
  SRRuntime *r = [SRRuntime new];
  r->_root = root; r->_version = sv[@"ProductVersion"];
  r->_build = [sv[@"ProductBuildVersion"] isKindOfClass:NSString.class] ? sv[@"ProductBuildVersion"] : @"";
  r->_name = [NSString stringWithFormat:@"iOS %@ (%@)", r->_version, r->_build];
  return r;
}
@end

static NSString *const kRuntimeKey = @"SRRuntimeBuild";

@implementation SREnvironment

// The available iOS runtimes' roots as CoreSimulator knows them, wherever they are mounted (disk images under
// CoreSimulator/Volumes, cryptexes under /private/var/run/com.apple.security.cryptexd/mnt, bundles in
// CoreSimulator/Profiles); nil if simctl can't be run or doesn't answer within 5 s.
static NSArray<NSString *> *SimctlRuntimeRoots(void) {
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
  t.arguments = @[ @"simctl", @"list", @"runtimes", @"--json" ];
  // a Mac process: none of the sim environment SimRun itself may have been started with (simrun.sh)
  NSMutableDictionary *env = [NSMutableDictionary dictionary];
  [NSProcessInfo.processInfo.environment enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
    if (![k hasPrefix:@"DYLD_"] && ![k hasPrefix:@"SIMULATOR_"] && ![k hasPrefix:@"IPHONE_"] && ![@[ @"CFFIXED_USER_HOME", @"TMPDIR" ] containsObject:k]) env[k] = v;
  }];
  env[@"HOME"] = RealHome();
  t.environment = env;
  NSPipe *out = [NSPipe pipe];
  t.standardOutput = out; t.standardError = [NSFileHandle fileHandleWithNullDevice];
  if (![t launchAndReturnError:nil]) return nil;
  __block NSData *data = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    data = [out.fileHandleForReading readDataToEndOfFile];
    dispatch_semaphore_signal(done);
  });
  if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) { [t terminate]; return nil; }
  [t waitUntilExit];
  if (t.terminationStatus != 0) return nil;
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSArray *list = [json isKindOfClass:NSDictionary.class] && [json[@"runtimes"] isKindOfClass:NSArray.class] ? json[@"runtimes"] : nil;
  if (!list) return nil;
  NSMutableArray *roots = [NSMutableArray array];
  for (NSDictionary *r in list) {
    if (![r isKindOfClass:NSDictionary.class] || ![r[@"platform"] isEqual:@"iOS"] || ![r[@"isAvailable"] boolValue]) continue;
    if ([r[@"runtimeRoot"] isKindOfClass:NSString.class]) [roots addObject:r[@"runtimeRoot"]];
  }
  return roots;
}

// Without simctl: the places runtimes are mounted or installed.
static NSArray<NSString *> *ScannedRuntimeRoots(void) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableArray<NSString *> *dirs = [NSMutableArray arrayWithObject:@"/Library/Developer/CoreSimulator/Profiles/Runtimes"];
  for (NSString *mounts in @[ @"/Library/Developer/CoreSimulator/Volumes", @"/private/var/run/com.apple.security.cryptexd/mnt" ])
    for (NSString *v in [fm contentsOfDirectoryAtPath:mounts error:nil])
      if ([v hasPrefix:@"iOS_"]) [dirs addObject:[mounts stringByAppendingFormat:@"/%@/Library/Developer/CoreSimulator/Profiles/Runtimes", v]];
  NSMutableArray *roots = [NSMutableArray array];
  for (NSString *dir in dirs)
    for (NSString *r in [fm contentsOfDirectoryAtPath:dir error:nil])
      if ([r hasPrefix:@"iOS"] && [r.pathExtension isEqualToString:@"simruntime"])
        [roots addObject:[dir stringByAppendingFormat:@"/%@/Contents/Resources/RuntimeRoot", r]];
  return roots;
}

static NSArray<SRRuntime *> *gRuntimes;
static CFAbsoluteTime gRuntimesTime;

+ (void)reloadInstalledRuntimes { @synchronized(self) { gRuntimes = nil; } }

+ (NSArray<SRRuntime *> *)installedRuntimes {
  @synchronized(self) {
    if (gRuntimes && CFAbsoluteTimeGetCurrent() - gRuntimesTime < 30) return gRuntimes;
    NSArray *roots = SimctlRuntimeRoots() ?: ScannedRuntimeRoots();
    NSMutableArray<SRRuntime *> *out = [NSMutableArray array];
    NSMutableSet *builds = [NSMutableSet set];
    for (NSString *root in roots) {
      SRRuntime *rt = [SRRuntime runtimeAtRoot:root];
      if (rt && ![builds containsObject:rt.build]) { [builds addObject:rt.build]; [out addObject:rt]; }
    }
    [out sortUsingComparator:^NSComparisonResult(SRRuntime *a, SRRuntime *b) {
      NSComparisonResult c = [b.version compare:a.version options:NSNumericSearch];
      return c != NSOrderedSame ? c : [b.build compare:a.build options:NSNumericSearch];
    }];
    gRuntimes = out; gRuntimesTime = CFAbsoluteTimeGetCurrent();
    return out;
  }
}
+ (SRRuntime *)installedRuntimeWithBuild:(NSString *)build {
  for (SRRuntime *r in [self installedRuntimes]) if ([r.build isEqualToString:build]) return r;
  return nil;
}

+ (NSString *)preferredRuntimeBuild {
  NSString *b = [NSUserDefaults.standardUserDefaults stringForKey:kRuntimeKey];
  return b.length ? b : nil;
}
+ (void)setPreferredRuntimeBuild:(NSString *)build {
  if (build.length) [NSUserDefaults.standardUserDefaults setObject:build forKey:kRuntimeKey];
  else [NSUserDefaults.standardUserDefaults removeObjectForKey:kRuntimeKey];
}

+ (BOOL)runtimeRootFromEnvironment { return NSProcessInfo.processInfo.environment[@"SIMRUN_RUNTIME_ROOT"].length > 0; }

+ (NSString *)runtimeRoot {
  static NSString *root; static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *o = NSProcessInfo.processInfo.environment[@"SIMRUN_RUNTIME_ROOT"];
    if (o.length) { root = o.stringByStandardizingPath; return; }
    NSString *pref = [self preferredRuntimeBuild];
    root = (pref ? [self installedRuntimeWithBuild:pref] : nil).root ?: [self installedRuntimes].firstObject.root;
  });
  return root;
}

+ (NSDictionary<NSString *, NSString *> *)runtimeVariablesForRoot:(NSString *)R {
  if (!R) return @{};
  SRRuntime *rt = [SRRuntime runtimeAtRoot:R];
  return @{
    @"DYLD_ROOT_PATH": R, @"IPHONE_SIMULATOR_ROOT": R, @"SIMULATOR_ROOT": R,
    @"DYLD_SHARED_CACHE_DIR": [R stringByAppendingPathComponent:@"System/Library/Caches/com.apple.dyld"],
    @"DYLD_FALLBACK_FRAMEWORK_PATH": [R stringByAppendingPathComponent:@"System/Library/Frameworks"],
    @"DYLD_FALLBACK_LIBRARY_PATH": [R stringByAppendingPathComponent:@"usr/lib"],
    @"SIMULATOR_RUNTIME_VERSION": rt.version ?: @"", @"SIMULATOR_RUNTIME_BUILD_VERSION": rt.build ?: @"",
  };
}

+ (NSString *)dataDirectory {
  return NSProcessInfo.processInfo.environment[@"SIMRUN_DATA"] ?: [RealHome() stringByAppendingPathComponent:@"Library/Developer/SimRun/data"];
}

+ (NSString *)containerIdentifierForExecutable:(NSString *)executable {
  NSString *dir = executable.stringByDeletingLastPathComponent;
  NSString *ident = nil;
  if ([dir.pathExtension isEqualToString:@"app"])
    ident = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"];
  if (![ident isKindOfClass:NSString.class] || !ident.length) ident = executable.lastPathComponent;
  return [ident stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
}
+ (NSString *)containerPathForIdentifier:(NSString *)identifier {
  return [[[self dataDirectory] stringByAppendingPathComponent:@"Containers/Data/Application"] stringByAppendingPathComponent:identifier];
}
+ (NSString *)createContainerForIdentifier:(NSString *)identifier {
  NSString *c = [self containerPathForIdentifier:identifier];
  for (NSString *sub in @[ @"Documents", @"Library/Caches", @"Library/Preferences", @"tmp" ])
    [NSFileManager.defaultManager createDirectoryAtPath:[c stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:nil];
  return c;
}

+ (NSDictionary<NSString *, NSString *> *)simulatorVariables { return [self simulatorVariablesForRoot:[self runtimeRoot]]; }
+ (NSDictionary<NSString *, NSString *> *)simulatorVariablesForRoot:(NSString *)R {
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  if (!R) return @{};
  NSString *D = [self dataDirectory];
  for (NSString *sub in @[ @"tmp", @"Library/Preferences", @"Documents" ])
    [NSFileManager.defaultManager createDirectoryAtPath:[D stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:nil];
  NSMutableDictionary *vars = [@{
    @"HOME": D, @"CFFIXED_USER_HOME": D, @"TMPDIR": [D stringByAppendingString:@"/tmp/"],
    @"IPHONE_SHARED_RESOURCES_DIRECTORY": D, @"SIMULATOR_SHARED_RESOURCES_DIRECTORY": D,
    @"SIMULATOR_HOST_HOME": env[@"SIMRUN_HOST_HOME"] ?: RealHome(),
    @"SIMULATOR_ARCHS": @"arm64",
    @"SIMULATOR_DEVICE_NAME": @"SimRun", @"SIMULATOR_MODEL_IDENTIFIER": @"iPhone19,4", @"SIMULATOR_PRODUCT_CLASS": @"V68",
    @"SIMULATOR_CAPABILITIES": @"/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype/Contents/Resources/capabilities.plist",
    @"SIMULATOR_MAINSCREEN_WIDTH": env[@"SIMRUN_W"] ?: @"1206", @"SIMULATOR_MAINSCREEN_HEIGHT": env[@"SIMRUN_H"] ?: @"2622",
    @"SIMULATOR_MAINSCREEN_SCALE": env[@"SIMRUN_SCALE"] ?: @"3.000000", @"SIMULATOR_MAINSCREEN_PITCH": @"460.000000",
    @"SIMULATOR_UDID": @"00000000-0000-0000-0000-000000000000", @"SIMULATOR_LEGACY_ASSET_SUFFIX": @"iphone",
    @"SIMULATOR_BOOT_TIME": [NSString stringWithFormat:@"%ld", (long)time(NULL)],
    @"XPC_FLAGS": @"0x0", @"LS_ENABLE_BUNDLE_LOCALIZATION_CACHING": @"1",
  } mutableCopy];
  [vars addEntriesFromDictionary:[self runtimeVariablesForRoot:R]];
  return vars;
}

+ (NSString *)hostInternationalSettings {
  // The Mac's language & region settings (rshim.dylib applies them in each app). Read from the plist: when SimRun runs
  // from simrun.sh, HOME and CFFIXED_USER_HOME are the device's, and CFPreferences would read the device's instead.
  NSDictionary *g = [NSDictionary dictionaryWithContentsOfFile:[RealHome() stringByAppendingPathComponent:@"Library/Preferences/.GlobalPreferences.plist"]];
  if (!g) return nil;
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSString *k in @[ @"AppleLocale", @"AppleLanguages", @"AppleLanguagesSchemaVersion", @"AppleCollationOrder", @"AppleFirstWeekday",
                         @"AppleMeasurementUnits", @"AppleMetricUnits", @"AppleTemperatureUnit", @"AppleICUForce12HourTime",
                         @"AppleICUForce24HourTime", @"AppleICUDateFormatStrings", @"AppleICUTimeFormatStrings",
                         @"AppleICUNumberSymbols", @"AppleICUDateTimeSymbols" ]) {
    id v = g[k];
    out[k] = v && [NSJSONSerialization isValidJSONObject:@[ v ]] ? v : NSNull.null;   // null: not set on the Mac
  }
  NSData *d = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:NULL];
  return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

+ (NSArray<NSString *> *)processEnvironment {
  NSMutableArray *a = [NSMutableArray array];
  for (char **e = environ; *e; e++) [a addObject:@(*e)];
  return a;
}

+ (NSArray<NSString *> *)environment:(NSArray<NSString *> *)base withOverrides:(NSDictionary<NSString *, NSString *> *)overrides {
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *kv in base) {
    NSRange eq = [kv rangeOfString:@"="];
    if (eq.location != NSNotFound && overrides[[kv substringToIndex:eq.location]]) continue;
    [out addObject:kv];
  }
  [overrides enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [out addObject:[NSString stringWithFormat:@"%@=%@", k, v]]; }];
  return out;
}

+ (NSString *)simnsPath {
  return InAppBundle() ? [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/simns"]
                       : [ExecutableDir() stringByAppendingPathComponent:@"simns"];
}
+ (NSString *)libraryDirectory {
  return InAppBundle() ? [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"lib"]
                       : [[ExecutableDir() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"lib"];
}
+ (NSString *)injectedLibraries {
  NSString *d = [self libraryDirectory];
  NSMutableArray *libs = [NSMutableArray array];
  for (NSString *n in @[ @"rshim.dylib", @"glue.dylib", @"scenes.dylib", @"hid.dylib", @"pboard.dylib", @"drag.dylib", @"keychain.dylib", @"webkit.dylib" ]) [libs addObject:[d stringByAppendingPathComponent:n]];
  NSString *extra = NSProcessInfo.processInfo.environment[@"SIMAPP_EXTRA_INSERT"];
  if (extra.length) [libs addObject:extra];
  return [libs componentsJoinedByString:@":"];
}
+ (NSString *)framebufferFramework { return [[self libraryDirectory] stringByAppendingPathComponent:@"SimFramebuffer"]; }
@end
