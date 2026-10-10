// launchoptions.m — see launchoptions.h.
#import "launchoptions.h"
#import "library.h"

static NSString *const kOptionsKey = @"SRLaunchOptions";   // { app path: { runtime, arguments, environment, switches } }

@implementation SRLaunchItem
@end

// Words of a command line as a shell splits them: whitespace separates, quotes group, a backslash escapes (not in '').
static NSArray<NSString *> *ShellWords(NSString *s) {
  NSMutableArray *words = [NSMutableArray array];
  NSMutableString *w = nil;
  unichar quote = 0;
  for (NSUInteger i = 0; i < s.length; i++) {
    unichar c = [s characterAtIndex:i];
    if (quote) {
      if (c == quote) quote = 0;
      else if (c == '\\' && quote == '"' && i + 1 < s.length) [w appendFormat:@"%C", [s characterAtIndex:++i]];
      else [w appendFormat:@"%C", c];
    } else if ([NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c]) {
      if (w) { [words addObject:w]; w = nil; }
    } else {
      if (!w) w = [NSMutableString string];
      if (c == '"' || c == '\'') quote = c;
      else if (c == '\\' && i + 1 < s.length) [w appendFormat:@"%C", [s characterAtIndex:++i]];
      else [w appendFormat:@"%C", c];
    }
  }
  if (w) [words addObject:w];
  return words;
}

@implementation SRLaunchOptions

- (instancetype)init {
  if ((self = [super init])) { _arguments = [NSMutableArray array]; _environment = [NSMutableArray array]; _switches = [NSMutableSet set]; }
  return self;
}

+ (NSDictionary *)allSaved {
  NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:kOptionsKey];
  return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

+ (instancetype)optionsForAppAtPath:(NSString *)path {
  SRLaunchOptions *o = [SRLaunchOptions new];
  NSDictionary *d = [self allSaved][path];
  if (![d isKindOfClass:NSDictionary.class]) return o;
  if ([d[@"runtime"] isKindOfClass:NSString.class]) o.runtimeBuild = d[@"runtime"];
  for (NSString *key in @[ @"arguments", @"environment" ]) {
    NSArray *items = [d[key] isKindOfClass:NSArray.class] ? d[key] : @[];
    for (NSDictionary *it in items) {
      if (![it isKindOfClass:NSDictionary.class]) continue;
      SRLaunchItem *i = [SRLaunchItem new];
      i.enabled = [it[@"enabled"] boolValue];
      i.name = [it[@"name"] isKindOfClass:NSString.class] ? it[@"name"] : @"";
      i.value = [it[@"value"] isKindOfClass:NSString.class] ? it[@"value"] : @"";
      [[key isEqualToString:@"arguments"] ? o.arguments : o.environment addObject:i];
    }
  }
  for (NSString *s in [d[@"switches"] isKindOfClass:NSArray.class] ? d[@"switches"] : @[])
    if ([s isKindOfClass:NSString.class]) [o.switches addObject:s];
  return o;
}

+ (void)store:(NSDictionary *)d forPath:(NSString *)path {
  NSMutableDictionary *all = [[self allSaved] mutableCopy];
  if (d) all[path] = d; else [all removeObjectForKey:path];
  [NSUserDefaults.standardUserDefaults setObject:all forKey:kOptionsKey];
}
+ (void)removeOptionsForAppAtPath:(NSString *)path { [self store:nil forPath:path]; }

- (void)saveForAppAtPath:(NSString *)path {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  if (_runtimeBuild) d[@"runtime"] = _runtimeBuild;
  NSMutableArray *args = [NSMutableArray array], *env = [NSMutableArray array];
  for (SRLaunchItem *i in _arguments) if (i.value.length) [args addObject:@{ @"enabled": @(i.enabled), @"value": i.value }];
  for (SRLaunchItem *i in _environment)
    if (i.name.length) [env addObject:@{ @"enabled": @(i.enabled), @"name": i.name, @"value": i.value ?: @"" }];
  if (args.count) d[@"arguments"] = args;
  if (env.count) d[@"environment"] = env;
  if (_switches.count) d[@"switches"] = [_switches.allObjects sortedArrayUsingSelector:@selector(compare:)];
  [SRLaunchOptions store:d.count ? d : nil forPath:path];
  [NSNotificationCenter.defaultCenter postNotificationName:SRLibraryDidChangeNotification object:nil];
}

- (NSArray<NSString *> *)launchArguments {
  NSMutableArray *out = [NSMutableArray array];
  for (SRLaunchItem *i in _arguments) if (i.enabled) [out addObjectsFromArray:ShellWords(i.value ?: @"")];
  return out;
}

- (NSDictionary<NSString *, NSString *> *)environmentVariables {
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSString *s in _switches) out[s] = @"1";
  for (SRLaunchItem *i in _environment) if (i.enabled && i.name.length) out[i.name] = i.value ?: @"";
  return out;
}
@end
