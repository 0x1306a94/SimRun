// filepanel.m — host side of the document picker bridge (see include/docpicker.h, docs/docpicker.md).
#import "filepanel.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <xpc/xpc.h>
#include <sys/stat.h>
#include "docpicker.h"

xpc_endpoint_t xpc_endpoint_create(xpc_connection_t);
mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
void xpc_connection_enable_sim2host_4sim(xpc_connection_t);   // sim clients speak the sim2host wire format (gpuhost.m)
pid_t xpc_connection_get_pid(xpc_connection_t);

static NSArray<NSString *> *Strings(xpc_object_t m, const char *key) {
  NSMutableArray *out = [NSMutableArray array];
  xpc_object_t a = xpc_dictionary_get_value(m, key);
  if (a && xpc_get_type(a) == XPC_TYPE_ARRAY)
    xpc_array_apply(a, ^bool(size_t i, xpc_object_t s) { if (xpc_get_type(s) == XPC_TYPE_STRING) [out addObject:@(xpc_string_get_string_ptr(s))]; return true; });
  return out;
}

// What an open panel may choose for the app's types: nil = any file. A type that stands for any file (public.item,
// public.data, public.content) means no filter; types the Mac doesn't know only count through their extensions.
static NSArray<UTType *> *AllowedTypes(NSArray<NSString *> *identifiers, NSArray<NSString *> *extensions) {
  NSMutableArray<UTType *> *types = [NSMutableArray array];
  for (NSString *i in identifiers) {
    UTType *t = [UTType typeWithIdentifier:i];
    if (!t || t.dynamic) continue;
    if ([t isEqual:UTTypeItem] || [t isEqual:UTTypeData] || [t isEqual:UTTypeContent]) return nil;
    if (![t conformsToType:UTTypeDirectory] || [t conformsToType:UTTypePackage]) [types addObject:t];
  }
  for (NSString *e in extensions) {
    UTType *t = [UTType typeWithFilenameExtension:e];
    if (t) [types addObject:t];
  }
  return types.count ? types : nil;
}

@implementation SRDocumentPickerHost {
  NSWindow * (^_windowForPid)(pid_t);
  xpc_connection_t _listener;
  NSMutableDictionary<NSNumber *, NSSavePanel *> *_panels;   // by app pid: the panel it is choosing with
  struct stat _executable;                                    // SimRun's executable when it started
}

// Open and save panels run in a macOS service that checks the app asking for one against its bundle on disk. Once
// SimRun.app has been rebuilt under a running SimRun, the service turns that SimRun away (AppKit logs "an error occurred
// while attempting to obtain endpoint for listener 'com.apple.view-bridge'") and the app's picker sees its connection
// interrupted. Nothing short of reopening SimRun fixes that, so say so.
- (BOOL)bundleReplaced {
  struct stat now;
  return stat(NSBundle.mainBundle.executablePath.fileSystemRepresentation, &now) != 0
      || now.st_ino != _executable.st_ino || now.st_dev != _executable.st_dev;
}

- (instancetype)initWithWindowForPid:(NSWindow * (^)(pid_t))windowForPid {
  if ((self = [super init])) {
    _windowForPid = [windowForPid copy]; _panels = [NSMutableDictionary dictionary];
    stat(NSBundle.mainBundle.executablePath.fileSystemRepresentation, &_executable);
  }
  return self;
}

// Everything runs on the main queue: panels are AppKit.
- (mach_port_t)start {
  _listener = xpc_connection_create(NULL, dispatch_get_main_queue());
  xpc_connection_enable_sim2host_4sim(_listener);
  xpc_connection_set_event_handler(_listener, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) [self accept:peer];
  });
  xpc_connection_activate(_listener);
  xpc_endpoint_t ep = xpc_endpoint_create(_listener);
  return ep ? xpc_endpoint_copy_listener_port_4sim(ep) : MACH_PORT_NULL;
}

- (void)accept:(xpc_connection_t)peer {
  pid_t pid = xpc_connection_get_pid(peer);
  xpc_connection_set_target_queue(peer, dispatch_get_main_queue());
  xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
    if (xpc_get_type(m) == XPC_TYPE_ERROR) {   // the app is gone: so is its panel
      if (m == XPC_ERROR_CONNECTION_INVALID) { [self->_panels[@(pid)] cancel:nil]; xpc_connection_cancel(peer); }
      return;
    }
    if (xpc_get_type(m) != XPC_TYPE_DICTIONARY) return;
    const char *op = xpc_dictionary_get_string(m, "op");
    if (op && !strcmp(op, "cancel")) { [self->_panels[@(pid)] cancel:nil]; return; }
    xpc_object_t reply = xpc_dictionary_create_reply(m);
    if (!reply) return;
    if (!op || strcmp(op, "choose")) { xpc_dictionary_set_string(reply, "error", "unknown op"); xpc_connection_send_message(peer, reply); return; }
    [self choose:m reply:reply peer:peer pid:pid];
  });
  xpc_connection_activate(peer);
}

- (void)choose:(xpc_object_t)m reply:(xpc_object_t)reply peer:(xpc_connection_t)peer pid:(pid_t)pid {
  if (_panels[@(pid)]) { xpc_dictionary_set_string(reply, "error", "a panel is already open"); xpc_connection_send_message(peer, reply); return; }
  if ([self bundleReplaced]) {
    static const char *why = "SimRun.app was rebuilt or replaced after this SimRun started, and macOS no longer shows its "
                             "open and save panels: quit and reopen SimRun (simrun stop)";
    fprintf(stderr, "[simrund] no file panel for pid %d: %s\n", pid, why);
    xpc_dictionary_set_string(reply, "error", why); xpc_connection_send_message(peer, reply); return;
  }
  const char *kind = xpc_dictionary_get_string(m, "panel"), *prompt = xpc_dictionary_get_string(m, "prompt");
  const char *directory = xpc_dictionary_get_string(m, "directory"), *message = xpc_dictionary_get_string(m, "message");
  NSSavePanel *panel;
  if (kind && !strcmp(kind, "save")) {
    panel = [NSSavePanel savePanel];
    const char *name = xpc_dictionary_get_string(m, "name");
    if (name) panel.nameFieldStringValue = @(name);
    panel.canCreateDirectories = YES;
  } else {
    NSOpenPanel *open = [NSOpenPanel openPanel];
    open.canChooseFiles = xpc_dictionary_get_bool(m, "files");
    open.canChooseDirectories = xpc_dictionary_get_bool(m, "directories");
    open.allowsMultipleSelection = xpc_dictionary_get_bool(m, "multiple");
    open.canCreateDirectories = open.canChooseDirectories;
    open.resolvesAliases = YES;
    if (open.canChooseFiles) {
      NSArray<UTType *> *types = AllowedTypes(Strings(m, "types"), Strings(m, "extensions"));
      if (types) open.allowedContentTypes = types;
    }
    panel = open;
  }
  if (prompt) panel.prompt = @(prompt);
  if (message) panel.message = @(message);
  if (directory) panel.directoryURL = [NSURL fileURLWithPath:@(directory) isDirectory:YES];
  _panels[@(pid)] = panel;

  void (^done)(NSModalResponse) = ^(NSModalResponse response) {
    [self->_panels removeObjectForKey:@(pid)];
    NSArray<NSURL *> *urls = response != NSModalResponseOK ? @[]
                           : [panel isKindOfClass:NSOpenPanel.class] ? ((NSOpenPanel *)panel).URLs : (panel.URL ? @[ panel.URL ] : @[]);
    xpc_object_t paths = xpc_array_create(NULL, 0);
    for (NSURL *u in urls) if (u.isFileURL) xpc_array_set_string(paths, XPC_ARRAY_APPEND, u.path.fileSystemRepresentation);
    xpc_dictionary_set_value(reply, "paths", paths);
    xpc_connection_send_message(peer, reply);
  };
  // The user is choosing for this app: bring it forward, with the panel as a sheet on its window.
  NSWindow *window = _windowForPid ? _windowForPid(pid) : nil;
  [NSApp activateIgnoringOtherApps:YES];
  if (window.visible && !window.attachedSheet) {
    [window makeKeyAndOrderFront:nil];
    [panel beginSheetModalForWindow:window completionHandler:done];
  } else {
    [panel beginWithCompletionHandler:done];
  }
}
@end
