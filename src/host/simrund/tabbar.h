// tabbar.h — a row of tabs as in Xcode's scheme editor: borderless buttons, the selected one on a pill tinted with the
// accent color. Used by the launcher's app pane and the Launch With… sheet.
#pragma once
#import <Cocoa/Cocoa.h>

@interface SRTabBar : NSStackView
+ (instancetype)tabBarWithTitles:(NSArray<NSString *> *)titles;
@property (nonatomic) NSInteger selectedIndex;              // setting it doesn't call onSelect
@property (copy) void (^onSelect)(NSInteger index);         // the user chose a tab
@end
