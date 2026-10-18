// ClockFont: lock screen clock in Apple's ADT numeric font (tall, narrow digits).
// Font axes and size are read from /Library/ClockFont/config.plist at SpringBoard start.
// A short diagnostic log is written to /var/mobile/Documents/ClockFont.log

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#if __has_include(<rootless.h>)
#import <rootless.h>
#endif
#ifndef ROOT_PATH_NS
#define ROOT_PATH_NS(path) (path)
#endif

#define SUPPORT_DIR ROOT_PATH_NS(@"/Library/ClockFont")
#define LOG_PATH @"/var/mobile/Documents/ClockFont.log"

static const char kBusyKey;

static BOOL gActive = NO;
static CGFloat gScale = 1.0;
static CGFloat gMinPt = 40.0;
static NSDictionary *gConfig = nil;
static CTFontDescriptorRef gBaseDesc = NULL;
static NSMutableDictionary *gCache = nil;
static NSMutableSet *gSeen = nil;
static NSRegularExpression *gTimeRE = nil;

#pragma mark - logging

static void CFLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[ClockFont] %@", msg);
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:LOG_PATH error:nil];
        if (attrs && [attrs fileSize] > 64 * 1024) return;
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n", [NSDate date], [[NSProcessInfo processInfo] processName], msg];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
        if (!h) {
            [line writeToFile:LOG_PATH atomically:NO encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } @catch (NSException *e) {}
}

#pragma mark - config and font

static void loadConfig(void) {
    NSMutableDictionary *cfg = [@{
        @"enabled": @YES,
        @"face": @".SFAdaptiveNumeric-Regular",
        @"axes": @{ @"wght": @600, @"wdth": @100, @"HGHT": @200 },
        @"sizeScale": @1.0,
        @"minPointSize": @40,
    } mutableCopy];
    NSString *path = [SUPPORT_DIR stringByAppendingPathComponent:@"config.plist"];
    NSDictionary *user = [NSDictionary dictionaryWithContentsOfFile:path];
    if ([user isKindOfClass:[NSDictionary class]]) {
        [cfg addEntriesFromDictionary:user];
    } else {
        CFLog(@"no config.plist at %@, using defaults", path);
    }
    gConfig = cfg;
    gScale = [cfg[@"sizeScale"] doubleValue];
    if (gScale <= 0) gScale = 1.0;
    gMinPt = [cfg[@"minPointSize"] doubleValue];
}

static CTFontDescriptorRef findBaseDescriptor(void) {
    NSString *face = gConfig[@"face"];
    NSArray *paths = @[
        [SUPPORT_DIR stringByAppendingPathComponent:@"ADTNumeric.ttc"],
        @"/System/Library/Fonts/Core/ADTNumeric.ttc",
        @"/System/Library/Fonts/ADTNumeric.ttc",
    ];
    for (NSString *p in paths) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
        CFArrayRef arr = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)[NSURL fileURLWithPath:p]);
        if (!arr) {
            CFLog(@"could not read fonts from %@", p);
            continue;
        }
        CTFontDescriptorRef found = NULL;
        NSMutableArray *names = [NSMutableArray array];
        for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
            CTFontDescriptorRef d = (CTFontDescriptorRef)CFArrayGetValueAtIndex(arr, i);
            CFStringRef ps = (CFStringRef)CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute);
            if (ps) {
                [names addObject:(__bridge NSString *)ps];
                if (!found && [(__bridge NSString *)ps isEqualToString:face]) found = (CTFontDescriptorRef)CFRetain(d);
                CFRelease(ps);
            }
        }
        CFRelease(arr);
        if (found) {
            CFLog(@"using face %@ from %@", face, p);
            return found;
        }
        CFLog(@"face %@ not found in %@, it has: %@", face, p, [names componentsJoinedByString:@", "]);
    }
    return NULL;
}

static NSNumber *axisID(NSString *tag) {
    long long v = 0;
    for (NSUInteger i = 0; i < 4; i++) v = (v << 8) | (unsigned char)[tag characterAtIndex:i];
    return @(v);
}

static UIFont *clockFont(CGFloat size) {
    if (!gBaseDesc) return nil;
    NSNumber *key = @((NSInteger)lround(size * 10.0));
    UIFont *cached = gCache[key];
    if (cached) return cached;

    NSMutableDictionary *variation = [NSMutableDictionary dictionary];
    NSDictionary *axes = gConfig[@"axes"];
    if ([axes isKindOfClass:[NSDictionary class]]) {
        for (NSString *tag in axes) {
            if (![tag isKindOfClass:[NSString class]] || tag.length != 4) continue;
            variation[axisID(tag)] = @([axes[tag] doubleValue]);
        }
    }
    CTFontDescriptorRef desc = CTFontDescriptorCreateCopyWithAttributes(gBaseDesc, (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCTFontVariationAttribute: variation,
    });
    if (!desc) return nil;
    CTFontRef ct = CTFontCreateWithFontDescriptor(desc, size, NULL);
    CFRelease(desc);
    if (!ct) return nil;
    UIFont *font = (__bridge_transfer UIFont *)ct;
    gCache[key] = font;
    return font;
}

static BOOL isOurFont(UIFont *f) {
    for (UIFont *ours in [gCache allValues]) if (ours == f) return YES;
    return NO;
}

#pragma mark - applying to labels

static BOOL isClockString(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 3 || s.length > 10) return NO;
    return [gTimeRE firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil;
}

static void applyToLabel(UILabel *label) {
    if (!gActive || !label) return;
    UIFont *cur = label.font;
    if (!cur || cur.pointSize < gMinPt) return;
    if (objc_getAssociatedObject(label, &kBusyKey)) return;
    if (isOurFont(cur)) return;
    if (!isClockString(label.text)) return;

    UIFont *nf = clockFont(cur.pointSize * gScale);
    if (!nf) {
        CFLog(@"could not build font at %.1f pt", cur.pointSize * gScale);
        return;
    }
    objc_setAssociatedObject(label, &kBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    label.font = nf;
    objc_setAssociatedObject(label, &kBusyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [label setNeedsLayout];
    [label.superview setNeedsLayout];

    NSString *tag = [NSString stringWithFormat:@"%@/%.0f", NSStringFromClass([label class]), cur.pointSize];
    if (![gSeen containsObject:tag]) {
        [gSeen addObject:tag];
        NSMutableArray *chain = [NSMutableArray array];
        UIView *v = label.superview;
        for (int i = 0; v && i < 6; i++, v = v.superview) [chain addObject:NSStringFromClass([v class])];
        CFLog(@"applied to %@ (was %@ %.0f pt) text=%@ parents=%@", NSStringFromClass([label class]), cur.fontName, cur.pointSize, label.text, [chain componentsJoinedByString:@" < "]);
    }
}

%hook UILabel
- (void)setFont:(UIFont *)font {
    %orig;
    applyToLabel(self);
}
- (void)setText:(NSString *)text {
    %orig;
    applyToLabel(self);
}
- (void)setAttributedText:(NSAttributedString *)text {
    %orig;
    applyToLabel(self);
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.apple.springboard"] && ![bid isEqualToString:@"com.apple.PosterBoard"]) return;
        loadConfig();
        if (![gConfig[@"enabled"] boolValue]) return;
        gBaseDesc = findBaseDescriptor();
        if (!gBaseDesc) {
            CFLog(@"font face not found, tweak is idle");
            return;
        }
        gCache = [NSMutableDictionary dictionary];
        gSeen = [NSMutableSet set];
        gTimeRE = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\d{1,2}[:\\u2236]\\d{2}(\\s?[AaPp][Mm])?\\s*$" options:0 error:nil];
        UIFont *test = clockFont(80.0);
        CFLog(@"loaded in %@, test font at 80 pt: %@", bid, test ? test.fontName : @"FAILED");
        if (!test) return;
        gActive = YES;
        %init;
    }
}
