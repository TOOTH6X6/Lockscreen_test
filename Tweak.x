// ClockFont 0.2: lock screen clock in Apple's ADT numeric font (tall digits), sized to the screen width.
// Edit config.plist (Filza) and the clock updates within ~2 seconds, no respring needed.
// Diagnostic log: /var/mobile/Documents/ClockFont.log

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#if __has_include(<rootless.h>)
#import <rootless.h>
#endif
#ifndef ROOT_PATH_NS
#define ROOT_PATH_NS(path) (path)
#endif

#define VERSION @"0.2.0"
#define SUPPORT_DIR ROOT_PATH_NS(@"/Library/ClockFont")
#define LOG_PATH @"/var/mobile/Documents/ClockFont.log"

static const char kBusyKey;
static const char kClockKey;
static const char kOrigKey;

static BOOL gActive = NO;
static CGFloat gScale = 1.0;
static CGFloat gMinPt = 40.0;
static NSDictionary *gConfig = nil;
static NSString *gCfgPath = nil;
static NSDate *gCfgMTime = nil;
static CTFontDescriptorRef gBaseDesc = NULL;
static NSMutableDictionary *gCache = nil;
static NSMutableSet *gSeen = nil;
static NSHashTable *gLabels = nil;
static NSRegularExpression *gTimeRE = nil;
static CGFloat gFill = 0;
static BOOL gFillDone = NO;

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

static NSArray *configCandidates(void) {
    return @[
        [SUPPORT_DIR stringByAppendingPathComponent:@"config.plist"],
        @"/var/jb/Library/ClockFont/config.plist",
        @"/Library/ClockFont/config.plist",
        @"/var/mobile/Library/ClockFont/config.plist",
    ];
}

static NSDate *mtimeOf(NSString *path) {
    return [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileModificationDate];
}

static void loadConfig(void) {
    NSMutableDictionary *cfg = [@{
        @"enabled": @YES,
        @"face": @".SFAdaptiveNumeric-Regular",
        @"axes": @{ @"wght": @600, @"wdth": @100, @"HGHT": @260 },
        @"widthFraction": @0.75,
        @"sizeScale": @1.0,
        @"minPointSize": @40,
    } mutableCopy];
    NSString *found = nil;
    for (NSString *p in configCandidates()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { found = p; break; }
    }
    gCfgPath = found;
    gCfgMTime = found ? mtimeOf(found) : nil;
    NSDictionary *user = found ? [NSDictionary dictionaryWithContentsOfFile:found] : nil;
    if ([user isKindOfClass:[NSDictionary class]]) {
        [cfg addEntriesFromDictionary:user];
        CFLog(@"config read from %@", found);
    } else {
        CFLog(@"no readable config.plist (looked in %@), using defaults", [configCandidates() componentsJoinedByString:@", "]);
    }
    gConfig = cfg;
    gScale = [cfg[@"sizeScale"] doubleValue];
    if (gScale <= 0) gScale = 1.0;
    gMinPt = [cfg[@"minPointSize"] doubleValue];
    CFLog(@"effective: axes=%@ widthFraction=%@ sizeScale=%@ face=%@", cfg[@"axes"], cfg[@"widthFraction"], cfg[@"sizeScale"], cfg[@"face"]);
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

// Point size at which "00:00" spans widthFraction of the screen width.
// Digit height then follows from the HGHT axis (taller axis = taller digits at the same width).
static CGFloat fillSize(void) {
    if (gFillDone) return gFill;
    gFillDone = YES;
    gFill = 0;
    CGFloat frac = [gConfig[@"widthFraction"] doubleValue];
    if (frac <= 0) return 0;
    UIFont *probe = clockFont(100.0);
    if (!probe) return 0;
    CGSize b = [UIScreen mainScreen].bounds.size;
    CGFloat w = [@"00:00" sizeWithAttributes:@{ NSFontAttributeName: probe }].width;
    if (w <= 1) return 0;
    gFill = (MIN(b.width, b.height) * frac) * 100.0 / w;
    CFLog(@"fill size %.1f pt (screen %.0f x %.0f, fraction %.2f, 00:00 at 100pt = %.1f)", gFill, b.width, b.height, frac, w);
    return gFill;
}

#pragma mark - applying to labels

static BOOL isClockString(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 3 || s.length > 10) return NO;
    return [gTimeRE firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil;
}

// Size the label needs for its current text and font, so SpringBoard's fixed frame cannot cut the digits.
static CGSize neededSize(UILabel *l) {
    CGSize s = [l sizeThatFits:CGSizeMake(10000, 10000)];
    s.height = MAX(s.height, l.font.lineHeight);
    return CGSizeMake(ceil(s.width), ceil(s.height));
}

static BOOL isLiveClock(UILabel *l) {
    return gActive && objc_getAssociatedObject(l, &kClockKey) && l.font && isOurFont(l.font);
}

// Grow a frame to fit the text: keep the top edge and the horizontal center, so it extends downward.
static CGRect grownFrame(UILabel *l, CGRect f) {
    if (!isLiveClock(l)) return f;
    CGSize need = neededSize(l);
    if (f.size.width < need.width) {
        f.origin.x -= (need.width - f.size.width) / 2.0;
        f.size.width = need.width;
    }
    if (f.size.height < need.height) f.size.height = need.height;
    return f;
}

static void restyle(UILabel *label, CGFloat curPoint) {
    CGFloat fill = fillSize();
    CGFloat target = fill > 0 ? fill : curPoint * gScale;
    UIFont *nf = clockFont(target);
    if (!nf) {
        CFLog(@"could not build font at %.1f pt", target);
        return;
    }
    objc_setAssociatedObject(label, &kBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    label.adjustsFontSizeToFitWidth = NO;
    label.lineBreakMode = NSLineBreakByClipping;
    label.font = nf;
    objc_setAssociatedObject(label, &kBusyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(label, &kClockKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gLabels addObject:label];

    // Fit the label to the bigger text now, and stop the parents clipping it.
    label.clipsToBounds = NO;
    label.frame = grownFrame(label, label.frame);
    [label invalidateIntrinsicContentSize];
    UIView *v = label;
    for (int i = 0; v && i < 4; i++, v = v.superview) {
        [v setNeedsLayout];
        if (i > 0) v.clipsToBounds = NO;
    }
}

static void applyToLabel(UILabel *label) {
    if (!gActive || !label) return;
    UIFont *cur = label.font;
    if (!cur || cur.pointSize < gMinPt) return;
    if (objc_getAssociatedObject(label, &kBusyKey)) return;
    if (isOurFont(cur)) return;
    if (!isClockString(label.text)) return;

    objc_setAssociatedObject(label, &kOrigKey, @(cur.pointSize), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    restyle(label, cur.pointSize);

    NSString *tag = [NSString stringWithFormat:@"%@/%.0f", NSStringFromClass([label class]), cur.pointSize];
    if (![gSeen containsObject:tag]) {
        [gSeen addObject:tag];
        NSMutableArray *chain = [NSMutableArray array];
        UIView *p = label.superview;
        for (int i = 0; p && i < 6; i++, p = p.superview) [chain addObject:NSStringFromClass([p class])];
        CFLog(@"applied to %@ (was %@ %.0f pt, now %.1f pt) text=%@ parents=%@", NSStringFromClass([label class]), cur.fontName, cur.pointSize, label.font.pointSize, label.text, [chain componentsJoinedByString:@" < "]);
        __weak UILabel *weak = label;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UILabel *l = weak;
            if (!l) return;
            CFLog(@"after layout: label frame=%@ needed=%@ superview frame=%@ lineHeight=%.1f transform=%@",
                  NSStringFromCGRect(l.frame), NSStringFromCGSize(neededSize(l)), NSStringFromCGRect(l.superview.frame),
                  l.font.lineHeight, NSStringFromCGAffineTransform(l.transform));
        });
    }
}

#pragma mark - live reload

static void reloadIfChanged(void) {
    NSString *path = nil;
    for (NSString *p in configCandidates()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { path = p; break; }
    }
    NSDate *m = path ? mtimeOf(path) : nil;
    BOOL same = (path == gCfgPath || [path isEqualToString:gCfgPath]) && (m == gCfgMTime || [m isEqualToDate:gCfgMTime]);
    if (same) return;

    CFLog(@"config changed, reloading");
    loadConfig();
    if (![gConfig[@"enabled"] boolValue]) {
        CFLog(@"enabled=false: new labels are left alone, respring to restore the stock font");
        gActive = NO;
        return;
    }
    CTFontDescriptorRef nb = findBaseDescriptor();
    if (nb) {
        if (gBaseDesc) CFRelease(gBaseDesc);
        gBaseDesc = nb;
    }
    [gCache removeAllObjects];
    gFillDone = NO;
    gActive = YES;
    for (UILabel *l in [gLabels allObjects]) {
        if (l.window == nil && l.superview == nil) continue;
        NSNumber *orig = objc_getAssociatedObject(l, &kOrigKey);
        restyle(l, orig ? [orig doubleValue] : l.font.pointSize);
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
- (void)setFrame:(CGRect)frame {
    %orig(grownFrame(self, frame));
}
- (void)setBounds:(CGRect)bounds {
    if (!isLiveClock(self)) {
        %orig;
        return;
    }
    CGRect g = bounds;
    CGSize need = neededSize(self);
    CGFloat dh = 0;
    if (g.size.width < need.width) g.size.width = need.width;
    if (g.size.height < need.height) { dh = need.height - g.size.height; g.size.height = need.height; }
    %orig(g);
    if (dh > 0) {
        // bounds grow around the center; shift the center so the top edge stays put.
        CGPoint c = self.center;
        self.center = CGPointMake(c.x, c.y + dh / 2.0);
    }
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.apple.springboard"] && ![bid isEqualToString:@"com.apple.PosterBoard"]) return;
        CFLog(@"ClockFont %@ starting in %@", VERSION, bid);
        loadConfig();
        if (![gConfig[@"enabled"] boolValue]) return;
        gBaseDesc = findBaseDescriptor();
        if (!gBaseDesc) {
            CFLog(@"font face not found, tweak is idle");
            return;
        }
        gCache = [NSMutableDictionary dictionary];
        gSeen = [NSMutableSet set];
        gLabels = [NSHashTable weakObjectsHashTable];
        gTimeRE = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\d{1,2}[:\\u2236]\\d{2}(\\s?[AaPp][Mm])?\\s*$" options:0 error:nil];
        UIFont *test = clockFont(80.0);
        CFLog(@"loaded in %@, test font at 80 pt: %@", bid, test ? test.fontName : @"FAILED");
        if (!test) return;
        gActive = YES;
        %init;

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(timer, ^{ reloadIfChanged(); });
        dispatch_resume(timer);
        objc_setAssociatedObject([NSBundle mainBundle], "ClockFontTimer", timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
