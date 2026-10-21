#import "BrowserContentBlocker.h"

#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

static NSString * const kBrowserContentBlockerLogPrefix = @"[ContentBlocker]";
static NSString * const kBrowserContentBlockerEnabledDefaultsKey = @"ContentBlockerEnabled";
static NSString * const kBrowserContentBlockerDirectoryName = @"ContentBlockers";
static NSString * const kBrowserContentBlockerIdentifierPrefix = @"browser-content-blocker-";
static NSString * const kBrowserContentRuleListStoreClassName = @"WKContentRuleListStore";

@interface BrowserContentBlocker ()

@property (nonatomic, strong) NSHashTable *userContentControllers;
@property (nonatomic, strong) NSMutableArray *ruleLists;
@property (nonatomic) BOOL loadingStarted;

@end

@implementation BrowserContentBlocker

+ (instancetype)sharedBlocker {
    static BrowserContentBlocker *sharedBlocker = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedBlocker = [BrowserContentBlocker new];
    });
    return sharedBlocker;
}

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"%@ %@", kBrowserContentBlockerLogPrefix, message);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _userContentControllers = [NSHashTable weakObjectsHashTable];
        _ruleLists = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isEnabled {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kBrowserContentBlockerEnabledDefaultsKey];
    return value == nil ? YES : [value boolValue];
}

- (void)setEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kBrowserContentBlockerEnabledDefaultsKey];
    for (id userContentController in self.userContentControllers) {
        if (enabled) {
            [self addRuleLists:self.ruleLists toUserContentController:userContentController];
        } else {
            [self removeRuleListsFromUserContentController:userContentController];
        }
    }
    [self startLoadingIfNeeded];
}

- (void)registerUserContentController:(id)userContentController {
    if (userContentController == nil) {
        return;
    }
    [self.userContentControllers addObject:userContentController];
    if (self.isEnabled) {
        [self addRuleLists:self.ruleLists toUserContentController:userContentController];
    }
    [self startLoadingIfNeeded];
}

- (void)addRuleLists:(NSArray *)ruleLists toUserContentController:(id)userContentController {
    SEL addSelector = NSSelectorFromString(@"addContentRuleList:");
    if (![userContentController respondsToSelector:addSelector]) {
        return;
    }
    for (id ruleList in ruleLists) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addSelector, ruleList);
    }
}

- (void)removeRuleListsFromUserContentController:(id)userContentController {
    SEL removeSelector = NSSelectorFromString(@"removeAllContentRuleLists");
    if ([userContentController respondsToSelector:removeSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(userContentController, removeSelector);
    }
}

- (void)ruleListDidBecomeAvailable:(id)ruleList {
    [self.ruleLists addObject:ruleList];
    if (!self.isEnabled) {
        return;
    }
    for (id userContentController in self.userContentControllers) {
        [self addRuleLists:@[ruleList] toUserContentController:userContentController];
    }
}

#pragma mark - Loading

- (id)ruleListStore {
    Class storeClass = NSClassFromString(kBrowserContentRuleListStoreClassName);
    SEL storeWithURLSelector = NSSelectorFromString(@"storeWithURL:");
    if (storeClass == Nil || ![storeClass respondsToSelector:storeWithURLSelector]) {
        return nil;
    }

    // WebKit cannot create its default Library/WebKit directories in this app's container on
    // tvOS, and tvOS apps may only write to Caches and tmp. If the system purges the cache, the
    // lists are simply compiled again.
    NSURL *cachesURL = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *storeURL = [cachesURL URLByAppendingPathComponent:@"ContentRuleLists" isDirectory:YES];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:storeURL withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self log:@"could not create %@: %@", storeURL.path, error];
        return nil;
    }

    // Compiled lists are named "ContentRuleList-<identifier>"; anything else is the temporary
    // file of a compile that was interrupted (for example by the app being killed).
    for (NSURL *fileURL in [NSFileManager.defaultManager contentsOfDirectoryAtURL:storeURL includingPropertiesForKeys:nil options:0 error:nil]) {
        if (![fileURL.lastPathComponent hasPrefix:@"ContentRuleList-"]) {
            [NSFileManager.defaultManager removeItemAtURL:fileURL error:nil];
        }
    }
    return ((id (*)(id, SEL, id))objc_msgSend)((id)storeClass, storeWithURLSelector, storeURL);
}

- (void)startLoadingIfNeeded {
    // Compiling takes a while on Apple TV, so it waits until the blocker is actually wanted.
    if (self.loadingStarted || !self.isEnabled) {
        return;
    }
    self.loadingStarted = YES;

    id store = [self ruleListStore];
    if (store == nil) {
        [self log:@"WKContentRuleListStore is unavailable; ad blocking disabled"];
        return;
    }

    NSArray<NSURL *> *ruleFileURLs = [[NSBundle mainBundle] URLsForResourcesWithExtension:@"json" subdirectory:kBrowserContentBlockerDirectoryName];
    for (NSURL *ruleFileURL in [ruleFileURLs sortedArrayUsingComparator:^NSComparisonResult(NSURL *first, NSURL *second) {
        return [first.lastPathComponent compare:second.lastPathComponent];
    }]) {
        [self loadRuleListFromFileURL:ruleFileURL store:store];
    }
}

- (void)loadRuleListFromFileURL:(NSURL *)fileURL store:(id)store {
    NSString *name = fileURL.URLByDeletingPathExtension.lastPathComponent;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:fileURL];
        if (data.length == 0) {
            [self log:@"%@: rule file is missing or empty", name];
            return;
        }

        // The digest in the identifier makes updated rule files recompile, while unchanged ones
        // reuse the copy WebKit compiled on an earlier launch.
        NSString *identifierPrefix = [NSString stringWithFormat:@"%@%@-", kBrowserContentBlockerIdentifierPrefix, name];
        NSString *identifier = [identifierPrefix stringByAppendingString:[self digestForData:data]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self lookUpOrCompileRuleListWithIdentifier:identifier identifierPrefix:identifierPrefix data:data store:store];
        });
    });
}

- (NSString *)digestForData:(NSData *)data {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hexDigest = [NSMutableString stringWithCapacity:16];
    for (NSUInteger index = 0; index < 8; index++) {
        [hexDigest appendFormat:@"%02x", digest[index]];
    }
    return hexDigest;
}

- (void)lookUpOrCompileRuleListWithIdentifier:(NSString *)identifier
                             identifierPrefix:(NSString *)identifierPrefix
                                         data:(NSData *)data
                                        store:(id)store {
    SEL lookUpSelector = NSSelectorFromString(@"lookUpContentRuleListForIdentifier:completionHandler:");
    if (![store respondsToSelector:lookUpSelector]) {
        return;
    }

    ((void (*)(id, SEL, id, id))objc_msgSend)(store, lookUpSelector, identifier, ^(id ruleList, __unused NSError *error) {
        if (ruleList != nil) {
            [self log:@"%@ loaded from cache", identifier];
            [self ruleListDidBecomeAvailable:ruleList];
            return;
        }
        [self removeStaleRuleListsWithPrefix:identifierPrefix keepingIdentifier:identifier store:store];
        [self compileRuleListWithIdentifier:identifier data:data store:store];
    });
}

- (void)compileRuleListWithIdentifier:(NSString *)identifier data:(NSData *)data store:(id)store {
    SEL compileSelector = NSSelectorFromString(@"compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:");
    NSString *encodedRuleList = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (![store respondsToSelector:compileSelector] || encodedRuleList.length == 0) {
        return;
    }

    CFTimeInterval startTime = CACurrentMediaTime();
    [self log:@"compiling %@", identifier];
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, compileSelector, identifier, encodedRuleList, ^(id ruleList, NSError *error) {
        if (ruleList == nil) {
            [self log:@"%@ failed to compile: %@", identifier, error];
            return;
        }
        [self log:@"%@ compiled in %.1fs", identifier, CACurrentMediaTime() - startTime];
        [self ruleListDidBecomeAvailable:ruleList];
    });
}

- (void)removeStaleRuleListsWithPrefix:(NSString *)identifierPrefix keepingIdentifier:(NSString *)identifier store:(id)store {
    SEL identifiersSelector = NSSelectorFromString(@"getAvailableContentRuleListIdentifiers:");
    SEL removeSelector = NSSelectorFromString(@"removeContentRuleListForIdentifier:completionHandler:");
    if (![store respondsToSelector:identifiersSelector] || ![store respondsToSelector:removeSelector]) {
        return;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(store, identifiersSelector, ^(NSArray<NSString *> *identifiers) {
        for (NSString *existingIdentifier in identifiers) {
            if ([existingIdentifier hasPrefix:identifierPrefix] && ![existingIdentifier isEqualToString:identifier]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(store, removeSelector, existingIdentifier, ^(__unused NSError *error) {});
            }
        }
    });
}

@end
