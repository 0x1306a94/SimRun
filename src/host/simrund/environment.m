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

@implementation SREnvironment

+ (NSString *)runtimeRoot {
  NSString *o = NSProcessInfo.processInfo.environment[@"SIMRUN_RUNTIME_ROOT"];
  if (o.length) return o;
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *vols = @"/Library/Developer/CoreSimulator/Volumes";
  NSString *best = nil, *bestVersion = nil;
  for (NSString *v in [fm contentsOfDirectoryAtPath:vols error:nil]) {
    if (![v hasPrefix:@"iOS_"]) continue;
    NSString *rt = [vols stringByAppendingFormat:@"/%@/Library/Developer/CoreSimulator/Profiles/Runtimes", v];
    for (NSString *r in [fm contentsOfDirectoryAtPath:rt error:nil]) {
      if (![r hasPrefix:@"iOS"] || ![r.pathExtension isEqualToString:@"simruntime"]) continue;
      NSString *root = [rt stringByAppendingFormat:@"/%@/Contents/Resources/RuntimeRoot", r];
      NSString *ver = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"System/Library/CoreServices/SystemVersion.plist"]][@"ProductVersion"] ?: @"0";
      if (!best || [ver compare:bestVersion options:NSNumericSearch] == NSOrderedDescending) { best = root; bestVersion = ver; }
    }
  }
  return best;
}

+ (NSDictionary<NSString *, NSString *> *)simulatorVariables {
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  NSString *R = [self runtimeRoot];
  if (!R) return @{};
  NSString *D = env[@"SIMRUN_DATA"] ?: [RealHome() stringByAppendingPathComponent:@"Library/Developer/SimRun/data"];
  for (NSString *sub in @[ @"tmp", @"Library/Preferences", @"Documents" ])
    [NSFileManager.defaultManager createDirectoryAtPath:[D stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:nil];
  NSDictionary *sv = [NSDictionary dictionaryWithContentsOfFile:[R stringByAppendingPathComponent:@"System/Library/CoreServices/SystemVersion.plist"]];
  return @{
    @"DYLD_ROOT_PATH": R, @"IPHONE_SIMULATOR_ROOT": R, @"SIMULATOR_ROOT": R,
    @"DYLD_SHARED_CACHE_DIR": [R stringByAppendingPathComponent:@"System/Library/Caches/com.apple.dyld"],
    @"DYLD_FALLBACK_FRAMEWORK_PATH": [R stringByAppendingPathComponent:@"System/Library/Frameworks"],
    @"DYLD_FALLBACK_LIBRARY_PATH": [R stringByAppendingPathComponent:@"usr/lib"],
    @"HOME": D, @"CFFIXED_USER_HOME": D, @"TMPDIR": [D stringByAppendingString:@"/tmp/"],
    @"IPHONE_SHARED_RESOURCES_DIRECTORY": D, @"SIMULATOR_SHARED_RESOURCES_DIRECTORY": D,
    @"SIMULATOR_HOST_HOME": env[@"SIMRUN_HOST_HOME"] ?: RealHome(),
    @"SIMULATOR_RUNTIME_VERSION": sv[@"ProductVersion"] ?: @"", @"SIMULATOR_RUNTIME_BUILD_VERSION": sv[@"ProductBuildVersion"] ?: @"",
    @"SIMULATOR_ARCHS": @"arm64",
    @"SIMULATOR_DEVICE_NAME": @"SimRun", @"SIMULATOR_MODEL_IDENTIFIER": @"iPhone19,4", @"SIMULATOR_PRODUCT_CLASS": @"V68",
    @"SIMULATOR_CAPABILITIES": @"/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype/Contents/Resources/capabilities.plist",
    @"SIMULATOR_MAINSCREEN_WIDTH": env[@"SIMRUN_W"] ?: @"1206", @"SIMULATOR_MAINSCREEN_HEIGHT": env[@"SIMRUN_H"] ?: @"2622",
    @"SIMULATOR_MAINSCREEN_SCALE": env[@"SIMRUN_SCALE"] ?: @"3.000000", @"SIMULATOR_MAINSCREEN_PITCH": @"460.000000",
    @"SIMULATOR_UDID": @"00000000-0000-0000-0000-000000000000", @"SIMULATOR_LEGACY_ASSET_SUFFIX": @"iphone",
    @"SIMULATOR_BOOT_TIME": [NSString stringWithFormat:@"%ld", (long)time(NULL)],
    @"XPC_FLAGS": @"0x0", @"LS_ENABLE_BUNDLE_LOCALIZATION_CACHING": @"1",
  };
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
  for (NSString *n in @[ @"rshim.dylib", @"glue.dylib", @"scenes.dylib", @"hid.dylib", @"pboard.dylib", @"drag.dylib" ]) [libs addObject:[d stringByAppendingPathComponent:n]];
  NSString *extra = NSProcessInfo.processInfo.environment[@"SIMAPP_EXTRA_INSERT"];
  if (extra.length) [libs addObject:extra];
  return [libs componentsJoinedByString:@":"];
}
+ (NSString *)framebufferFramework { return [[self libraryDirectory] stringByAppendingPathComponent:@"SimFramebuffer"]; }
@end
