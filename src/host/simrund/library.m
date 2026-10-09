// library.m — see library.h.
#import "library.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <pwd.h>
#include <dlfcn.h>

// CoreUI (private): reads compiled asset catalogs (Assets.car), including iOS ones, on macOS.
@interface CUICatalog : NSObject
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (id)iconImageWithName:(NSString *)name scaleFactor:(double)scale deviceIdiom:(long long)idiom deviceSubtype:(unsigned long long)subtype
           displayGamut:(long long)gamut layoutDirection:(long long)dir sizeClassHorizontal:(long long)h sizeClassVertical:(long long)v
            desiredSize:(CGSize)size appearanceName:(NSString *)appearance;
@end

NSNotificationName const SRLibraryDidChangeNotification = @"SRLibraryDidChange";
static NSString *const kLibraryKey = @"SRLibraryPaths";

// Platform (LC_BUILD_VERSION) of the arm64 slice of a Mach-O, or 0.
static uint32_t Arm64Platform(NSString *path) {
  NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  if (d.length < sizeof(struct mach_header_64)) return 0;
  const uint8_t *p = d.bytes; size_t off = 0;
  uint32_t magic = *(const uint32_t *)p;
  if (magic == FAT_CIGAM || magic == FAT_MAGIC) {   // fat: find the arm64 slice
    const struct fat_header *fh = (const void *)p;
    uint32_t n = OSSwapBigToHostInt32(fh->nfat_arch);
    const struct fat_arch *fa = (const void *)(fh + 1);
    off = SIZE_MAX;
    for (uint32_t i = 0; i < n && (const uint8_t *)(fa + i + 1) <= p + d.length; i++)
      if ((cpu_type_t)OSSwapBigToHostInt32(fa[i].cputype) == CPU_TYPE_ARM64) off = OSSwapBigToHostInt32(fa[i].offset);
    if (off == SIZE_MAX || off + sizeof(struct mach_header_64) > d.length) return 0;
  }
  const struct mach_header_64 *mh = (const void *)(p + off);
  if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) return 0;
  const uint8_t *lc = (const uint8_t *)(mh + 1), *end = p + d.length;
  for (uint32_t i = 0; i < mh->ncmds && lc + sizeof(struct load_command) <= end; i++) {
    const struct load_command *c = (const void *)lc;
    if (c->cmd == LC_BUILD_VERSION) return ((const struct build_version_command *)c)->platform;
    if (c->cmd == LC_VERSION_MIN_IPHONEOS) return PLATFORM_IOSSIMULATOR;   // old binaries; sim vs device unknown
    lc += c->cmdsize;
  }
  return 0;
}

@implementation SRAppInfo

+ (NSString *)problemWithAppAtPath:(NSString *)path {
  if (![path.pathExtension isEqualToString:@"app"]) return @"Not an app bundle.";
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
  if (!info) return @"This doesn't look like an iOS app: it has no top-level Info.plist (macOS apps keep it in Contents/).";
  NSString *exe = info[@"CFBundleExecutable"];
  if (!exe.length) return @"Info.plist has no CFBundleExecutable.";
  switch (Arm64Platform([path stringByAppendingPathComponent:exe])) {
    case PLATFORM_IOSSIMULATOR: return nil;
    case PLATFORM_IOS: return @"This is a build for iPhone/iPad devices. Build it for an iOS Simulator destination instead.";
    case 0: return @"The executable has no arm64 slice (SimRun needs an arm64 iOS Simulator build).";
    default: return @"The executable isn't built for the iOS Simulator.";
  }
}

+ (instancetype)infoWithPath:(NSString *)path {
  SRAppInfo *a = [SRAppInfo new];
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
  a->_path = path;
  a->_name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: path.lastPathComponent.stringByDeletingPathExtension;
  a->_bundleIdentifier = info[@"CFBundleIdentifier"] ?: @"";
  a->_executablePath = [path stringByAppendingPathComponent:info[@"CFBundleExecutable"] ?: @""];
  a->_icon = [self iconForBundle:path info:info];
  return a;
}

// The app icon, best source first: the asset catalog (Assets.car, full resolution, light + dark variants), then the
// PNG files listed in Info.plist, then a generic icon. iOS icons are full-bleed squares, so they get iOS's rounded mask.
+ (NSImage *)iconForBundle:(NSString *)path info:(NSDictionary *)info {
  NSDictionary *primary = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"] ?: info[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"];
  NSString *iconName = [primary isKindOfClass:NSDictionary.class] ? primary[@"CFBundleIconName"] : nil;
  NSImage *img = [self catalogIcon:[path stringByAppendingPathComponent:@"Assets.car"] name:iconName ?: @"AppIcon"];
  if (!img) img = [self pngIconInBundle:path info:info];
  if (!img) return [NSWorkspace.sharedWorkspace iconForContentType:UTTypeApplicationBundle];
  return img;
}

static CGImageRef CatalogIconImage(CUICatalog *cat, NSString *name, NSString *appearance) {
  for (long long idiom = 1; idiom <= 2; idiom++) {   // phone, then pad
    id named = [cat iconImageWithName:name scaleFactor:1 deviceIdiom:idiom deviceSubtype:0 displayGamut:0 layoutDirection:0
                  sizeClassHorizontal:0 sizeClassVertical:0 desiredSize:CGSizeMake(1024, 1024) appearanceName:appearance];
    CGImageRef cg = [named respondsToSelector:@selector(image)] ? (__bridge CGImageRef)[named performSelector:@selector(image)] : NULL;
    if (cg) return CGImageRetain(cg);
  }
  return NULL;
}

+ (NSImage *)catalogIcon:(NSString *)carPath name:(NSString *)name {
  static dispatch_once_t once; dispatch_once(&once, ^{ dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_LAZY); });
  Class C = NSClassFromString(@"CUICatalog");
  if (!C || ![NSFileManager.defaultManager fileExistsAtPath:carPath]) return nil;
  CUICatalog *cat = [[C alloc] initWithURL:[NSURL fileURLWithPath:carPath] error:nil];
  if (![cat respondsToSelector:@selector(iconImageWithName:scaleFactor:deviceIdiom:deviceSubtype:displayGamut:layoutDirection:sizeClassHorizontal:sizeClassVertical:desiredSize:appearanceName:)]) return nil;
  CGImageRef light = CatalogIconImage(cat, name, nil);
  if (!light) return nil;
  CGImageRef dark = CatalogIconImage(cat, name, @"UIAppearanceDark");
  NSImage *masked = [self roundedIconFrom:light dark:dark];
  CGImageRelease(light); if (dark) CGImageRelease(dark);
  return masked;
}

+ (NSImage *)pngIconInBundle:(NSString *)path info:(NSDictionary *)info {
  NSMutableArray *names = [NSMutableArray array];
  for (NSString *k in @[ @"CFBundleIcons", @"CFBundleIcons~ipad" ]) {
    NSArray *f = info[k][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
    if ([f isKindOfClass:NSArray.class]) [names addObjectsFromArray:f];
  }
  if ([info[@"CFBundleIconFiles"] isKindOfClass:NSArray.class]) [names addObjectsFromArray:info[@"CFBundleIconFiles"]];
  if ([info[@"CFBundleIconFile"] isKindOfClass:NSString.class]) [names addObject:info[@"CFBundleIconFile"]];
  CGImageRef best = NULL; size_t bestW = 0;
  NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil];
  for (NSString *n in names)
    for (NSString *f in files) {
      if (![f hasPrefix:n.stringByDeletingPathExtension] || ![f.pathExtension isEqualToString:@"png"]) continue;
      NSImage *img = [[NSImage alloc] initWithContentsOfFile:[path stringByAppendingPathComponent:f]];
      CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
      if (cg && CGImageGetWidth(cg) > bestW) { if (best) CGImageRelease(best); best = CGImageRetain(cg); bestW = CGImageGetWidth(cg); }
    }
  if (!best) return nil;
  NSImage *img = [self roundedIconFrom:best dark:NULL];
  CGImageRelease(best);
  return img;
}

// An NSImage that draws `light` (or `dark` under a dark appearance) clipped to iOS's rounded icon shape.
+ (NSImage *)roundedIconFrom:(CGImageRef)light dark:(CGImageRef)dark {
  id l = (__bridge id)light, d = dark ? (__bridge id)dark : nil;
  return [NSImage imageWithSize:NSMakeSize(64, 64) flipped:NO drawingHandler:^BOOL(NSRect r) {
    BOOL isDark = d && [[NSAppearance.currentDrawingAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
                        isEqualToString:NSAppearanceNameDarkAqua];
    CGImageRef img = (__bridge CGImageRef)(isDark ? d : l);
    CGFloat radius = r.size.width * 0.2237;   // iOS app icon corner radius
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] addClip];
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, NSRectToCGRect(r), img);
    return YES;
  }];
}
@end

@implementation SRLibrary { NSMutableArray<SRAppInfo *> *_apps; }

+ (instancetype)shared { static SRLibrary *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [SRLibrary new]; }); return s; }

- (instancetype)init {
  if ((self = [super init])) {
    _apps = [NSMutableArray array];
    for (NSString *p in [NSUserDefaults.standardUserDefaults stringArrayForKey:kLibraryKey])
      if ([NSFileManager.defaultManager fileExistsAtPath:p]) [_apps addObject:[SRAppInfo infoWithPath:p]];
  }
  return self;
}
- (NSArray<SRAppInfo *> *)apps { return _apps; }
- (void)save {
  [NSUserDefaults.standardUserDefaults setObject:[_apps valueForKey:@"path"] forKey:kLibraryKey];
  [NSNotificationCenter.defaultCenter postNotificationName:SRLibraryDidChangeNotification object:self];
}
- (SRAppInfo *)addPath:(NSString *)path {
  path = path.stringByStandardizingPath;
  for (SRAppInfo *a in _apps) if ([a.path isEqualToString:path]) return a;
  SRAppInfo *a = [SRAppInfo infoWithPath:path];
  [_apps addObject:a];
  [_apps sortUsingComparator:^NSComparisonResult(SRAppInfo *x, SRAppInfo *y) { return [x.name localizedCaseInsensitiveCompare:y.name]; }];
  [self save];
  return a;
}
- (void)removePath:(NSString *)path {
  NSIndexSet *ix = [_apps indexesOfObjectsPassingTest:^BOOL(SRAppInfo *a, NSUInteger i, BOOL *stop) { return [a.path isEqualToString:path]; }];
  [_apps removeObjectsAtIndexes:ix];
  [self save];
}

+ (NSArray<NSString *> *)xcodeSimulatorBuilds {
  struct passwd *pw = getpwuid(getuid());
  NSString *dd = [@(pw ? pw->pw_dir : "~") stringByAppendingPathComponent:@"Library/Developer/Xcode/DerivedData"];
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *proj in [fm contentsOfDirectoryAtPath:dd error:nil]) {
    NSString *products = [dd stringByAppendingFormat:@"/%@/Build/Products", proj];
    for (NSString *cfg in [fm contentsOfDirectoryAtPath:products error:nil]) {
      if (![cfg hasSuffix:@"-iphonesimulator"]) continue;
      NSString *dir = [products stringByAppendingPathComponent:cfg];
      for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        NSString *p = [dir stringByAppendingPathComponent:f];
        if ([f.pathExtension isEqualToString:@"app"] && ![SRAppInfo problemWithAppAtPath:p]) [out addObject:p];
      }
    }
  }
  return out;
}
@end
