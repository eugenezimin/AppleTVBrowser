#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const BrowserRezkaPlayerElementSelector;

@interface BrowserRezkaStream : NSObject

@property (nonatomic, copy, readonly) NSString *label;
@property (nonatomic, strong, readonly) NSURL *URL;
@property (nonatomic, readonly, getter=isHLS) BOOL HLS;
// Premium-only qualities only play a short promo for regular accounts.
@property (nonatomic, readonly, getter=isPremium) BOOL premium;

- (instancetype)initWithLabel:(NSString *)label URL:(NSURL *)URL HLS:(BOOL)HLS premium:(BOOL)premium NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// Reads the stream list of rezka.ag (and its mirror domains) players.
@interface BrowserRezkaExtractor : NSObject

// Streams for the translator/episode currently selected on the page, highest quality first, with
// premium-only qualities last.
// Returns an empty array when the page is not a rezka player page.
- (NSArray<BrowserRezkaStream *> *)streamsInWebView:(BrowserWebView *)webView;

// Decodes a rezka "streams"/"url" value ("#h..." obfuscated or plain "[720p]https://... or https://...,").
+ (NSArray<BrowserRezkaStream *> *)streamsFromEncodedString:(NSString *)encodedString;

@end

NS_ASSUME_NONNULL_END
