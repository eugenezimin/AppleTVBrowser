#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserNativeVideoAssetLoader.h"

#import <AVFoundation/AVFoundation.h>

static NSString * const kBrowserNativeVideoPlayerLogPrefix = @"[NativeVideoPlayer]";
static NSTimeInterval const kBrowserNativeVideoSkipInterval = 10.0;
static NSString * const kBrowserNativePlayerInputLogPrefix = @"[InputTrace][NativePlayer]";

static NSString *BrowserNativePlayerPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserNativePlayerPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

@interface BrowserNativeVideoPlayerViewController ()

@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, copy) NSString *videoTitle;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *requestCookies;
@property (nonatomic, strong) BrowserNativeVideoAssetLoader *assetLoader;
@property (nonatomic) BOOL usesResourceLoaderProxy;
@property (nonatomic) BOOL presentedFailureAlert;
@property (nonatomic, strong) NSError *pendingFailureError;
@property (nonatomic) BOOL appliedStartTime;
@property (nonatomic, strong) NSNumber *transportBarShowsPlaying;

@end

@implementation BrowserNativeVideoPlayerViewController

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"%@ %@", kBrowserNativeVideoPlayerLogPrefix, message);
}

- (instancetype)initWithURL:(NSURL *)URL title:(NSString *)title {
    return [self initWithURL:URL title:title requestHeaders:nil cookies:nil];
}

- (instancetype)initWithURL:(NSURL *)URL
                      title:(NSString *)title
             requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                    cookies:(NSArray<NSHTTPCookie *> *)cookies {
    return [self initWithURL:URL title:title requestHeaders:requestHeaders cookies:cookies usesResourceLoaderProxy:YES];
}

- (instancetype)initWithURL:(NSURL *)URL
                      title:(NSString *)title
             requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                    cookies:(NSArray<NSHTTPCookie *> *)cookies
    usesResourceLoaderProxy:(BOOL)usesResourceLoaderProxy {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _videoURL = URL;
        _videoTitle = [title copy] ?: @"";
        _requestHeaders = [requestHeaders copy] ?: @{};
        _requestCookies = [cookies copy] ?: @[];
        _usesResourceLoaderProxy = usesResourceLoaderProxy;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;
    self.showsPlaybackControls = YES;
    AVPlayerItem *playerItem = nil;
    if (self.requestHeaders.count > 0 || self.requestCookies.count > 0) {
        NSMutableDictionary *assetOptions = [NSMutableDictionary dictionary];
        if (self.requestHeaders.count > 0) {
            assetOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = self.requestHeaders;
            NSString *userAgent = self.requestHeaders[@"User-Agent"];
            if (userAgent.length > 0) {
                assetOptions[@"AVURLAssetHTTPUserAgentKey"] = userAgent;
            }
        }
        if (self.requestCookies.count > 0) {
            assetOptions[@"AVURLAssetHTTPCookiesKey"] = self.requestCookies;
        }
        AVURLAsset *asset = nil;
        if (self.usesResourceLoaderProxy) {
            self.assetLoader = [[BrowserNativeVideoAssetLoader alloc] initWithRequestHeaders:self.requestHeaders cookies:self.requestCookies];
            NSURL *assetURL = [self.assetLoader assetURLForPlaybackURL:self.videoURL];
            asset = [AVURLAsset URLAssetWithURL:assetURL options:assetOptions];
            [self.assetLoader attachToAsset:asset];
        } else {
            asset = [AVURLAsset URLAssetWithURL:self.videoURL options:assetOptions];
        }
        playerItem = [AVPlayerItem playerItemWithAsset:asset];
        [self log:@"using request headers %@ cookies=%lu proxy=%d", self.requestHeaders, (unsigned long)self.requestCookies.count, self.usesResourceLoaderProxy];
    } else {
        playerItem = [AVPlayerItem playerItemWithURL:self.videoURL];
    }
    self.player = [AVPlayer playerWithPlayerItem:playerItem];
    [self log:@"created player url=%@", self.videoURL.absoluteString ?: @""];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemFailedToPlayToEndTime:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:self.player.currentItem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemNewErrorLogEntry:)
                                                 name:AVPlayerItemNewErrorLogEntryNotification
                                               object:self.player.currentItem];

    [self.player.currentItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
    [self.player addObserver:self
                  forKeyPath:@"timeControlStatus"
                     options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                     context:NULL];
    [self updateTransportBarItems];
}

// tvOS shows only the progress bar by default; these add on-screen skip and play/pause buttons to it.
- (void)updateTransportBarItems {
    // Rebuilding the items moves focus, so only do it when the play/pause button has to change.
    BOOL playing = self.player.timeControlStatus != AVPlayerTimeControlStatusPaused;
    if (self.transportBarShowsPlaying != nil && self.transportBarShowsPlaying.boolValue == playing) {
        return;
    }
    self.transportBarShowsPlaying = @(playing);

    __weak typeof(self) weakSelf = self;
    NSString *skipBackTitle = [NSString stringWithFormat:@"Back %.0f Seconds", kBrowserNativeVideoSkipInterval];
    NSString *skipForwardTitle = [NSString stringWithFormat:@"Forward %.0f Seconds", kBrowserNativeVideoSkipInterval];
    self.transportBarCustomMenuItems = @[
        [UIAction actionWithTitle:skipBackTitle
                            image:[UIImage systemImageNamed:@"gobackward.10"]
                       identifier:nil
                          handler:^(__unused UIAction *action) {
            [weakSelf skipBySeconds:-kBrowserNativeVideoSkipInterval];
        }],
        [UIAction actionWithTitle:playing ? @"Pause" : @"Play"
                            image:[UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"]
                       identifier:nil
                          handler:^(__unused UIAction *action) {
            [weakSelf togglePlayback];
        }],
        [UIAction actionWithTitle:skipForwardTitle
                            image:[UIImage systemImageNamed:@"goforward.10"]
                       identifier:nil
                          handler:^(__unused UIAction *action) {
            [weakSelf skipBySeconds:kBrowserNativeVideoSkipInterval];
        }],
    ];
}

- (void)togglePlayback {
    if (self.player.timeControlStatus == AVPlayerTimeControlStatusPaused) {
        [self.player play];
    } else {
        [self.player pause];
    }
}

- (void)skipBySeconds:(NSTimeInterval)seconds {
    CMTime currentTime = self.player.currentTime;
    if (!CMTIME_IS_NUMERIC(currentTime)) {
        return;
    }

    NSTimeInterval targetTime = MAX(CMTimeGetSeconds(currentTime) + seconds, 0.0);
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    if (isfinite(duration) && duration > 0.0) {
        targetTime = MIN(targetTime, duration);
    }
    [self log:@"skip %+.0fs to %.1f", seconds, targetTime];
    [self.player seekToTime:CMTimeMakeWithSeconds(targetTime, NSEC_PER_SEC)];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSLog(@"%@ viewDidAppear", kBrowserNativePlayerInputLogPrefix);
    if (self.pendingFailureError != nil) {
        NSError *error = self.pendingFailureError;
        self.pendingFailureError = nil;
        [self presentPlaybackFailureAlertWithError:error];
        return;
    }
    [self log:@"viewDidAppear play"];
    [self.player play];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    NSLog(@"%@ viewWillDisappear", kBrowserNativePlayerInputLogPrefix);
    [self log:@"viewWillDisappear pause"];
    [self.player pause];
}

- (void)dealloc {
    @try {
        [self.player.currentItem removeObserver:self forKeyPath:@"status"];
    } @catch (__unused NSException *exception) {}
    @try {
        [self.player removeObserver:self forKeyPath:@"timeControlStatus"];
    } @catch (__unused NSException *exception) {}
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)closePlayer {
    [self log:@"close player"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)presentPlaybackFailureAlertWithError:(NSError *)error {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentPlaybackFailureAlertWithError:error];
        });
        return;
    }

    // The item can fail before the player is on screen; viewDidAppear picks it up then.
    if (self.view.window == nil) {
        self.pendingFailureError = error;
        return;
    }

    if (self.presentedFailureAlert || self.presentedViewController != nil) {
        return;
    }
    self.presentedFailureAlert = YES;

    NSString *reason = error.localizedFailureReason ?: error.localizedDescription ?: @"Unknown error.";
    NSString *message = [NSString stringWithFormat:@"%@\n\nHost: %@", reason, self.videoURL.host ?: @"unknown"];
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Video Could Not Be Played"
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        [weakSelf closePlayer];
    }]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)handlePlayerItemFailedToPlayToEndTime:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self log:@"failedToPlayToEnd error=%@", error];
}

- (void)handlePlayerItemNewErrorLogEntry:(NSNotification *)notification {
    AVPlayerItemErrorLog *errorLog = self.player.currentItem.errorLog;
    AVPlayerItemErrorLogEvent *lastEvent = errorLog.events.lastObject;
    [self log:@"errorLog domain=%@ status=%ld comment=%@ serverAddress=%@ playbackSessionID=%@",
     lastEvent.errorDomain ?: @"",
     (long)lastEvent.errorStatusCode,
     lastEvent.errorComment ?: @"",
     lastEvent.serverAddress ?: @"",
     lastEvent.playbackSessionID ?: @""];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == self.player.currentItem && [keyPath isEqualToString:@"status"]) {
        switch (self.player.currentItem.status) {
            case AVPlayerItemStatusUnknown:
                [self log:@"item status=unknown error=%@", self.player.currentItem.error];
                break;
            case AVPlayerItemStatusReadyToPlay:
                [self log:@"item status=ready duration=%f likelyToKeepUp=%d bufferEmpty=%d",
                 CMTimeGetSeconds(self.player.currentItem.duration),
                 self.player.currentItem.isPlaybackLikelyToKeepUp,
                 self.player.currentItem.isPlaybackBufferEmpty];
                if (!self.appliedStartTime && self.startTime > 1.0) {
                    self.appliedStartTime = YES;
                    [self log:@"seek to start time %0.3f", self.startTime];
                    [self.player seekToTime:CMTimeMakeWithSeconds(self.startTime, NSEC_PER_SEC)];
                }
                break;
            case AVPlayerItemStatusFailed:
                [self log:@"item status=failed error=%@", self.player.currentItem.error];
                [self presentPlaybackFailureAlertWithError:self.player.currentItem.error];
                break;
        }
        return;
    }

    if (object == self.player && [keyPath isEqualToString:@"timeControlStatus"]) {
        NSString *status = @"unknown";
        switch (self.player.timeControlStatus) {
            case AVPlayerTimeControlStatusPaused:
                status = @"paused";
                break;
            case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                status = @"waiting";
                break;
            case AVPlayerTimeControlStatusPlaying:
                status = @"playing";
                break;
        }
        [self log:@"timeControlStatus=%@ reason=%@", status, self.player.reasonForWaitingToPlay ?: @""];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateTransportBarItems];
        });
        return;
    }

    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"%@ pressesBegan type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"%@ pressesEnded type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesEnded:presses withEvent:event];
}

@end
