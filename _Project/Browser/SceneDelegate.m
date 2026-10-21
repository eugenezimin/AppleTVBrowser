#import "SceneDelegate.h"

#import "AppDelegate.h"

@implementation SceneDelegate

- (AppDelegate *)appDelegate {
    return (AppDelegate *)UIApplication.sharedApplication.delegate;
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    [[self appDelegate] restoreCookiesFromDefaults];
}

- (void)sceneWillResignActive:(UIScene *)scene {
    [[self appDelegate] saveCookiesToDefaults];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    [[self appDelegate] restoreCookiesFromDefaults];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    [[self appDelegate] saveCookiesToDefaults];
}

@end
