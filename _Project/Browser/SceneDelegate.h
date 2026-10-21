#import <UIKit/UIKit.h>

// tvOS 27 requires the UIScene lifecycle; with it, UIKit stops sending the app-level
// resign/background callbacks, so cookie persistence is driven from here instead.
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (strong, nonatomic) UIWindow *window;

@end
