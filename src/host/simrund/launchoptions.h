// launchoptions.h — an app's launch settings, edited in the launcher's Launch With… sheet and kept in user defaults per
// app path; every launch from the launcher uses them. Besides the runtime, arguments and environment variables, the
// switches are SimRun's own environment variables set to 1 (LOCALE_DISABLE, HID_VERBOSE, ...; docs/reference.md).
#pragma once
#import <Foundation/Foundation.h>

@interface SRLaunchItem : NSObject
@property BOOL enabled;
@property (copy) NSString *name, *value;   // an argument has only a value
@end

@interface SRLaunchOptions : NSObject
@property (copy) NSString *runtimeBuild;   // nil: SimRun's runtime (SimRun ▸ iOS Runtime)
@property (readonly) NSMutableArray<SRLaunchItem *> *arguments, *environment;
@property (readonly) NSMutableSet<NSString *> *switches;
+ (instancetype)optionsForAppAtPath:(NSString *)path;   // the saved ones, or the defaults
+ (void)removeOptionsForAppAtPath:(NSString *)path;
- (void)saveForAppAtPath:(NSString *)path;              // posts SRLibraryDidChangeNotification
// The enabled arguments, each split into words as a shell would ("quotes", 'quotes' and \ escapes).
- (NSArray<NSString *> *)launchArguments;
// The switches (=1), then the enabled environment variables.
- (NSDictionary<NSString *, NSString *> *)environmentVariables;
@end
