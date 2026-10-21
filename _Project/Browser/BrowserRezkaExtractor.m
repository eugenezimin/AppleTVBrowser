#import "BrowserRezkaExtractor.h"

#import "BrowserWebView.h"

NSString * const BrowserRezkaPlayerElementSelector = @"#cdnplayer, #cdnplayer-container, .b-player";

static NSString * const kBrowserRezkaExtractorLogPrefix = @"[RezkaExtractor]";
static NSString * const kBrowserRezkaEncodedPrefix = @"#h";
static NSString * const kBrowserRezkaSeparator = @"//_//";

@implementation BrowserRezkaStream

- (instancetype)initWithLabel:(NSString *)label URL:(NSURL *)URL HLS:(BOOL)HLS premium:(BOOL)premium {
    self = [super init];
    if (self) {
        _label = [label copy];
        _URL = URL;
        _HLS = HLS;
        _premium = premium;
    }
    return self;
}

@end

@implementation BrowserRezkaExtractor

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"%@ %@", kBrowserRezkaExtractorLogPrefix, message);
}

- (NSArray<BrowserRezkaStream *> *)streamsInWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return @[];
    }

    // A translator/episode switch fetches a fresh stream list; the inline one only describes the default.
    for (NSDictionary *entry in webView.capturedMediaStreams.reverseObjectEnumerator) {
        if (![entry[@"kind"] isEqualToString:@"rezka-streams"]) {
            continue;
        }
        NSArray<BrowserRezkaStream *> *streams = [[self class] streamsFromEncodedString:entry[@"url"]];
        if (streams.count > 0) {
            [self log:@"using captured stream list (%lu streams)", (unsigned long)streams.count];
            return streams;
        }
    }

    NSString *inlineStreams = [webView stringByEvaluatingJavaScriptFromString:[self inlineStreamsJavaScript]];
    NSArray<BrowserRezkaStream *> *streams = [[self class] streamsFromEncodedString:inlineStreams ?: @""];
    if (streams.count > 0) {
        [self log:@"using inline stream list (%lu streams)", (unsigned long)streams.count];
    }
    return streams;
}

- (NSString *)inlineStreamsJavaScript {
    return @"(function(){"
            "var scripts = document.getElementsByTagName('script');"
            "for (var i = scripts.length - 1; i >= 0; i--) {"
                "var text = scripts[i].textContent || '';"
                "if (text.indexOf('initCDN') === -1) { continue; }"
                "var match = text.match(/initCDN(?:Movies|Series)Events\\([\\s\\S]*?\"streams\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"/);"
                "if (!match) { continue; }"
                "try { return JSON.parse('\"' + match[1] + '\"'); } catch (error) { return match[1]; }"
            "}"
            "return '';"
           "})()";
}

+ (NSArray<NSString *> *)trashCodes {
    static NSArray<NSString *> *trashCodes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *trashCharacters = @[@"@", @"#", @"!", @"^", @"$"];
        NSMutableArray<NSString *> *combinations = [NSMutableArray array];
        for (NSString *first in trashCharacters) {
            for (NSString *second in trashCharacters) {
                [combinations addObject:[first stringByAppendingString:second]];
            }
        }
        NSArray<NSString *> *pairs = [combinations copy];
        for (NSString *pair in pairs) {
            for (NSString *third in trashCharacters) {
                [combinations addObject:[pair stringByAppendingString:third]];
            }
        }

        NSMutableArray<NSString *> *codes = [NSMutableArray arrayWithCapacity:combinations.count];
        for (NSString *combination in combinations) {
            NSData *data = [combination dataUsingEncoding:NSUTF8StringEncoding];
            [codes addObject:[data base64EncodedStringWithOptions:0]];
        }
        trashCodes = [codes copy];
    });
    return trashCodes;
}

+ (NSString *)decodedStreamsString:(NSString *)encodedString {
    if (![encodedString hasPrefix:kBrowserRezkaEncodedPrefix]) {
        return encodedString;
    }

    NSString *body = [[encodedString substringFromIndex:kBrowserRezkaEncodedPrefix.length] stringByReplacingOccurrencesOfString:kBrowserRezkaSeparator withString:@""];
    for (NSString *trashCode in [self trashCodes]) {
        body = [body stringByReplacingOccurrencesOfString:trashCode withString:@""];
    }

    body = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger paddingLength = (4 - body.length % 4) % 4;
    body = [body stringByPaddingToLength:body.length + paddingLength withString:@"=" startingAtIndex:0];

    NSData *data = [[NSData alloc] initWithBase64EncodedString:body options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (data == nil) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (NSInteger)sortRankForLabel:(NSString *)label {
    NSString *lowercaseLabel = label.lowercaseString;
    NSInteger rank = 0;
    if ([lowercaseLabel containsString:@"4k"]) {
        rank = 2160;
    } else if ([lowercaseLabel containsString:@"2k"]) {
        rank = 1440;
    } else {
        NSScanner *scanner = [NSScanner scannerWithString:lowercaseLabel];
        scanner.charactersToBeSkipped = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        [scanner scanInteger:&rank];
    }
    // "1080p Ultra" is the higher-bitrate variant of "1080p".
    return rank * 10 + ([lowercaseLabel containsString:@"ultra"] ? 1 : 0);
}

+ (NSArray<BrowserRezkaStream *> *)streamsFromEncodedString:(NSString *)encodedString {
    if (![encodedString isKindOfClass:[NSString class]] || encodedString.length == 0) {
        return @[];
    }

    NSString *decodedString = [self decodedStreamsString:encodedString];
    if (decodedString.length == 0) {
        return @[];
    }

    NSRegularExpression *qualityExpression = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]]+)\\]([^\\[]+)" options:0 error:nil];
    NSCharacterSet *trimCharacters = [NSCharacterSet characterSetWithCharactersInString:@", \t\r\n"];
    NSMutableArray<BrowserRezkaStream *> *streams = [NSMutableArray array];
    NSArray<NSTextCheckingResult *> *matches = [qualityExpression matchesInString:decodedString options:0 range:NSMakeRange(0, decodedString.length)];
    NSRegularExpression *markupExpression = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:nil];
    for (NSTextCheckingResult *match in matches) {
        // Premium qualities are labelled with markup, e.g. <span class="pjs-prem-quality">1080p Ultra<img ...></span>.
        NSString *rawLabel = [decodedString substringWithRange:[match rangeAtIndex:1]];
        BOOL premium = [rawLabel.lowercaseString containsString:@"prem"];
        NSString *label = [markupExpression stringByReplacingMatchesInString:rawLabel options:0 range:NSMakeRange(0, rawLabel.length) withTemplate:@""];
        label = [label stringByTrimmingCharactersInSet:trimCharacters];
        if (premium) {
            label = [label stringByAppendingString:@" (Premium)"];
        }
        NSString *candidatesString = [decodedString substringWithRange:[match rangeAtIndex:2]];

        NSURL *progressiveURL = nil;
        NSURL *HLSURL = nil;
        for (NSString *candidate in [candidatesString componentsSeparatedByString:@" or "]) {
            NSString *URLString = [candidate stringByTrimmingCharactersInSet:trimCharacters];
            NSURL *URL = [NSURL URLWithString:URLString];
            NSString *scheme = URL.scheme.lowercaseString;
            if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
                continue;
            }
            if ([URLString.lowercaseString containsString:@".m3u8"]) {
                HLSURL = HLSURL ?: URL;
            } else {
                progressiveURL = progressiveURL ?: URL;
            }
        }

        NSURL *URL = HLSURL ?: progressiveURL;
        if (label.length > 0 && URL != nil) {
            [streams addObject:[[BrowserRezkaStream alloc] initWithLabel:label URL:URL HLS:HLSURL != nil premium:premium]];
        }
    }

    [streams sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(BrowserRezkaStream *first, BrowserRezkaStream *second) {
        if (first.isPremium != second.isPremium) {
            return first.isPremium ? NSOrderedDescending : NSOrderedAscending;
        }
        NSInteger firstRank = [self sortRankForLabel:first.label];
        NSInteger secondRank = [self sortRankForLabel:second.label];
        if (firstRank == secondRank) {
            return NSOrderedSame;
        }
        return firstRank > secondRank ? NSOrderedAscending : NSOrderedDescending;
    }];
    return streams;
}

@end
