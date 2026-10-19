// ClockFont 0.5.2: lock screen clock in Apple's ADT numeric font (tall digits), sized to the screen width,
// with an optional "Liquid Glass" look (blurred glass digits, light rim, Metal edge refraction), emulated on iOS 16.
// Edit config.plist (Filza) and the clock updates within ~2 seconds, no respring needed.
// Diagnostic log: /var/mobile/Documents/ClockFont.log
//
// config.plist keys (all optional):
//   enabled        BOOL    master switch (needs respring when turned back on)
//   face           String  .SFAdaptiveNumeric-Regular | .SFAdaptiveSoftNumeric-Regular
//   axes           Dict    wght / wdth / HGHT
//   widthFraction  Real    share of screen width the "00:00" spans (0.75)
//   liquidGlass    BOOL    glass effect on the clock (YES)
//   glassBlur      Real    blur radius inside the digits (8)
//   glassSaturation Real   colour boost of what shows through the glass (1.8)
//   glassTint      Real    white tint alpha over the glass (0.10)
//   glassEdge      Real    rim light alpha, 0 turns the rim off (0.95)
//   glassEdgeWidth Real    rim stroke width in pt (1.0)
//   glassBaseAlpha Real    alpha of the stock vibrant digits under the glass (0.30)
//
// 0.4.0 changes
//  - FIX: the inner label of SBUILegibilityLabel was pushed left by exactly half its width, because it is first
//    framed at zero width and we grew that frame around its centre. Zero-width frames now keep their left edge.
//  - FIX: font detection no longer depends on object identity only (UILabel may hand back another instance).
//  - Log spam from "extended sibling" lines is de-duplicated.
//  - NEW: Liquid Glass module (private CABackdropLayer + CAFilter, hosted next to the vibrancy portal).
//
// 0.5.2: live refraction, no flicker, tracking
//  - Refraction now samples the picture OUTSIDE the digits (mirrored across the edge), where the glass is never drawn.
//    So the capture no longer has to hide the glass: the hide/blink that caused the flicker is gone and the capture can
//    run continuously (glassLiveFPS, default 15) on a background queue.
//  - Glass position, size and alpha follow the clock every display frame, from the layers' PRESENTATION values
//    (in-flight animations), not once per layout / 2 s from model values. The stock digits' alpha is re-applied per frame.
//  - Log line "clock positions (screen pt)" lists every live clock label and glass, to see which copy is off.
//
// 0.5.1: crash safety
//  - Metal setup (shader compile, UIScreen) no longer runs in the constructor while SpringBoard is still starting;
//    it runs when the first glass view is created.
//  - Crash breadcrumbs: risky steps (glass, metal, capture, render) write their name to ClockFont.stage while they run.
//    If SpringBoard dies in one, the next launch writes it to ClockFont.disabled and keeps that step off.
//    Delete /var/mobile/Documents/ClockFont.disabled to try again.
//
// 0.5.0 changes: refraction
//  - NEW: Metal layer with a glyph signed-distance-field and the refraction / rim shader from LiquidGlassDock
//    (Kyant "Backdrop" port, Apache-2.0, see NOTICE.txt). Drawn on every display frame, only when something changed.
//  - NEW: background capture for the refraction (CARenderServerRenderDisplay, double buffered, glass hidden while
//    capturing). Event driven by default; glassLiveFPS > 0 captures continuously (can flicker).
//  - Makefile: add Metal and IOSurface to the tweak's FRAMEWORKS (QuartzCore is already there).
//  - Force a new capture: notifyutil -p com.example.clockfont.recapture
//
// refraction keys (all optional):
//   glassRefraction     BOOL  Metal refraction on/off (YES); off = blur + tint + gradient rim only
//   glassRefractHeight  Real  width of the refracting band along the digit edge, pt (5)
//   glassRefractAmount  Real  how far the band bends the picture, pt (9)
//   glassRefractMix     Real  0..1 how much of the bent picture shows in the band (0.7)
//   glassChroma         Real  colour fringing, 0 = none (0.8)
//   glassRimStrength    Real  rim light (0.55)
//   glassGlow           Real  soft inner glow near the edge (0.05)
//   glassRimSat         Real  saturation of the refracted picture (1.25)
//   glassRimBlur        Real  blur of the refracted picture, pt (1.5)
//   glassLiveFPS        Real  background capture rate for the refracted picture (15); 0 = only on events
//   glassFPS            Real  display-link rate for the Metal layer (60)

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <simd/simd.h>
#if __has_include(<rootless.h>)
#import <rootless.h>
#endif
#ifndef ROOT_PATH_NS
#define ROOT_PATH_NS(path) (path)
#endif

#define VERSION @"0.5.2"
#define SUPPORT_DIR ROOT_PATH_NS(@"/Library/ClockFont")
#define LOG_PATH @"/var/mobile/Documents/ClockFont.log"

static const char kBusyKey;
static const char kClockKey;
static const char kOrigKey;
static const char kGlassKey;      // label -> its glass view
static const char kGlassMarkKey;  // marker on the glass view itself
static const char kGlassPendKey;  // coalesced update pending
static const char kBaseAlphaKey;  // label's alpha before we dimmed it

static BOOL gActive = NO;
static BOOL gGlassOn = NO;
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

// Log each distinct message only once per process (used for lines that repeat on every layout pass).
static void CFLogOnce(NSString *key, NSString *fmt, ...) {
    static NSMutableSet *done = nil;
    if (!done) done = [NSMutableSet set];
    if ([done containsObject:key]) return;
    [done addObject:key];
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    CFLog(@"%@", msg);
}

#pragma mark - crash breadcrumbs

// A SpringBoard crash drops Dopamine into Safe Mode. Risky steps leave their name in STAGE_PATH while they run.
// A launch that finds a leftover file knows the last name in it was running when SpringBoard died, and disables it.
#define STAGE_PATH @"/var/mobile/Documents/ClockFont.stage"
#define DISABLED_PATH @"/var/mobile/Documents/ClockFont.disabled"

static NSMutableArray *gActiveStages = nil;
static NSMutableSet *gSettledStages = nil;
static NSMutableSet *gDisabledStages = nil;

static void stageWrite(void) {
    if (gActiveStages.count == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:STAGE_PATH error:nil];
        return;
    }
    [[gActiveStages componentsJoinedByString:@","] writeToFile:STAGE_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL stageDisabled(NSString *name) {
    return [gDisabledStages containsObject:name];
}

// Only the first run of each step per process is tracked, so steady-state frames do no file I/O.
static void stageBegin(NSString *name) {
    if ([gSettledStages containsObject:name] || [gActiveStages containsObject:name]) return;
    [gActiveStages addObject:name];
    stageWrite();
}

static void stageEnd(NSString *name) {
    [gSettledStages addObject:name];
    if ([gActiveStages containsObject:name]) {
        [gActiveStages removeObject:name];
        stageWrite();
    }
}

static void stageInit(void) {
    gActiveStages = [NSMutableArray array];
    gSettledStages = [NSMutableSet set];
    gDisabledStages = [NSMutableSet set];
    NSString *old = [NSString stringWithContentsOfFile:DISABLED_PATH encoding:NSUTF8StringEncoding error:nil];
    for (NSString *l in [old componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (l.length) [gDisabledStages addObject:l];
    }
    NSString *left = [NSString stringWithContentsOfFile:STAGE_PATH encoding:NSUTF8StringEncoding error:nil];
    if (left.length) {
        NSString *culprit = [[left componentsSeparatedByString:@","] lastObject];
        if (culprit.length) [gDisabledStages addObject:culprit];
        [[[gDisabledStages allObjects] componentsJoinedByString:@"\n"] writeToFile:DISABLED_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:STAGE_PATH error:nil];
        CFLog(@"previous run ended while these steps were running: %@. Disabling '%@' (delete %@ to retry)", left, culprit, DISABLED_PATH);
    }
    if (gDisabledStages.count) CFLog(@"disabled steps: %@", [[gDisabledStages allObjects] componentsJoinedByString:@", "]);
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

static CGFloat cfgNum(NSString *key, CGFloat def) {
    id v = gConfig[key];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def;
}

static void loadConfig(void) {
    NSMutableDictionary *cfg = [@{
        @"enabled": @YES,
        @"face": @".SFAdaptiveNumeric-Regular",
        @"axes": @{ @"wght": @600, @"wdth": @100, @"HGHT": @260 },
        @"widthFraction": @0.75,
        @"sizeScale": @1.0,
        @"minPointSize": @40,
        @"extendEffects": @YES,
        @"extendAncestors": @NO,
        @"alignLayers": @YES,
        @"liquidGlass": @YES,
        @"glassBlur": @8,
        @"glassSaturation": @1.8,
        @"glassTint": @0.10,
        @"glassEdge": @0.95,
        @"glassEdgeWidth": @1.0,
        @"glassBaseAlpha": @0.30,
        @"glassRefraction": @YES,
        @"glassRefractHeight": @5.0,
        @"glassRefractAmount": @9.0,
        @"glassRefractMix": @0.7,
        @"glassChroma": @0.8,
        @"glassRimStrength": @0.55,
        @"glassGlow": @0.05,
        @"glassRimSat": @1.25,
        @"glassRimBlur": @1.5,
        @"glassLiveFPS": @15,
        @"glassFPS": @60,
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
    CFLog(@"effective: axes=%@ widthFraction=%@ sizeScale=%@ face=%@ liquidGlass=%@", cfg[@"axes"], cfg[@"widthFraction"], cfg[@"sizeScale"], cfg[@"face"], cfg[@"liquidGlass"]);
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

// Identity first (cheap), then by name: UILabel does not always hand back the instance we set.
static BOOL isOurFont(UIFont *f) {
    if (!f) return NO;
    for (UIFont *ours in [gCache allValues]) if (ours == f) return YES;
    return [f.fontName hasPrefix:@".SFAdaptive"];
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

// Grow a frame to fit the text: keep the top edge, and the horizontal center when the frame already had a width.
// A zero-width frame (SBUILegibilityLabel frames its inner label that way first) keeps its left edge instead,
// otherwise the label ends up half its width to the left of where its parent expects it.
static CGRect grownFrame(UILabel *l, CGRect f) {
    if (!isLiveClock(l)) return f;
    CGSize need = neededSize(l);
    if (f.size.width < need.width) {
        if (f.size.width > 1.0) f.origin.x -= (need.width - f.size.width) / 2.0;
        f.size.width = need.width;
    }
    if (f.size.height < need.height) f.size.height = need.height;
    return f;
}

#pragma mark - effect views (blur / vibrancy / masks)

static BOOL looksLikeEffect(UIView *v) {
    CALayer *l = v.layer;
    return [v isKindOfClass:[UIVisualEffectView class]] || l.filters.count > 0 || l.backgroundFilters.count > 0 || l.compositingFilter != nil || l.mask != nil;
}

static NSString *shortDesc(id o) {
    if (!o) return @"-";
    NSString *s = [[o description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return s.length > 90 ? [s substringToIndex:90] : s;
}

static NSString *describeView(UIView *v) {
    CALayer *l = v.layer;
    return [NSString stringWithFormat:@"%@ frame=%@ clip=%d alpha=%.2f filters=%@ bgFilters=%@ comp=%@ mask=%@",
            NSStringFromClass([v class]), NSStringFromCGRect(v.frame), (int)v.clipsToBounds, v.alpha,
            l.filters.count ? shortDesc(l.filters) : @"-", l.backgroundFilters.count ? shortDesc(l.backgroundFilters) : @"-",
            shortDesc(l.compositingFilter), l.mask ? NSStringFromClass([l.mask class]) : @"-"];
}

static void dumpHierarchy(UILabel *label) {
    CFLog(@"hierarchy: label %@", describeView(label));
    UIView *child = label;
    UIView *p = label.superview;
    for (int i = 0; p && i < 4; i++) {
        CFLog(@"  parent%d %@", i, describeView(p));
        int shown = 0;
        for (UIView *s in p.subviews) {
            if (s == child) continue;
            if (shown++ >= 8) break;
            CFLog(@"    sibling %@%@", describeView(s), looksLikeEffect(s) ? @" [effect]" : @"");
        }
        child = p;
        p = p.superview;
    }
}

// The stock clock has its blur/vibrancy view sized for the stock clock. Stretch those views down
// so they cover the whole taller clock: effect views next to the label, and effect ancestors.
static void extendEffects(UILabel *label) {
    static BOOL busy = NO;
    if (busy || ![gConfig[@"extendEffects"] boolValue]) return;
    busy = YES;
    UIView *child = label;
    UIView *p = label.superview;
    for (int i = 0; p && i < 3; i++) {
        CGRect lr = [label.superview convertRect:label.frame toView:p];
        CGFloat bottom = CGRectGetMaxY(lr);
        // Growing an ancestor re-centers its content and shifts one clock layer away from the other,
        // so this is off unless extendAncestors is set in config.plist.
        if ([gConfig[@"extendAncestors"] boolValue] && looksLikeEffect(p) && bottom > p.bounds.size.height + 0.5) {
            CGRect f = p.frame;
            f.size.height += bottom - p.bounds.size.height;
            p.frame = f;
            CFLogOnce([NSString stringWithFormat:@"anc/%@/%.0f", NSStringFromClass([p class]), f.size.height],
                      @"extended ancestor %@ to height %.1f", NSStringFromClass([p class]), f.size.height);
        }
        for (UIView *s in p.subviews) {
            if (s == child || objc_getAssociatedObject(s, &kGlassMarkKey) || !looksLikeEffect(s)) continue;
            CGRect sr = s.frame;
            BOOL overlaps = CGRectGetMinX(sr) < CGRectGetMaxX(lr) && CGRectGetMaxX(sr) > CGRectGetMinX(lr) &&
                            CGRectGetMinY(sr) < CGRectGetMaxY(lr) && CGRectGetMaxY(sr) > CGRectGetMinY(lr);
            if (overlaps && CGRectGetMaxY(sr) < bottom - 0.5) {
                sr.size.height += bottom - CGRectGetMaxY(sr);
                s.frame = sr;
                CFLogOnce([NSString stringWithFormat:@"sib/%@/%.0f", NSStringFromClass([s class]), sr.size.height],
                          @"extended sibling %@ to height %.1f", NSStringFromClass([s class]), sr.size.height);
            }
        }
        child = p;
        p = p.superview;
    }
    busy = NO;
}

// The lock screen draws the clock more than once (a blurred layer behind, a brightening layer in front).
// Each copy is a UILabel with the same text. After our resize they can end up at different heights, so
// move every extra copy (with its date, by shifting the whole branch under the common parent) onto the
// copy that sits highest, which is where the stock clock is.
static UIView *commonAncestor(UIView *a, UIView *b) {
    NSMutableSet *chain = [NSMutableSet set];
    for (UIView *v = a.superview; v; v = v.superview) [chain addObject:v];
    for (UIView *v = b.superview; v; v = v.superview) if ([chain containsObject:v]) return v;
    return nil;
}

static UIView *branchUnder(UIView *ancestor, UIView *v) {
    while (v && v.superview != ancestor) v = v.superview;
    return v;
}

static void alignLayers(void) {
    static BOOL busy = NO;
    static NSMutableSet *logged = nil;
    if (busy || !gActive || ![gConfig[@"alignLayers"] boolValue]) return;
    busy = YES;
    NSMutableArray *clocks = [NSMutableArray array];
    for (UILabel *l in [gLabels allObjects]) {
        if (l.window && !l.hidden && l.alpha > 0.01 && isLiveClock(l)) [clocks addObject:l];
    }
    if (clocks.count >= 2) {
        UILabel *ref = nil;
        CGRect refR = CGRectZero;
        for (UILabel *l in clocks) {
            CGRect r = [l convertRect:l.bounds toView:nil];
            if (!ref || r.origin.y < refR.origin.y - 0.5) { ref = l; refR = r; }
        }
        for (UILabel *l in clocks) {
            if (l == ref || l.window != ref.window) continue;
            CGRect r = [l convertRect:l.bounds toView:nil];
            BOOL sameShape = fabs(r.size.width - refR.size.width) < 4 && fabs(r.size.height - refR.size.height) < 4;
            BOOL sameColumn = fabs(r.origin.x - refR.origin.x) < 40;
            CGFloat dx = refR.origin.x - r.origin.x, dy = refR.origin.y - r.origin.y;
            if (!sameShape || !sameColumn || fabs(dy) > 600) continue;
            if (fabs(dx) < 0.5 && fabs(dy) < 0.5) continue;
            UIView *lca = commonAncestor(ref, l);
            UIView *branch = lca ? branchUnder(lca, l) : nil;
            if (!branch) continue;
            CGRect f = branch.frame;
            f.origin.x += dx;
            f.origin.y += dy;
            branch.frame = f;
            if (!logged) logged = [NSMutableSet set];
            NSString *key = [NSString stringWithFormat:@"%@/%.0f", NSStringFromClass([branch class]), dy];
            if (![logged containsObject:key]) {
                [logged addObject:key];
                CFLog(@"aligned layer: moved %@ by (%.1f, %.1f); reference label is in %@, common parent %@", NSStringFromClass([branch class]), dx, dy, NSStringFromClass([ref.superview class]), NSStringFromClass([lca class]));
            }
        }
    }
    busy = NO;
}

#pragma mark - liquid glass

// Liquid Glass is an iOS 26 material; iOS 16 has no public API for it. This module emulates it with three layers:
//  1. a live CABackdropLayer (blur + saturation of whatever is behind the clock, done by the render server every
//     frame) masked to the digit outlines: the glass body,
//  2. a Metal layer that evaluates, every frame, a signed distance field of the digits and draws veil, glow, rim light
//     and EDGE REFRACTION (the wallpaper bent along the outline normal, with colour fringing). The maths is the
//     refraction / SDF / rim shader of LiquidGlassDock (port of Kyant's "Backdrop", Apache-2.0, see NOTICE.txt),
//     with the rounded-rectangle SDF replaced by a distance field computed from the glyph outlines,
//  3. CAShapeLayer tint + gradient rim as a fallback when Metal is unavailable.
// The overlay is hosted inside BSUIVibrancyEffectView, next to (not inside) the portal that mirrors the clock,
// because portals do not carry backdrop layers. The stock vibrant digits underneath are dimmed (glassBaseAlpha).
//
// What "real time" means here: the shader runs on every display frame (CADisplayLink) and follows the clock, including
// in-flight animations; the blur body is live (render server). The picture the rim refracts is a screen capture
// (CARenderServerRenderDisplay) refreshed in the background at glassLiveFPS. The rim samples only pixels OUTSIDE the digits,
// where the glass is never drawn, so the capture contains no glass and nothing has to be hidden while it runs.

static id makeFilter(NSString *type) {
    Class c = NSClassFromString(@"CAFilter");
    SEL sel = NSSelectorFromString(@"filterWithType:");
    if (!c || ![c respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(c, sel, type);
}

static BOOL glassSupported(void) {
    return NSClassFromString(@"CABackdropLayer") != nil && makeFilter(@"gaussianBlur") != nil;
}

#pragma mark metal state and shader

#define LG_TAG(...) @#__VA_ARGS__

static NSString *const kMSL = LG_TAG(
struct U { float2 size; float2 origin; float2 bgSize; float refH; float refA; float chroma; float scale; float tint; float sat; float rim; float glow; float refMix; float sdfToPx; float blurPx; float bgOn; };
float3 bgTap(texture2d<float> t, float2 p, float2 sz, float r) {
  constexpr sampler s(filter::linear, address::clamp_to_edge);
  float3 c = t.sample(s, p / sz).rgb;
  if (r > 0.01) {
    c += t.sample(s, (p + float2(r, 0.0)) / sz).rgb;
    c += t.sample(s, (p - float2(r, 0.0)) / sz).rgb;
    c += t.sample(s, (p + float2(0.0, r)) / sz).rgb;
    c += t.sample(s, (p - float2(0.0, r)) / sz).rgb;
    c *= 0.2;
  }
  return c;
}
vertex float4 vmain(uint v [[vertex_id]]) {
  float2 p = float2((v << 1) & 2, v & 2);
  return float4(p * 2.0 - 1.0, 0.0, 1.0);
}
fragment float4 fmain(float4 pos [[position]], constant U &u [[buffer(0)]], texture2d<float> sdfT [[texture(0)]], texture2d<float> bg [[texture(1)]]) {
  constexpr sampler ls(filter::linear, address::clamp_to_edge);
  float2 uv = pos.xy / u.size;
  float sd = sdfT.sample(ls, uv).r * u.sdfToPx;
  float alpha = clamp(0.5 - sd, 0.0, 1.0);
  if (alpha <= 0.0) return float4(0.0);
  float depthIn = -min(sd, 0.0);
  float2 e = 1.0 / float2(sdfT.get_width(), sdfT.get_height());
  float2 gr = float2(sdfT.sample(ls, uv + float2(e.x, 0.0)).r - sdfT.sample(ls, uv - float2(e.x, 0.0)).r,
                     sdfT.sample(ls, uv + float2(0.0, e.y)).r - sdfT.sample(ls, uv - float2(0.0, e.y)).r);
  float gl = length(gr);
  float2 n = gl > 1e-4 ? gr / gl : float2(0.0);
  float wr = 0.0;
  float3 col = float3(1.0);
  if (u.bgOn > 0.5 && depthIn < u.refH) {
    float x = clamp(1.0 - depthIn / u.refH, 0.0, 1.0);
    float bend = (1.0 - sqrt(1.0 - x * x)) * u.refA;
    float2 off = n * (2.0 * depthIn + bend);
    float2 p = pos.xy + u.origin + off;
    float2 disp = n * bend * u.chroma * 0.25;
    float3 r = float3(bgTap(bg, p + disp, u.bgSize, u.blurPx).r, bgTap(bg, p, u.bgSize, u.blurPx).g, bgTap(bg, p - disp, u.bgSize, u.blurPx).b);
    float lum = dot(r, float3(0.299, 0.587, 0.114));
    r = mix(float3(lum), r, u.sat);
    col = mix(r, float3(1.0), u.tint);
    wr = (1.0 - smoothstep(0.0, u.refH, depthIn)) * u.refMix;
  }
  float vy = pos.y / u.size.y;
  float veil = u.tint + 0.05 * (1.0 - vy);
  float a = max(veil, wr);
  float3 base = mix(float3(1.0), col, wr);
  float glow = exp(-depthIn / (7.0 * u.scale)) * u.glow;
  float rim = exp(-depthIn / (1.2 * u.scale)) * pow(abs(dot(n, normalize(float2(-1.0, -1.0)))), 1.5) * u.rim;
  float h = glow + rim;
  float3 pm = clamp(base * a + float3(h), 0.0, 1.0);
  float aa = clamp(a + h, 0.0, 1.0);
  return float4(pm * alpha, aa * alpha);
}
);

// Must match struct U in the shader above (3 x float2, then 12 floats).
typedef struct { simd_float2 size; simd_float2 origin; simd_float2 bgSize; float refH, refA, chroma, scale, tint, sat, rim, glow, refMix, sdfToPx, blurPx, bgOn; } LGU;

static id<MTLDevice> gDev;
static id<MTLCommandQueue> gQ;
static id<MTLRenderPipelineState> gPSO;
static BOOL gMetalOK = NO;
static BOOL gRefractWanted = NO;
static BOOL gRefractOn = NO;
static CGFloat gPxScale = 3.0;

// Background capture, double buffered so the renderer never reads a surface that is being written.
static IOSurfaceRef gBgSurf[2];
static id<MTLTexture> gBgTex[2];
static int gBgFront = -1;
static NSUInteger gBgGen = 0;
static BOOL gNeedCapture = YES;
static CFTimeInterval gCapDue = 0, gLastCap = 0;
static BOOL gWasVisible = NO;

static BOOL setupMetal(void) {
    gDev = MTLCreateSystemDefaultDevice();
    if (!gDev) { CFLog(@"metal: no device"); return NO; }
    gQ = [gDev newCommandQueue];
    NSError *e = nil;
    NSString *src = [@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:kMSL];
    id<MTLLibrary> lib = [gDev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { CFLog(@"metal: MSL compile error: %@", e); return NO; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vmain"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fmain"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    gPSO = [gDev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!gPSO) { CFLog(@"metal: pipeline error: %@", e); return NO; }
    gPxScale = UIScreen.mainScreen.nativeScale;
    CFLog(@"metal: ready (device %@, nativeScale %.2f)", gDev.name, gPxScale);
    return YES;
}

static BOOL setupBgBuffers(void) {
    if (gBgSurf[0] && gBgSurf[1]) return YES;
    UIScreen *s = UIScreen.mainScreen;
    size_t W = (size_t)s.nativeBounds.size.width, H = (size_t)s.nativeBounds.size.height;
    for (int i = 0; i < 2; i++) {
        NSDictionary *props = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @(0x42475241) };
        gBgSurf[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!gBgSurf[i]) { CFLog(@"capture: IOSurfaceCreate failed"); return NO; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        gBgTex[i] = [gDev newTextureWithDescriptor:td iosurface:gBgSurf[i] plane:0];
        if (!gBgTex[i]) { CFLog(@"capture: texture from IOSurface failed"); return NO; }
    }
    CFLog(@"capture: buffers ready %zux%zu", W, H);
    return YES;
}

// Metal is set up late, when the first glass view is about to be created, not while SpringBoard is still loading.
static BOOL ensureMetal(void) {
    if (gMetalOK) return YES;
    static BOOL tried = NO;
    if (!gRefractWanted || tried) return NO;
    tried = YES;
    stageBegin(@"metal");
    gMetalOK = setupMetal();
    stageEnd(@"metal");
    gRefractOn = gGlassOn && gMetalOK;
    return gMetalOK;
}

#pragma mark glyph signed distance field

// Felzenszwalb & Huttenlocher exact squared Euclidean distance transform, 1D pass.
static void edt1d(const float *f, float *d, int n, int *v, float *z) {
    const float INF = 1e20f;
    int k = 0;
    v[0] = 0; z[0] = -INF; z[1] = INF;
    for (int q = 1; q < n; q++) {
        float s = ((f[q] + (float)q * q) - (f[v[k]] + (float)v[k] * v[k])) / (2.0f * q - 2.0f * v[k]);
        while (s <= z[k]) {
            k--;
            s = ((f[q] + (float)q * q) - (f[v[k]] + (float)v[k] * v[k])) / (2.0f * q - 2.0f * v[k]);
        }
        k++;
        v[k] = q; z[k] = s; z[k + 1] = INF;
    }
    k = 0;
    for (int q = 0; q < n; q++) {
        while (z[k + 1] < q) k++;
        float dx = (float)(q - v[k]);
        d[q] = dx * dx + f[v[k]];
    }
}

static void edt2d(float *f, int w, int h) {
    int m = MAX(w, h);
    float *col = malloc(sizeof(float) * m), *out = malloc(sizeof(float) * m), *z = malloc(sizeof(float) * (m + 1));
    int *v = malloc(sizeof(int) * m);
    for (int x = 0; x < w; x++) {
        for (int y = 0; y < h; y++) col[y] = f[(size_t)y * w + x];
        edt1d(col, out, h, v, z);
        for (int y = 0; y < h; y++) f[(size_t)y * w + x] = out[y];
    }
    for (int y = 0; y < h; y++) {
        edt1d(f + (size_t)y * w, out, w, v, z);
        memcpy(f + (size_t)y * w, out, sizeof(float) * w);
    }
    free(col); free(out); free(z); free(v);
}

// Signed distance (pixels of the SDF texture, negative inside) of `path`, drawn at `s` px per point, as an R16Float texture.
// Runs on a background queue; the path is in label coordinates (y down) and `pt` is the label size.
static id<MTLTexture> buildSDF(CGPathRef path, CGSize pt, CGFloat s, float maxD) {
    int w = (int)ceil(pt.width * s), h = (int)ceil(pt.height * s);
    if (w < 4 || h < 4 || w > 2400 || h > 2400) return nil;
    size_t n = (size_t)w * h;
    uint8_t *mask = calloc(n, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef cx = CGBitmapContextCreate(mask, w, h, 8, w, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!cx) { free(mask); return nil; }
    CGContextTranslateCTM(cx, 0, h);
    CGContextScaleCTM(cx, s, -s);
    CGContextSetGrayFillColor(cx, 1.0, 1.0);
    CGContextAddPath(cx, path);
    CGContextFillPath(cx);
    CGContextRelease(cx);

    float *dOut = malloc(n * sizeof(float)), *dIn = malloc(n * sizeof(float));
    BOOL any = NO;
    for (size_t i = 0; i < n; i++) {
        BOOL in = mask[i] > 127;
        if (in) any = YES;
        dOut[i] = in ? 0.0f : 1e20f;
        dIn[i] = in ? 1e20f : 0.0f;
    }
    free(mask);
    if (!any) { free(dOut); free(dIn); return nil; }
    edt2d(dOut, w, h);
    edt2d(dIn, w, h);

    __fp16 *half = malloc(n * sizeof(__fp16));
    for (size_t i = 0; i < n; i++) {
        float sdv = dOut[i] < 0.5f ? -(sqrtf(dIn[i]) - 0.5f) : (sqrtf(dOut[i]) - 0.5f);
        half[i] = (__fp16)fmaxf(-maxD, fminf(maxD, sdv));
    }
    free(dOut); free(dIn);

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [gDev newTextureWithDescriptor:td];
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:half bytesPerRow:(size_t)w * sizeof(__fp16)];
    free(half);
    return t;
}

#pragma mark presentation geometry

// Bounding box of `layer` in the coordinate space of `stop` (nil = the root layer, i.e. screen points), computed from the
// layers' PRESENTATION values so in-flight animations are included. Model values (what convertRect: uses) jump to the end
// of an animation at once, which is why a glass placed from them runs ahead of the portal-rendered stock clock.
static CGRect layerRectInAncestor(CALayer *layer, CALayer *stop) {
    CGRect b = layer.bounds;
    CGPoint pts[4] = { b.origin, CGPointMake(CGRectGetMaxX(b), b.origin.y), CGPointMake(b.origin.x, CGRectGetMaxY(b)), CGPointMake(CGRectGetMaxX(b), CGRectGetMaxY(b)) };
    for (CALayer *l = layer; l && l != stop; l = l.superlayer) {
        CALayer *pl = l.presentationLayer ?: l;
        CGRect lb = pl.bounds;
        CGAffineTransform t = CATransform3DGetAffineTransform(pl.transform);
        CGPoint an = CGPointMake(pl.anchorPoint.x * lb.size.width, pl.anchorPoint.y * lb.size.height);
        for (int i = 0; i < 4; i++) {
            CGPoint v = CGPointMake(pts[i].x - lb.origin.x - an.x, pts[i].y - lb.origin.y - an.y);
            v = CGPointApplyAffineTransform(v, t);
            pts[i] = CGPointMake(pl.position.x + v.x, pl.position.y + v.y);
        }
    }
    CGFloat x0 = pts[0].x, x1 = pts[0].x, y0 = pts[0].y, y1 = pts[0].y;
    for (int i = 1; i < 4; i++) {
        x0 = MIN(x0, pts[i].x); x1 = MAX(x1, pts[i].x);
        y0 = MIN(y0, pts[i].y); y1 = MAX(y1, pts[i].y);
    }
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

#pragma mark glass view

@interface CFGlassView : UIView
@property (nonatomic, strong) CALayer *backdrop;
@property (nonatomic, strong) CAShapeLayer *fillMask;
@property (nonatomic, strong) CAShapeLayer *tintShape;
@property (nonatomic, strong) CAGradientLayer *edgeGradient;
@property (nonatomic, strong) CAShapeLayer *edgeShape;
@property (nonatomic, strong) CAMetalLayer *metal;
@property (nonatomic, strong) id sdfTex;
@property (nonatomic, assign) float sdfToPx;
@property (nonatomic, assign) NSUInteger sdfToken;
@property (nonatomic, assign) BOOL dirty;
@property (nonatomic, assign) CGRect lastRect;
@property (nonatomic, assign) NSUInteger lastGen;
@property (nonatomic, strong) id blurFilter;
@property (nonatomic, strong) id satFilter;
@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, weak) UILabel *label;
@property (nonatomic, assign) CGRect screenRect;
- (instancetype)initGlass;
- (void)syncGeometry;
- (void)renderIfNeeded;
@end

@implementation CFGlassView
- (instancetype)initGlass {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = NO;
    self.backgroundColor = [UIColor clearColor];
    objc_setAssociatedObject(self, &kGlassMarkKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    Class bc = NSClassFromString(@"CABackdropLayer");
    _blurFilter = makeFilter(@"gaussianBlur");
    _satFilter = makeFilter(@"colorSaturate");
    if (!bc || !_blurFilter) return nil;
    @try { [_blurFilter setValue:@YES forKey:@"inputNormalizeEdges"]; } @catch (NSException *e) {}

    _backdrop = [bc layer];
    @try { [_backdrop setValue:@YES forKey:@"windowServerAware"]; } @catch (NSException *e) {}
    _fillMask = [CAShapeLayer layer];
    _fillMask.fillColor = [UIColor whiteColor].CGColor;
    _backdrop.mask = _fillMask;
    [self.layer addSublayer:_backdrop];

    _tintShape = [CAShapeLayer layer];
    [self.layer addSublayer:_tintShape];

    _edgeGradient = [CAGradientLayer layer];
    _edgeGradient.startPoint = CGPointMake(0.0, 0.0);
    _edgeGradient.endPoint = CGPointMake(1.0, 1.0);
    _edgeShape = [CAShapeLayer layer];
    _edgeShape.fillColor = nil;
    _edgeShape.strokeColor = [UIColor whiteColor].CGColor;
    _edgeShape.lineJoin = kCALineJoinRound;
    _edgeGradient.mask = _edgeShape;
    [self.layer addSublayer:_edgeGradient];

    if (gRefractOn) {
        _metal = [CAMetalLayer layer];
        _metal.device = gDev;
        _metal.pixelFormat = MTLPixelFormatBGRA8Unorm;
        _metal.framebufferOnly = YES;
        _metal.opaque = NO;
        _metal.contentsScale = gPxScale;
        [self.layer addSublayer:_metal];
    }
    return self;
}

// Place the glass exactly over the clock label, every frame. Position comes from presentation values. Alpha is the product
// of the layers between the label and the host's direct child: that child is the portal's source and sits at alpha 0 on
// purpose, so it is skipped; the host's own alpha/hidden state is inherited because the glass is its subview.
- (void)syncGeometry {
    UILabel *lab = self.label;
    UIView *host = self.superview;
    if (!lab || !host) { if (!self.hidden) self.hidden = YES; return; }
    CALayer *ll = lab.layer;
    CGFloat a = 1.0;
    BOOL hid = lab.hidden || lab.window == nil;
    for (CALayer *l = ll.superlayer; l && l.superlayer != host.layer; l = l.superlayer) {
        CALayer *pl = l.presentationLayer ?: l;
        a *= pl.opacity;
        if (l.hidden) hid = YES;
    }
    BOOL vis = !hid && a > 0.003;
    CGRect rh = layerRectInAncestor(ll, host.layer);
    _screenRect = layerRectInAncestor(ll, nil);
    CGSize sz = lab.bounds.size;
    CGPoint c = CGPointMake(CGRectGetMidX(rh), CGRectGetMidY(rh));
    CGFloat na = vis ? a : 0;
    if (self.hidden == vis) self.hidden = !vis;
    if (fabs(self.alpha - na) > 0.002) self.alpha = na;
    if (!CGSizeEqualToSize(self.bounds.size, sz)) self.bounds = CGRectMake(0, 0, sz.width, sz.height);
    if (fabs(self.center.x - c.x) > 0.01 || fabs(self.center.y - c.y) > 0.01) self.center = c;
}

// One draw of the glyph glass. Cheap when nothing changed: it returns before touching Metal.
- (void)renderIfNeeded {
    id<MTLTexture> sdf = self.sdfTex;
    if (!_metal || !sdf || !gPSO || self.hidden || !self.superview) return;
    CGRect r = _screenRect;
    if (!_dirty && _lastGen == gBgGen && CGRectEqualToRect(r, _lastRect)) return;
    CGSize pt = self.bounds.size;
    if (pt.width < 2 || pt.height < 2) return;
    CGSize want = CGSizeMake(ceil(pt.width * gPxScale), ceil(pt.height * gPxScale));
    if (!CGSizeEqualToSize(_metal.drawableSize, want)) _metal.drawableSize = want;
    id<CAMetalDrawable> dr = [_metal nextDrawable];
    if (!dr) return;
    stageBegin(@"render");
    _dirty = NO; _lastRect = r; _lastGen = gBgGen;

    id<MTLTexture> bgT = gBgFront >= 0 ? gBgTex[gBgFront] : nil;
    CGFloat sc = gPxScale;
    LGU u = {
        .size = simd_make_float2(want.width, want.height),
        .origin = simd_make_float2(r.origin.x * sc, r.origin.y * sc),
        .bgSize = bgT ? simd_make_float2(bgT.width, bgT.height) : simd_make_float2(1, 1),
        .refH = cfgNum(@"glassRefractHeight", 5.0) * sc,
        .refA = cfgNum(@"glassRefractAmount", 9.0) * sc,
        .chroma = cfgNum(@"glassChroma", 0.8),
        .scale = sc,
        .tint = cfgNum(@"glassTint", 0.10),
        .sat = cfgNum(@"glassRimSat", 1.25),
        .rim = cfgNum(@"glassRimStrength", 0.55),
        .glow = cfgNum(@"glassGlow", 0.05),
        .refMix = cfgNum(@"glassRefractMix", 0.7),
        .sdfToPx = self.sdfToPx,
        .blurPx = cfgNum(@"glassRimBlur", 1.5) * sc,
        .bgOn = bgT ? 1.0f : 0.0f,
    };
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dr.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLCommandBuffer> cb = [gQ commandBuffer];
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:gPSO];
    [en setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [en setFragmentTexture:sdf atIndex:0];
    [en setFragmentTexture:(bgT ?: sdf) atIndex:1];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [en endEncoding];
    [cb presentDrawable:dr];
    [cb commit];
    stageEnd(@"render");
    CFLogOnce(@"firstrender", @"metal: first render origin=(%.0f,%.0f) size=%.0fx%.0f bg=%d sdfToPx=%.2f", u.origin.x, u.origin.y, u.size.x, u.size.y, bgT ? 1 : 0, self.sdfToPx);
}
@end

#pragma mark capture

static BOOL anyGlassVisible(void) {
    for (UILabel *l in [gLabels allObjects]) {
        CFGlassView *g = objc_getAssociatedObject(l, &kGlassKey);
        if (g && g.superview && !g.hidden && l.window && !l.window.hidden && l.window.alpha > 0.01) return YES;
    }
    return NO;
}

typedef void (*CARenderDisplayFn)(uint32_t, CFStringRef, IOSurfaceRef, int, int);

static dispatch_queue_t gCapQ = nil;
static BOOL gCapBusy = NO;
static CFTimeInterval gCapDur = 0.012;

// Capture the whole display into the back buffer on a background queue. Nothing is hidden: the shader only samples pixels
// outside the digits (see fmain), where the glass is never drawn, so the capture has no glass in it and cannot flicker.
static void captureBackgroundAsync(void) {
    static CARenderDisplayFn fn = NULL;
    static BOOL tried = NO;
    static int logged = 0;
    if (!tried) {
        tried = YES;
        fn = (CARenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        if (!fn) CFLog(@"capture: CARenderServerRenderDisplay not found, refraction has no picture to bend");
    }
    if (!fn || !gMetalOK || gCapBusy) return;
    stageBegin(@"capture");
    if (!setupBgBuffers()) { stageEnd(@"capture"); return; }
    gCapBusy = YES;
    int back = (gBgFront == 0) ? 1 : 0;
    IOSurfaceRef surf = gBgSurf[back];
    if (!gCapQ) gCapQ = dispatch_queue_create("clockfont.capture", DISPATCH_QUEUE_SERIAL);
    dispatch_async(gCapQ, ^{
        CFTimeInterval t0 = CACurrentMediaTime();
        fn(0, CFSTR("LCD"), surf, 0, 0);
        double dt = CACurrentMediaTime() - t0;
        dispatch_async(dispatch_get_main_queue(), ^{
            gBgFront = back;
            gBgGen++;
            gLastCap = CACurrentMediaTime();
            gCapDur = gCapDur * 0.5 + dt * 0.5;
            gCapBusy = NO;
            stageEnd(@"capture");
            if (logged++ < 5) CFLog(@"capture #%d: %.1f ms on a background queue", logged, dt * 1000.0);
        });
    });
}

// Capture when the lock screen shows up and on requests, then every 1/glassLiveFPS seconds. The gap is never shorter than
// 3x the measured capture time, so the capture cannot eat more than about a third of a core.
static void serviceCapture(void) {
    if (!gRefractOn) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (!anyGlassVisible()) { gWasVisible = NO; return; }
    if (!gWasVisible) {
        gWasVisible = YES;
        gNeedCapture = YES;
        gCapDue = now + 0.15;
    }
    BOOL due = gNeedCapture && now >= gCapDue;
    CGFloat fps = cfgNum(@"glassLiveFPS", 15);
    if (!due && fps > 0 && now - gLastCap >= MAX(1.0 / fps, gCapDur * 3.0)) due = YES;
    if (due && !gCapBusy) {
        gNeedCapture = NO;
        captureBackgroundAsync();
    }
}

static void onRecapture(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gNeedCapture = YES;
        gCapDue = CACurrentMediaTime() + 0.8;
    });
}

#pragma mark display link driver

@interface CFGlassDriver : NSObject
+ (void)startIfNeeded;
+ (void)stop;
@end

static CADisplayLink *sLink = nil;

@implementation CFGlassDriver
+ (void)startIfNeeded {
    if (sLink || !gGlassOn) return;
    sLink = [CADisplayLink displayLinkWithTarget:(id)self selector:@selector(tick:)];
    NSInteger fps = (NSInteger)cfgNum(@"glassFPS", 60);
    if (fps > 0) sLink.preferredFramesPerSecond = fps;
    [sLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    CFLog(@"glass: display link started (%ld fps requested)", (long)fps);
}
+ (void)stop {
    [sLink invalidate];
    sLink = nil;
}
+ (void)tick:(CADisplayLink *)link {
    if (!gGlassOn) return;
    @autoreleasepool {
        CGFloat base = cfgNum(@"glassBaseAlpha", 0.30);
        NSArray *labels = [gLabels allObjects];
        for (UILabel *l in labels) {
            CFGlassView *g = objc_getAssociatedObject(l, &kGlassKey);
            if (!g || !g.superview) continue;
            [g syncGeometry];
            // The system can put the stock digits back to alpha 1 (wake, unlock); hold them at the dimmed value every frame.
            if (objc_getAssociatedObject(l, &kBaseAlphaKey) && fabs(l.alpha - base) > 0.005) l.alpha = base;
        }
        if (!gRefractOn) return;
        serviceCapture();
        for (UILabel *l in labels) {
            CFGlassView *g = objc_getAssociatedObject(l, &kGlassKey);
            if (g) [g renderIfNeeded];
        }
    }
}
@end

#pragma mark glass layout

// Outline of `text` in `font` as a path in label coordinates (y down). baselineY is measured from the label's top.
static CGPathRef newGlyphPath(NSString *text, UIFont *font, NSTextAlignment align, CGFloat boundsWidth, CGFloat baselineY) {
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:@{ (__bridge id)kCTFontAttributeName: font }];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    if (!line) return NULL;
    CGFloat lineW = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CGFloat x0 = 0;
    if (align == NSTextAlignmentCenter) x0 = (boundsWidth - lineW) / 2.0;
    else if (align == NSTextAlignmentRight) x0 = boundsWidth - lineW;

    CGMutablePathRef path = CGPathCreateMutable();
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFIndex n = CTRunGetGlyphCount(run);
        if (n <= 0) continue;
        CTFontRef rf = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        if (!rf) continue;
        CGGlyph glyphs[n];
        CGPoint pos[n];
        CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
        CTRunGetPositions(run, CFRangeMake(0, 0), pos);
        for (CFIndex i = 0; i < n; i++) {
            CGPathRef gp = CTFontCreatePathForGlyph(rf, glyphs[i], NULL);
            if (!gp) continue;
            CGAffineTransform t = CGAffineTransformMake(1, 0, 0, -1, x0 + pos[i].x, baselineY - pos[i].y);
            CGPathAddPath(path, &t, gp);
            CGPathRelease(gp);
        }
    }
    CFRelease(line);
    return path;
}

static UIView *glassHostFor(UILabel *label) {
    Class vc = NSClassFromString(@"BSUIVibrancyEffectView");
    if (!vc) return nil;
    UIView *v = label.superview;
    for (int i = 0; v && i < 8; i++, v = v.superview) if ([v isKindOfClass:vc]) return v;
    return nil;
}

static void removeGlass(UILabel *label) {
    CFGlassView *g = objc_getAssociatedObject(label, &kGlassKey);
    if (g) {
        g.sdfToken++;
        [g removeFromSuperview];
        objc_setAssociatedObject(label, &kGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber *orig = objc_getAssociatedObject(label, &kBaseAlphaKey);
    if (orig) {
        label.alpha = [orig doubleValue];
        objc_setAssociatedObject(label, &kBaseAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void updateGlass(UILabel *label) {
    if (!gGlassOn || !label || !isLiveClock(label)) return;
    UIView *host = glassHostFor(label);
    if (!host) {
        CFLogOnce([NSString stringWithFormat:@"nohost/%@", NSStringFromClass([label class])],
                  @"liquidGlass: %@ has no BSUIVibrancyEffectView ancestor, glass skipped for it", NSStringFromClass([label class]));
        return;
    }
    NSString *text = label.text.length ? label.text : label.attributedText.string;
    UIFont *font = label.font;
    CGRect lb = label.bounds;
    if (!text.length || !font || lb.size.width < 2 || lb.size.height < 2) return;

    CFGlassView *g = objc_getAssociatedObject(label, &kGlassKey);
    if (!g) {
        ensureMetal();
        stageBegin(@"glass");
        @try {
            Class FL = NSClassFromString(@"CAFilter");
            SEL ft = NSSelectorFromString(@"filterTypes");
            if (FL && [FL respondsToSelector:ft]) CFLogOnce(@"filtertypes", @"CAFilter types: %@", ((id (*)(id, SEL))objc_msgSend)(FL, ft));
        } @catch (NSException *e) {}
        g = [[CFGlassView alloc] initGlass];
        if (!g) {
            CFLog(@"liquidGlass: could not create glass view (CABackdropLayer/CAFilter missing?), turning glass off");
            gGlassOn = NO;
            stageEnd(@"glass");
            return;
        }
        objc_setAssociatedObject(label, &kGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [CFGlassDriver startIfNeeded];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ stageEnd(@"glass"); });
    }
    if (g.superview != host) [host addSubview:g];
    else if (host.subviews.lastObject != g) [host bringSubviewToFront:g];

    g.label = label;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g.bounds = CGRectMake(0, 0, lb.size.width, lb.size.height);
    [g syncGeometry];

    CGFloat blur = cfgNum(@"glassBlur", 8), sat = cfgNum(@"glassSaturation", 1.8);
    CGFloat tint = cfgNum(@"glassTint", 0.10), edge = cfgNum(@"glassEdge", 0.95), edgeW = cfgNum(@"glassEdgeWidth", 1.0);
    NSString *key = [NSString stringWithFormat:@"%@|%.2f|%.1f|%.1f|%ld|%.2f|%.2f|%.2f|%.2f|%.2f",
                     text, font.pointSize, lb.size.width, lb.size.height, (long)label.textAlignment, blur, sat, tint, edge, edgeW];
    if (![key isEqualToString:g.cacheKey]) {
        g.cacheKey = key;
        CGRect full = g.bounds;
        g.backdrop.frame = full;
        g.fillMask.frame = full;
        g.tintShape.frame = full;
        g.edgeGradient.frame = full;
        g.edgeShape.frame = full;
        if (g.metal) {
            g.metal.frame = full;
            g.metal.contentsScale = gPxScale;
        }

        @try { [g.blurFilter setValue:@(blur) forKey:@"inputRadius"]; } @catch (NSException *e) {}
        @try { [g.satFilter setValue:@(sat) forKey:@"inputAmount"]; } @catch (NSException *e) {}
        g.backdrop.filters = g.satFilter ? @[g.blurFilter, g.satFilter] : @[g.blurFilter];

        CGRect tr = [label textRectForBounds:lb limitedToNumberOfLines:1];
        CGFloat baseline = tr.origin.y + font.ascender;
        CGPathRef p = newGlyphPath(text, font, label.textAlignment, lb.size.width, baseline);
        if (p) {
            g.fillMask.path = p;
            g.tintShape.path = p;
            g.edgeShape.path = p;
            CFLogOnce([NSString stringWithFormat:@"glass/%@/%.0f", NSStringFromClass([label class]), font.pointSize],
                      @"liquidGlass: installed for %@ in %@, glyph box=%@ baseline=%.1f label=%@ refraction=%d",
                      NSStringFromClass([label class]), NSStringFromClass([host class]),
                      NSStringFromCGRect(CGPathGetBoundingBox(p)), baseline, NSStringFromCGRect(lb), (int)(g.metal != nil));

            if (g.metal) {
                // Distance field of the new outline, off the main thread; the Metal layer starts drawing when it lands.
                CGPathRef pc = CGPathCreateCopy(p);
                NSUInteger token = ++g.sdfToken;
                CGSize sz = lb.size;
                CGFloat sdfScale = MIN(gPxScale, 2.0);
                __weak CFGlassView *wg = g;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    CFTimeInterval t0 = CACurrentMediaTime();
                    id<MTLTexture> t = buildSDF(pc, sz, sdfScale, 48.0f);
                    CGPathRelease(pc);
                    double ms = (CACurrentMediaTime() - t0) * 1000.0;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        CFGlassView *s = wg;
                        if (!s || s.sdfToken != token) return;
                        CFLogOnce(@"sdf", @"metal: glyph SDF %s in %.1f ms (%.0fx%.0f pt at %.1f px/pt)", t ? "ok" : "FAILED", ms, sz.width, sz.height, sdfScale);
                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];
                        s.sdfTex = t;
                        s.sdfToPx = (float)(gPxScale / sdfScale);
                        s.dirty = YES;
                        if (t) { s.tintShape.hidden = YES; s.edgeGradient.hidden = YES; }
                        [CATransaction commit];
                    });
                });
            }
            CGPathRelease(p);
        }
        g.tintShape.fillColor = [UIColor colorWithWhite:1.0 alpha:tint].CGColor;
        g.edgeShape.lineWidth = edgeW;
        BOOL metalReady = (g.metal != nil && g.sdfTex != nil);
        g.tintShape.hidden = metalReady;
        g.edgeGradient.hidden = metalReady || edge <= 0.001 || edgeW <= 0.01;
        g.edgeGradient.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:edge].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:edge * 0.22].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:edge * 0.60].CGColor,
        ];
        g.edgeGradient.locations = @[@0.0, @0.5, @1.0];
    }
    [CATransaction commit];

    // Dim the stock vibrant digits so the glass reads as glass, not as a sticker on top of white text.
    if (!objc_getAssociatedObject(label, &kBaseAlphaKey)) {
        objc_setAssociatedObject(label, &kBaseAlphaKey, @(label.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat base = cfgNum(@"glassBaseAlpha", 0.30);
    if (fabs(label.alpha - base) > 0.005) label.alpha = base;
}

static void scheduleGlass(UILabel *l) {
    if (!gGlassOn || objc_getAssociatedObject(l, &kGlassPendKey)) return;
    objc_setAssociatedObject(l, &kGlassPendKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UILabel *weak = l;
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *s = weak;
        if (!s) return;
        objc_setAssociatedObject(s, &kGlassPendKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        updateGlass(s);
    });
}

// Which clock copies exist and where they are (screen points, presentation values). Logged when the picture changes, max 14 lines.
static void logClockPositions(void) {
    static int n = 0;
    static NSString *last = nil;
    if (n >= 14) return;
    NSMutableString *sb = [NSMutableString string];
    for (UILabel *l in [gLabels allObjects]) {
        if (!l.window || !isLiveClock(l)) continue;
        CGRect r = layerRectInAncestor(l.layer, nil);
        CFGlassView *g = objc_getAssociatedObject(l, &kGlassKey);
        [sb appendFormat:@"[%@ %.1f,%.1f %.1fx%.1f a=%.2f%@] ", NSStringFromClass([l.superview class]), r.origin.x, r.origin.y, r.size.width, r.size.height, l.alpha,
            g ? [NSString stringWithFormat:@" glass=%.1f,%.1f %.1fx%.1f", g.screenRect.origin.x, g.screenRect.origin.y, g.screenRect.size.width, g.screenRect.size.height] : @""];
    }
    if (!sb.length || [sb isEqualToString:last]) return;
    last = [sb copy];
    n++;
    CFLog(@"clock positions (screen pt): %@", sb);
}

static void updateAllGlass(void) {
    logClockPositions();
    if (!gGlassOn) return;
    for (UILabel *l in [gLabels allObjects]) if (l.window) updateGlass(l);
}

#pragma mark - restyle

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
    extendEffects(label);
    scheduleGlass(label);
}

static void applyToLabel(UILabel *label) {
    if (!gActive || !label) return;
    UIFont *cur = label.font;
    if (!cur || cur.pointSize < gMinPt) return;
    if (objc_getAssociatedObject(label, &kBusyKey)) return;
    if (isOurFont(cur)) {
        // Already styled: the text just changed (a new minute), so refresh the glass outline.
        if (gGlassOn && objc_getAssociatedObject(label, &kClockKey)) scheduleGlass(label);
        return;
    }
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
            dumpHierarchy(l);
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
    // Always drop the glass first: it is rebuilt below with the new numbers if still wanted.
    for (UILabel *l in [gLabels allObjects]) removeGlass(l);
    if (![gConfig[@"enabled"] boolValue]) {
        CFLog(@"enabled=false: new labels are left alone, respring to restore the stock font");
        gActive = NO;
        gGlassOn = NO;
        gRefractOn = NO;
        [CFGlassDriver stop];
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
    gGlassOn = [gConfig[@"liquidGlass"] boolValue] && !stageDisabled(@"glass") && glassSupported();
    gRefractWanted = gGlassOn && [gConfig[@"glassRefraction"] boolValue] && !stageDisabled(@"metal") && !stageDisabled(@"capture") && !stageDisabled(@"render");
    gRefractOn = gRefractWanted && gMetalOK;
    gNeedCapture = YES;
    gCapDue = CACurrentMediaTime() + 0.3;
    [CFGlassDriver stop];
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
- (void)layoutSubviews {
    %orig;
    if (isLiveClock(self)) {
        extendEffects(self);
        alignLayers();
        updateGlass(self);
    }
}
- (void)setBounds:(CGRect)bounds {
    if (!isLiveClock(self)) {
        %orig;
        return;
    }
    CGRect g = bounds;
    CGSize need = neededSize(self);
    CGFloat dw = 0, dh = 0;
    if (g.size.width < need.width) { dw = need.width - g.size.width; g.size.width = need.width; }
    if (g.size.height < need.height) { dh = need.height - g.size.height; g.size.height = need.height; }
    BOOL hadWidth = bounds.size.width > 1.0;
    %orig(g);
    // Bounds grow around the center. Keep the top edge, and for a zero-width label also the left edge.
    CGFloat sx = (dw > 0 && !hadWidth) ? dw / 2.0 : 0;
    if (sx != 0 || dh > 0) {
        CGPoint c = self.center;
        self.center = CGPointMake(c.x + sx, c.y + dh / 2.0);
    }
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.apple.springboard"] && ![bid isEqualToString:@"com.apple.PosterBoard"]) return;
        CFLog(@"ClockFont %@ starting in %@", VERSION, bid);
        stageInit();
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
        BOOL canGlass = glassSupported();
        gGlassOn = [gConfig[@"liquidGlass"] boolValue] && !stageDisabled(@"glass") && canGlass;
        gRefractWanted = gGlassOn && [gConfig[@"glassRefraction"] boolValue] && !stageDisabled(@"metal") && !stageDisabled(@"capture") && !stageDisabled(@"render");
        CFLog(@"liquidGlass: wanted=%@ supported=%d active=%d refraction wanted=%d (Metal is set up with the first glass view)", gConfig[@"liquidGlass"], (int)canGlass, (int)gGlassOn, (int)gRefractWanted);
        CFNotificationCenterRef dn = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dn, NULL, onRecapture, CFSTR("com.example.clockfont.recapture"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dn, NULL, onRecapture, CFSTR("com.apple.springboard.lockstate"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        gActive = YES;
        %init;

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(timer, ^{
            reloadIfChanged();
            alignLayers();
            updateAllGlass();
        });
        dispatch_resume(timer);
        objc_setAssociatedObject([NSBundle mainBundle], "ClockFontTimer", timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
