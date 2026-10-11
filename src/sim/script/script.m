// script.dylib — runs JavaScript inside the app, on its main thread, for `simrun eval` (see scripting.md).
//
// SimRun sends a script over the app's session channel (protocol.h, SR_MSG_SCRIPT_*); console output and then the
// result or exception go back as they happen. JavaScriptCore isn't linked: it is loaded on the first script, so apps
// that never run one don't pay for it. Likewise UIKit's accessibility support, on the first ax.* call.
//
// Each script is the body of an async function (so `await` works at top level); an expression's value is the result.
// It runs on the main thread in one JSContext per process, so globals (globalThis.x = …) survive between scripts.
// Globals: console.log/error (per script), sleep(ms), setTimeout(fn, ms), tap(x, y), type(text), tapOn(query),
// views(), ax.tree({all}), ax.elements(), ax.find(query), ax.enable() (the ax functions call it themselves),
// objc(target, "sel:", …args) (target: object or class name), cls(name), desc(obj), methods(class, filter),
// classes(filter).
//
// Env: SCRIPT_DISABLE (no scripts: SimRun is never told the script port), SCRIPT_VERBOSE (log timings to stderr).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <JavaScriptCore/JavaScriptCore.h>   // classes are looked up at runtime: JavaScriptCore isn't linked
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include "protocol.h"

#define LOG(fmt, ...) fprintf(stderr, "[script] " fmt "\n", ##__VA_ARGS__)
static int gVerbose;
#define VLOG(fmt, ...) do { if (gVerbose) LOG(fmt, ##__VA_ARGS__); } while (0)

static double SRNowMS(void) {
  static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

// ---------------------------------------------------------------- JS <-> ObjC (just enough to explore)
@protocol SRJSContextClass
+ (JSContext *)currentContext;
+ (NSArray<JSValue *> *)currentArguments;
@end
static JSContext *SRCurrentContext(void) { return [(Class<SRJSContextClass>)NSClassFromString(@"JSContext") currentContext]; }
static NSArray<JSValue *> *SRCurrentArguments(void) { return [(Class<SRJSContextClass>)NSClassFromString(@"JSContext") currentArguments]; }
static JSValue *SRThrow(NSString *msg) {
  JSContext *c = SRCurrentContext();
  c.exception = [NSClassFromString(@"JSValue") valueWithNewErrorFromMessage:msg inContext:c];
  return [NSClassFromString(@"JSValue") valueWithUndefinedInContext:c];
}
static const char *SRSkipQualifiers(const char *t) { while (*t && strchr("rnNoORV", *t)) t++; return t; }

static BOOL SRSetArg(NSInvocation *inv, NSUInteger i, JSValue *v) {
  const char *t = SRSkipQualifiers([inv.methodSignature getArgumentTypeAtIndex:i]);
  switch (*t) {
    case '@': case '#': { __unsafe_unretained id o = v.isNull || v.isUndefined ? nil : [v toObject]; [inv setArgument:&o atIndex:i]; return YES; }
    case ':': { SEL s = NSSelectorFromString([v toString]); [inv setArgument:&s atIndex:i]; return YES; }
    case 'B': { bool b = [v toBool]; [inv setArgument:&b atIndex:i]; return YES; }
    case 'c': case 'C': { char c = (char)[v toInt32]; [inv setArgument:&c atIndex:i]; return YES; }
    case 's': case 'S': { short s = (short)[v toInt32]; [inv setArgument:&s atIndex:i]; return YES; }
    case 'i': case 'I': { int n = [v toInt32]; [inv setArgument:&n atIndex:i]; return YES; }
    case 'l': case 'L': case 'q': case 'Q': { long long n = (long long)[v toDouble]; [inv setArgument:&n atIndex:i]; return YES; }
    case 'f': { float f = (float)[v toDouble]; [inv setArgument:&f atIndex:i]; return YES; }
    case 'd': { double d = [v toDouble]; [inv setArgument:&d atIndex:i]; return YES; }
    case '{':
      if (!strncmp(t, "{CGPoint=", 9)) { CGPoint p = [v toPoint]; [inv setArgument:&p atIndex:i]; return YES; }
      if (!strncmp(t, "{CGSize=", 8)) { CGSize s = [v toSize]; [inv setArgument:&s atIndex:i]; return YES; }
      if (!strncmp(t, "{CGRect=", 8)) { CGRect r = [v toRect]; [inv setArgument:&r atIndex:i]; return YES; }
  }
  return NO;
}

static JSValue *SRReturnValue(NSInvocation *inv, JSContext *c) {
  Class V = NSClassFromString(@"JSValue");
  const char *t = SRSkipQualifiers(inv.methodSignature.methodReturnType);
  #define RET(type) ({ type x; [inv getReturnValue:&x]; x; })
  switch (*t) {
    case 'v': return [V valueWithUndefinedInContext:c];
    case '@': case '#': { __unsafe_unretained id o = nil; [inv getReturnValue:&o]; return o ? [V valueWithObject:o inContext:c] : [V valueWithNullInContext:c]; }
    case ':': return [V valueWithObject:NSStringFromSelector(RET(SEL)) inContext:c];
    case 'B': return [V valueWithBool:RET(bool) inContext:c];
    case 'c': return [V valueWithBool:RET(char) != 0 inContext:c];
    case 'C': return [V valueWithUInt32:RET(unsigned char) inContext:c];
    case 's': return [V valueWithInt32:RET(short) inContext:c];
    case 'S': return [V valueWithUInt32:RET(unsigned short) inContext:c];
    case 'i': return [V valueWithInt32:RET(int) inContext:c];
    case 'I': return [V valueWithUInt32:RET(unsigned) inContext:c];
    case 'l': case 'q': return [V valueWithDouble:(double)RET(long long) inContext:c];
    case 'L': case 'Q': return [V valueWithDouble:(double)RET(unsigned long long) inContext:c];
    case 'f': return [V valueWithDouble:RET(float) inContext:c];
    case 'd': return [V valueWithDouble:RET(double) inContext:c];
    case '{':
      if (!strncmp(t, "{CGPoint=", 9)) return [V valueWithPoint:RET(CGPoint) inContext:c];
      if (!strncmp(t, "{CGSize=", 8)) return [V valueWithSize:RET(CGSize) inContext:c];
      if (!strncmp(t, "{CGRect=", 8)) return [V valueWithRect:RET(CGRect) inContext:c];
  }
  #undef RET
  return SRThrow([NSString stringWithFormat:@"unsupported return type %s", t]);
}

// objc(target, "selector:with:", ...args): target is an object from an earlier call, or a class name.
static JSValue *SRObjCCall(void) {
  NSArray<JSValue *> *a = SRCurrentArguments();
  if (a.count < 2) return SRThrow(@"objc(target, selector, ...args)");
  id target = a[0].isString ? NSClassFromString([a[0] toString]) : [a[0] toObject];
  if (!target) return SRThrow([NSString stringWithFormat:@"no target %@", [a[0] toString]]);
  SEL sel = NSSelectorFromString([a[1] toString]);
  NSMethodSignature *sig = [target methodSignatureForSelector:sel];
  if (!sig) return SRThrow([NSString stringWithFormat:@"%@ doesn't respond to %@", [target class], [a[1] toString]]);
  if (a.count - 2 != sig.numberOfArguments - 2) return SRThrow([NSString stringWithFormat:@"%@ takes %lu arguments", [a[1] toString], (unsigned long)sig.numberOfArguments - 2]);
  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  inv.target = target; inv.selector = sel;
  for (NSUInteger i = 2; i < sig.numberOfArguments; i++)
    if (!SRSetArg(inv, i, a[i])) return SRThrow([NSString stringWithFormat:@"unsupported argument type %s", [sig getArgumentTypeAtIndex:i]]);
  [inv invoke];
  return SRReturnValue(inv, SRCurrentContext());
}

// ---------------------------------------------------------------- dumps
static UIWindowScene *SRActiveScene(void) {
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
    if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
  return nil;
}
static NSArray<UIWindow *> *SRWindows(void) {
  return [SRActiveScene().windows sortedArrayUsingComparator:^NSComparisonResult(UIWindow *x, UIWindow *y) {
    return x.windowLevel < y.windowLevel ? NSOrderedAscending : x.windowLevel > y.windowLevel ? NSOrderedDescending : NSOrderedSame;
  }];
}
static NSString *SRRect(CGRect r) { return [NSString stringWithFormat:@"(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height]; }

static void SRDumpView(UIView *v, int depth, NSMutableString *out) {
  if (v.hidden || v.alpha == 0) return;
  [out appendFormat:@"%*s%@ %@", depth * 2, "", NSStringFromClass(v.class), SRRect([v convertRect:v.bounds toView:nil])];
  if (v.accessibilityIdentifier.length) [out appendFormat:@" id=%@", v.accessibilityIdentifier];
  if (v.isAccessibilityElement && v.accessibilityLabel.length) [out appendFormat:@" label=%@", v.accessibilityLabel];
  [out appendString:@"\n"];
  for (UIView *s in v.subviews) SRDumpView(s, depth + 1, out);
}

static NSString *SRTraits(UIAccessibilityTraits t) {
  static const struct { UIAccessibilityTraits bit; const char *name; } names[] = {
    { 1 << 0, "button" }, { 1 << 1, "link" }, { 1 << 2, "image" }, { 1 << 3, "selected" }, { 1 << 6, "text" },
    { 1 << 8, "notEnabled" }, { 1 << 10, "searchField" }, { 1 << 12, "adjustable" }, { 1 << 16, "header" },
    { 1 << 18, "textEntry" }, { 1 << 28, "tabBar" }, { 1ull << 53, "toggle" },
  };
  NSMutableArray *r = [NSMutableArray array];
  UIAccessibilityTraits known = 0;
  for (size_t i = 0; i < sizeof names / sizeof *names; i++) { known |= names[i].bit; if (t & names[i].bit) [r addObject:@(names[i].name)]; }
  if (t & ~known) [r addObject:[NSString stringWithFormat:@"0x%llx", (unsigned long long)(t & ~known)]];
  return [r componentsJoinedByString:@","];
}

// What an AX client sees: elements (isAccessibilityElement), found through accessibilityElements /
// accessibilityElementAtIndex: on containers, else subviews. all: also print the containers on the way.
// out (text) and/or list (one dictionary per element) may be nil.
static void SRDumpAX(id e, int depth, BOOL all, NSMutableString *out, NSMutableArray *list) {
  if ([e accessibilityElementsHidden]) return;
  if ([e isKindOfClass:UIView.class] && (((UIView *)e).hidden || ((UIView *)e).alpha == 0)) return;
  BOOL leaf = [e isAccessibilityElement];
  if (leaf) {
    NSString *label = [e accessibilityLabel], *value = [e accessibilityValue];
    NSString *ident = [e respondsToSelector:@selector(accessibilityIdentifier)] ? [e accessibilityIdentifier] : nil;
    NSString *traits = SRTraits([e accessibilityTraits]);
    CGRect f = [e accessibilityFrame];
    [list addObject:@{ @"label": label ?: @"", @"value": value ?: @"", @"id": ident ?: @"", @"traits": traits, @"class": NSStringFromClass([e class]),
                       @"frame": @{ @"x": @(f.origin.x), @"y": @(f.origin.y), @"width": @(f.size.width), @"height": @(f.size.height) } }];
    [out appendFormat:@"%*s%@", depth * 2, "", NSStringFromClass([e class])];
    if (traits.length) [out appendFormat:@" [%@]", traits];
    if (label.length) [out appendFormat:@" \"%@\"", label];
    if (value.length) [out appendFormat:@" value=\"%@\"", value];
    if (ident.length) [out appendFormat:@" id=%@", ident];
    [out appendFormat:@" %@\n", SRRect(f)];
  } else if (all) [out appendFormat:@"%*s- %@\n", depth * 2, "", NSStringFromClass([e class])];
  NSArray *kids = [e accessibilityElements];
  if (!kids) {
    NSInteger n = [e accessibilityElementCount];
    if (n != NSNotFound && n > 0) {
      NSMutableArray *m = [NSMutableArray array];
      for (NSInteger i = 0; i < n; i++) { id k = [e accessibilityElementAtIndex:i]; if (k) [m addObject:k]; }
      kids = m;
    } else if ([e isKindOfClass:UIView.class]) kids = ((UIView *)e).subviews;
  }
  for (id k in kids) SRDumpAX(k, depth + (leaf || all ? 1 : 0), all, out, list);
}

// UIKit loads its accessibility support (the AX bundles; SwiftUI then builds its AccessibilityNode tree) at launch when
// the ApplicationAccessibilityEnabled setting is on, else never. Turn it on for a moment and have UIApplication
// re-read it. The setting is shared (com.apple.Accessibility preferences, every app reads it at launch), so it's turned
// back off right away; the loaded support stays.
static void SREnsureAX(void) {
  static BOOL done;
  if (done) return;
  done = YES;
  int (*get)(void) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilityEnabled");
  void (*set)(int) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
  if (!get || !set) { LOG("no _AXSApplicationAccessibility* functions"); return; }
  double t = SRNowMS();
  BOOL was = get() != 0;
  if (!was) set(1);
  #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  [UIApplication.sharedApplication performSelector:NSSelectorFromString(@"_updateApplicationAccessibility")];
  if (!was) set(0);
  VLOG("accessibility loaded in %.1f ms", SRNowMS() - t);
}

// ---------------------------------------------------------------- the context
static JSContext *gContext;
static JSValue *gLastException;

static NSString *const kPrelude = @
  "globalThis.__fmt = function (v) {\n"
  "  if (v === undefined) return '';\n"
  "  if (typeof v === 'string') return v;\n"
  "  try { const s = JSON.stringify(v, null, 2); if (s !== undefined) return s; } catch (e) {}\n"
  "  return String(v);\n"
  "};\n"
  // what an exception says: the error and where it came from in the script (frames in "script.js"), or what was thrown
  "globalThis.__error = e => {\n"
  "  if (!(e instanceof Error)) return `Uncaught ${__fmt(e)}`;\n"
  // (columns on line 1 count the wrapper in front of the script: __prefix characters)
  "  const at = (l, c) => `script.js:${l}` + (c === undefined ? '' : `:${l == 1 ? c - __prefix : c}`);\n"
  "  const frames = String(e.stack || '').split('\\n').map(f => f.match(/^(.*?)@?script\\.js:(\\d+):(\\d+)$/)).filter(m => m)\n"
  "    .map(([, fn, l, c]) => `    at ${fn ? `${fn} (${at(l, +c)})` : at(l, +c)}`);\n"
  "  if (!frames.length && e.line && e.sourceURL === 'script.js') frames.push(`    at ${at(e.line, e.column)}`);\n"
  "  return [String(e), ...frames].join('\\n');\n"
  "};\n"
  "globalThis.sleep = ms => new Promise(r => setTimeout(r, ms));\n"
  // ax.find(q): the first element whose label contains q (a string) or matches q (a RegExp), or whose id is q.
  "ax.find = q => ax.elements().find(e => e.id === q || (typeof q === 'string' ? e.label.includes(q) : q.test(e.label)));\n"
  "globalThis.tapOn = async q => {\n"
  "  const e = ax.find(q);\n"
  "  if (!e) throw new Error(`no element matches ${q}`);\n"
  "  await tap(e.frame.x + e.frame.width / 2, e.frame.y + e.frame.height / 2);\n"
  "  return e;\n"
  "};\n";

static JSContext *SRContext(void) {
  if (gContext) return gContext;
  double t0 = SRNowMS();
  void *h = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW);
  double t1 = SRNowMS();
  if (!h) { LOG("dlopen JavaScriptCore: %s", dlerror()); return nil; }
  Class V = NSClassFromString(@"JSValue");
  JSContext *ctx = [NSClassFromString(@"JSContext") new];
  ctx.name = [NSString stringWithFormat:@"SimRun script (%s)", getprogname()];
  ctx.exceptionHandler = ^(JSContext *c, JSValue *e) { gLastException = e; };

  ctx[@"setTimeout"] = ^(JSValue *fn, double ms) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
      gLastException = nil;
      [fn callWithArguments:@[]];
      if (gLastException) { LOG("uncaught in a setTimeout callback: %s", [gLastException toString].UTF8String); gLastException = nil; }
    });
  };
  // tap(x, y): finger 0 down, up 60 ms later; resolves after the up.
  ctx[@"tap"] = ^JSValue *(double x, double y) {
    void (*touch)(int, float, float) = dlsym(RTLD_DEFAULT, "SRHIDTouch");
    if (!touch) return SRThrow(@"hid.dylib isn't loaded");
    return [V valueWithNewPromiseInContext:SRCurrentContext() fromExecutor:^(JSValue *resolve, JSValue *reject) {
      touch(1, x, y);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        touch(3, x, y);
        [resolve callWithArguments:@[]];
      });
    }];
  };
  // type(text): key presses for each character, into whatever has keyboard focus.
  ctx[@"type"] = ^JSValue *(NSString *text) {
    void (*typeText)(const char *) = dlsym(RTLD_DEFAULT, "SRHIDText");
    if (!typeText) return SRThrow(@"hid.dylib isn't loaded");
    typeText(text.UTF8String);
    return [V valueWithUndefinedInContext:SRCurrentContext()];
  };
  ctx[@"views"] = ^NSString *(void) {
    NSMutableString *out = [NSMutableString string];
    for (UIWindow *w in SRWindows()) SRDumpView(w, 0, out);
    return out;
  };
  ctx[@"ax"] = @{};
  ctx[@"ax"][@"enable"] = ^{ SREnsureAX(); };
  ctx[@"ax"][@"tree"] = ^NSString *(JSValue *opts) {
    SREnsureAX();
    BOOL all = opts.isObject && [opts[@"all"] toBool];
    NSMutableString *out = [NSMutableString string];
    NSMutableArray *list = [NSMutableArray array];
    double t = SRNowMS();
    for (UIWindow *w in SRWindows()) SRDumpAX(w, 0, all, out, list);
    [out appendFormat:@"(%lu elements, %.1f ms)", (unsigned long)list.count, SRNowMS() - t];
    return out;
  };
  ctx[@"ax"][@"elements"] = ^NSArray *(void) {
    SREnsureAX();
    NSMutableArray *list = [NSMutableArray array];
    for (UIWindow *w in SRWindows()) SRDumpAX(w, 0, NO, nil, list);
    return list;
  };
  ctx[@"objc"] = ^JSValue *(void) { return SRObjCCall(); };
  ctx[@"cls"] = ^JSValue *(NSString *name) {
    Class k = NSClassFromString(name);
    return k ? [V valueWithObject:k inContext:SRCurrentContext()] : [V valueWithNullInContext:SRCurrentContext()];
  };
  ctx[@"desc"] = ^NSString *(JSValue *v) { return [[v toObject] description]; };
  // methods(className, filter): "+sel" / "-sel" of the class itself (not its superclasses) containing filter.
  ctx[@"methods"] = ^NSArray *(NSString *name, JSValue *filter) {
    Class k = NSClassFromString(name);
    NSString *f = filter.isString ? [filter toString] : nil;
    NSMutableArray *r = [NSMutableArray array];
    for (int meta = 1; k && meta >= 0; meta--) {
      unsigned n = 0;
      Method *ms = class_copyMethodList(meta ? object_getClass(k) : k, &n);
      for (unsigned i = 0; i < n; i++) {
        NSString *s = NSStringFromSelector(method_getName(ms[i]));
        if (!f || [s rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound) [r addObject:[(meta ? @"+" : @"-") stringByAppendingString:s]];
      }
      free(ms);
    }
    return r;
  };
  // classes(filter): names of loaded classes containing filter.
  ctx[@"classes"] = ^NSArray *(NSString *f) {
    unsigned n = 0;
    Class *cs = objc_copyClassList(&n);
    NSMutableArray *r = [NSMutableArray array];
    for (unsigned i = 0; i < n; i++) { NSString *s = NSStringFromClass(cs[i]); if ([s rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound) [r addObject:s]; }
    free(cs);
    return [r sortedArrayUsingSelector:@selector(compare:)];
  };
  [ctx evaluateScript:kPrelude];
  if (gLastException) { LOG("prelude: %s", [gLastException toString].UTF8String); gLastException = nil; }
  VLOG("JavaScriptCore loaded in %.1f ms, context ready in %.1f ms", t1 - t0, SRNowMS() - t0);
  return gContext = ctx;
}

// Runs src on the main thread. emit(kind, text) gets each console line (SR_SCRIPT_LOG), then one SR_SCRIPT_RESULT or
// SR_SCRIPT_EXCEPTION once the script's promise settles; console output after that goes to stderr.
static void SREval(NSString *src, void (^emit)(uint32_t kind, NSString *text)) {
  JSContext *ctx = SRContext();
  if (!ctx) { emit(SR_SCRIPT_EXCEPTION, @"JavaScriptCore didn't load"); return; }
  __block BOOL settled = NO;
  JSValue *console = [NSClassFromString(@"JSValue") valueWithNewObjectInContext:ctx];
  void (^log)(void) = ^{
    NSMutableArray *parts = [NSMutableArray array];
    for (JSValue *v in SRCurrentArguments()) [parts addObject:[[ctx[@"__fmt"] callWithArguments:@[ v ]] toString]];
    NSString *line = [parts componentsJoinedByString:@" "];
    if (settled) LOG("console (after its script finished): %s", line.UTF8String); else emit(SR_SCRIPT_LOG, line);
  };
  console[@"log"] = log; console[@"error"] = log;
  double t0 = SRNowMS();
  void (^finish)(uint32_t, NSString *) = ^(uint32_t kind, NSString *text) {
    if (settled) return;
    settled = YES;
    VLOG("script took %.1f ms", SRNowMS() - t0);
    emit(kind, text);
  };
  // The script is the body of an async function: as `return (<script>)` when it is an expression (its value is the
  // result), else as statements. Compiling only defines the function, so trying both has no side effects. The
  // wrapper starts on the script's first line, so line numbers in errors are the script's.
  NSURL *url = [NSURL URLWithString:@"script.js"];
  NSString *head = @"(async function (console) { return (";
  gLastException = nil;
  JSValue *fn = [ctx evaluateScript:[NSString stringWithFormat:@"%@%@\n) })", head, src] withSourceURL:url];
  if (gLastException) {
    gLastException = nil;
    head = @"(async function (console) { ";
    fn = [ctx evaluateScript:[NSString stringWithFormat:@"%@%@\n})", head, src] withSourceURL:url];
  }
  ctx[@"__prefix"] = @(head.length);
  JSValue *p = gLastException ? nil : [fn callWithArguments:@[ console ]];
  if (gLastException) {   // a syntax error (an async function never throws when called)
    JSValue *e = gLastException;
    gLastException = nil;
    finish(SR_SCRIPT_EXCEPTION, [[ctx[@"__error"] callWithArguments:@[ e ]] toString]);
    return;
  }
  [p invokeMethod:@"then" withArguments:@[
    ^(JSValue *v) { finish(SR_SCRIPT_RESULT, [[ctx[@"__fmt"] callWithArguments:@[ v ]] toString]); },
    ^(JSValue *e) { finish(SR_SCRIPT_EXCEPTION, [[ctx[@"__error"] callWithArguments:@[ e ]] toString]); },
  ]];
}

// ---------------------------------------------------------------- SimRun channel (protocol.h, SR_MSG_SCRIPT_*)
static mach_port_t gScriptPort;

static void SRSendOutput(mach_port_t reply, uint32_t kind, NSString *text) {
  NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  sr_script_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  m.h.msgh_size = sizeof m; m.h.msgh_remote_port = reply; m.h.msgh_id = SR_MSG_SCRIPT_OUTPUT;
  m.b.msgh_descriptor_count = 1;
  m.data.address = (void *)d.bytes; m.data.size = (mach_msg_size_t)d.length;
  m.data.deallocate = FALSE; m.data.copy = MACH_MSG_VIRTUAL_COPY; m.data.type = MACH_MSG_OOL_DESCRIPTOR;
  m.kind = kind;
  // SimRun drains replies off its main thread; the timeout only guards against a SimRun that stopped reading
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 5000, MACH_PORT_NULL);
  if (kr != KERN_SUCCESS) LOG("couldn't send script output (kind %u): 0x%x", kind, kr);
}

static void SRReceive(void) {
  union { sr_script_msg_t m; char buf[sizeof(sr_script_msg_t) + MAX_TRAILER_SIZE]; } u;
  while (mach_msg(&u.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof u, gScriptPort, 0, MACH_PORT_NULL) == KERN_SUCCESS) {
    mach_msg_header_t *h = &u.m.h;
    if (h->msgh_id != SR_MSG_SCRIPT_EVAL || !(h->msgh_bits & MACH_MSGH_BITS_COMPLEX) || h->msgh_size < sizeof u.m ||
        u.m.b.msgh_descriptor_count != 1 || u.m.data.type != MACH_MSG_OOL_DESCRIPTOR || !MACH_PORT_VALID(h->msgh_remote_port)) {
      mach_msg_destroy(h);
      continue;
    }
    NSString *src = [[NSString alloc] initWithBytes:u.m.data.address length:u.m.data.size encoding:NSUTF8StringEncoding] ?: @"";
    if (u.m.data.size) vm_deallocate(mach_task_self(), (vm_address_t)u.m.data.address, u.m.data.size);
    mach_port_t reply = h->msgh_remote_port;   // our send right for this script's output
    dispatch_async(dispatch_get_main_queue(), ^{
      SREval(src, ^(uint32_t kind, NSString *text) {
        SRSendOutput(reply, kind, text);
        if (kind != SR_SCRIPT_LOG) mach_port_deallocate(mach_task_self(), reply);
      });
    });
  }
}

// Says hello to SimRun with our script port, as hid.dylib does with its input port. Only apps are given script.dylib
// (the helper processes they spawn get rshim.dylib and webkit.dylib), so nothing else says hello in their place.
__attribute__((constructor)) static void SRScriptInit(void) {
  gVerbose = getenv("SCRIPT_VERBOSE") != NULL;
  if (getenv("SCRIPT_DISABLE")) { VLOG("SCRIPT_DISABLE: scripts can't be run"); return; }
  mach_port_array_t ports = NULL; mach_msg_type_number_t n = 0;
  mach_port_t host = MACH_PORT_NULL;
  if (mach_ports_lookup(mach_task_self(), &ports, &n) == KERN_SUCCESS && n > SR_PORT_SLOT_HOST) host = ports[SR_PORT_SLOT_HOST];
  if (!MACH_PORT_VALID(host)) { VLOG("no host port: scripts can't be run"); return; }
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gScriptPort);
  dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, gScriptPort, 0, dispatch_queue_create("dev.simrun.script", DISPATCH_QUEUE_SERIAL));
  dispatch_source_set_event_handler(src, ^{ SRReceive(); });
  dispatch_resume(src);
  (void)CFBridgingRetain(src);
  sr_port_msg_t m = {0};
  m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  m.h.msgh_size = sizeof m; m.h.msgh_remote_port = host; m.h.msgh_id = SR_MSG_SCRIPT_HELLO;
  m.b.msgh_descriptor_count = 1;
  m.port.name = gScriptPort; m.port.disposition = MACH_MSG_TYPE_MAKE_SEND; m.port.type = MACH_MSG_PORT_DESCRIPTOR;
  kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
  VLOG("script port 0x%x, SR_MSG_SCRIPT_HELLO kr=0x%x", gScriptPort, kr);
}
