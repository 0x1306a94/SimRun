// HIDTest.app — input test app for the hid workstream. Every input-related callback logs with an "[app]" prefix.
// Layout (402x874 scene, points):  button "Tap me" (id "button") frame {20,80,362,50}
//                                   text field (id "field")    frame {20,150,362,44}
//                                   switch (id "switch")       frame {20,210,...}
//                                   table view (id "table")    frame {0,260,402,614}, 100 rows of 44 pt
#import <UIKit/UIKit.h>

@interface LogView : UIView @end
@implementation LogView
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { UITouch *x = t.anyObject; NSLog(@"[app] touchesBegan %@ n=%lu type=%ld", NSStringFromCGPoint([x locationInView:self]), (unsigned long)t.count, (long)x.type); [super touchesBegan:t withEvent:e]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { NSLog(@"[app] touchesMoved %@", NSStringFromCGPoint([t.anyObject locationInView:self])); [super touchesMoved:t withEvent:e]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { NSLog(@"[app] touchesEnded %@", NSStringFromCGPoint([t.anyObject locationInView:self])); [super touchesEnded:t withEvent:e]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { NSLog(@"[app] touchesCancelled"); [super touchesCancelled:t withEvent:e]; }
@end

@interface VC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property UITableView *table; @property UITextField *field; @property CGFloat lastLoggedOffset;
@end
@implementation VC
- (void)loadView { self.view = [LogView new]; }
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
  b.accessibilityIdentifier = @"button";
  [b setTitle:@"Tap me" forState:UIControlStateNormal];
  b.frame = CGRectMake(20, 80, 362, 50);
  b.backgroundColor = UIColor.systemYellowColor;
  [b addAction:[UIAction actionWithHandler:^(UIAction *a) { NSLog(@"[app] BUTTON ACTION (touchUpInside) fired"); }] forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:b];

  UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(20, 150, 362, 44)];
  f.accessibilityIdentifier = @"field";
  f.borderStyle = UITextBorderStyleRoundedRect;
  f.placeholder = @"type here";
  f.autocorrectionType = UITextAutocorrectionTypeNo;
  f.autocapitalizationType = UITextAutocapitalizationTypeNone;
  f.delegate = self;
  [f addAction:[UIAction actionWithHandler:^(UIAction *a) { NSLog(@"[app] TEXTFIELD text now \"%@\"", f.text); }] forControlEvents:UIControlEventEditingChanged];
  [self.view addSubview:f];
  self.field = f;

  UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(20, 210, 60, 31)];
  sw.accessibilityIdentifier = @"switch";
  [sw addAction:[UIAction actionWithHandler:^(UIAction *a) { NSLog(@"[app] SWITCH valueChanged -> %d", sw.isOn); }] forControlEvents:UIControlEventValueChanged];
  [self.view addSubview:sw];

  UITableView *t = [[UITableView alloc] initWithFrame:CGRectMake(0, 260, 402, 614) style:UITableViewStylePlain];
  t.accessibilityIdentifier = @"table";
  t.dataSource = self; t.delegate = self;
  [t registerClass:UITableViewCell.class forCellReuseIdentifier:@"c"];
  [self.view addSubview:t];
  self.table = t;

  UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
  [self.view addGestureRecognizer:pinch];
  UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTap:)];
  tap.cancelsTouchesInView = NO;
  [self.view addGestureRecognizer:tap];
}
- (void)pinch:(UIPinchGestureRecognizer *)g {
  if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateEnded)
    NSLog(@"[app] PINCH %@ scale=%.2f touches=%lu", g.state == UIGestureRecognizerStateBegan ? @"began" : @"ended", g.scale, (unsigned long)g.numberOfTouches);
}
- (void)bgTap:(UITapGestureRecognizer *)g { NSLog(@"[app] TAP GESTURE recognized at %@", NSStringFromCGPoint([g locationInView:self.view])); }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 100; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
  c.textLabel.text = [NSString stringWithFormat:@"Row %ld", (long)ip.row];
  return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { NSLog(@"[app] TABLE didSelectRow %ld", (long)ip.row); }
- (void)scrollViewWillBeginDragging:(UIScrollView *)sv { NSLog(@"[app] SCROLL willBeginDragging offset=%@", NSStringFromCGPoint(sv.contentOffset)); }
- (void)scrollViewDidScroll:(UIScrollView *)sv {
  if (fabs(sv.contentOffset.y - self.lastLoggedOffset) >= 50) { self.lastLoggedOffset = sv.contentOffset.y; NSLog(@"[app] SCROLL didScroll offset.y=%.1f", sv.contentOffset.y); }
}
- (void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)d { NSLog(@"[app] SCROLL didEndDragging offset.y=%.1f decelerate=%d", sv.contentOffset.y, d); }
- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv { NSLog(@"[app] SCROLL didEndDecelerating offset.y=%.1f", sv.contentOffset.y); }
- (void)textFieldDidBeginEditing:(UITextField *)tf { NSLog(@"[app] TEXTFIELD didBeginEditing (isFirstResponder=%d)", tf.isFirstResponder); }
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s { NSLog(@"[app] TEXTFIELD shouldChange %@ -> \"%@\"", NSStringFromRange(r), s); return YES; }
- (void)textFieldDidEndEditing:(UITextField *)tf { NSLog(@"[app] TEXTFIELD didEndEditing text=\"%@\"%@", tf.text, getenv("APP_STACKS") ? NSThread.callStackSymbols : @""); }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { NSLog(@"[app] TEXTFIELD return pressed, text=\"%@\"", tf.text); [tf resignFirstResponder]; [self becomeFirstResponder]; return YES; }
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)e {
  for (UIPress *p in presses) NSLog(@"[app] pressesBegan key=%@ hid=0x%lx mods=0x%lx", p.key.characters, (long)p.key.keyCode, (long)p.key.modifierFlags);
  [super pressesBegan:presses withEvent:e];
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (NSArray<UIKeyCommand *> *)keyCommands {
  UIKeyCommand *down = [UIKeyCommand keyCommandWithInput:UIKeyInputDownArrow modifierFlags:0 action:@selector(arrow:)];
  UIKeyCommand *up = [UIKeyCommand keyCommandWithInput:UIKeyInputUpArrow modifierFlags:0 action:@selector(arrow:)];
  UIKeyCommand *cmdK = [UIKeyCommand keyCommandWithInput:@"k" modifierFlags:UIKeyModifierCommand action:@selector(cmdK:)];
  for (UIKeyCommand *k in @[down, up, cmdK]) k.wantsPriorityOverSystemBehavior = YES;
  return @[down, up, cmdK];
}
- (void)arrow:(UIKeyCommand *)k { NSLog(@"[app] KEYCOMMAND arrow %@", [k.input isEqual:UIKeyInputDownArrow] ? @"down" : @"up"); }
- (void)cmdK:(UIKeyCommand *)k { NSLog(@"[app] KEYCOMMAND cmd-K"); }
@end

@interface SD : UIResponder <UIWindowSceneDelegate> @property (nonatomic, strong) UIWindow *window; @end
@implementation SD
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.rootViewController = [VC new];
  [self.window makeKeyAndVisible];
  NSLog(@"[app] window %@ key=%d", NSStringFromCGRect(self.window.frame), self.window.isKeyWindow);
}
@end
@interface AD : UIResponder <UIApplicationDelegate> @end
@implementation AD
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
  UISceneConfiguration *c = [UISceneConfiguration configurationWithName:@"Default" sessionRole:s.role];
  c.delegateClass = SD.class; return c;
}
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AD.class)); } }
