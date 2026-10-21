#import <Foundation/Foundation.h>

@class BrowserViewModel;
@class BrowserNavigationService;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserSessionStore : NSObject

- (BOOL)restoreSessionIntoViewModel:(BrowserViewModel *)viewModel;
- (void)saveSessionForViewModel:(BrowserViewModel *)viewModel;
- (nullable NSURLRequest *)consumeSavedURLToReopenRequestWithNavigationService:(BrowserNavigationService *)navigationService;

@end

NS_ASSUME_NONNULL_END
