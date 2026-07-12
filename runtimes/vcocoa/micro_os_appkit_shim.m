// micro_os_appkit_shim.m — the vcocoa AppKit shim.
//
// Lets an UNMODIFIED macOS AppKit app run on micro-os/iOS. One set of NS* classes
// serves two kinds of app, decided by what the app puts in its window:
//
//   * Control apps (NSButton/NSTextField/NSStackView …) are emitted as a small
//     widget document and shown by the wm via micro_os_gui_*. (e.g. vcocoa-todo)
//   * Surface apps that host their own CALayer on the content view — most often a
//     CAMetalLayer they render into — get that view mounted as a real UIKit view
//     in a wm window, with touches delivered as NSEvents and NSApplication.run
//     driving the app's frame callback.
//
// Nothing here is renderer-specific: hosting a CAMetalLayer is just hosting a
// CALayer. Display always goes through the wm service (so wm must be running,
// exactly like the structural path).
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#import "micro_os.h"
#import "micro_os_gui_shim.h"

#import <objc/runtime.h>
#import <stdatomic.h>
#include <unistd.h>

NSApplication *NSApp = nil;

// Open a real platform view as a wm window (implemented in VCocoaRuntime.swift).
extern int32_t micro_os_vcocoa_open_platform_window(const char *title, void *view,
                                                    double width, double height);
// Change a shown window's title / permission ("Resize" off = fixed size).
extern void micro_os_vcocoa_set_window_title(int32_t windowID, const char *title);
extern void micro_os_vcocoa_set_window_permission(int32_t windowID, const char *key, int32_t enabled);
extern void micro_os_vcocoa_set_fullscreen(int32_t windowID, int32_t on);

static void MicroOSAppKitEmitView(micro_os_gui_window_t window, NSView *view);

enum {
    MicroOSKeyboardPhaseKeyDown = 0,
    MicroOSKeyboardPhaseKeyUp = 1,
    MicroOSKeyboardPhaseKeyRepeat = 2,
    MicroOSKeyboardPhaseModifiersChanged = 3,
};

enum {
    MicroOSKeyboardKeyText = 0,
    MicroOSKeyboardKeyTab = 1,
    MicroOSKeyboardKeyEscape = 2,
    MicroOSKeyboardKeyLeftArrow = 3,
    MicroOSKeyboardKeyDownArrow = 4,
    MicroOSKeyboardKeyUpArrow = 5,
    MicroOSKeyboardKeyRightArrow = 6,
    MicroOSKeyboardKeyDelete = 7,
    MicroOSKeyboardKeyReturn = 8,
    MicroOSKeyboardKeySpace = 9,
};

enum {
    MicroOSKeyboardModifierControl = 1 << 0,
    MicroOSKeyboardModifierOption = 1 << 1,
    MicroOSKeyboardModifierCommand = 1 << 2,
};

static NSMutableDictionary<NSString *, NSButton *> *MicroOSAppKitButtonsByID(void) {
    static NSMutableDictionary<NSString *, NSButton *> *buttons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ buttons = [NSMutableDictionary new]; });
    return buttons;
}

// ===========================================================================
//  Generic AppKit value/utility classes (no display-model dependency)
// ===========================================================================

// ---- NSEvent (mouse/keyboard, synthesized from UIKit touches) --------------
@interface NSEvent ()
+ (NSEvent *)microOSMouseEventAt:(CGPoint)loc;
+ (NSEvent *)microOSKeyEventWithCode:(unsigned short)code modifiers:(NSEventModifierFlags)mods;
+ (NSEvent *)microOSKeyEventWithCode:(unsigned short)code modifiers:(NSEventModifierFlags)mods characters:(NSString *)chars;
+ (NSEvent *)microOSKeyEventWithCode:(unsigned short)code modifiers:(NSEventModifierFlags)mods isARepeat:(BOOL)repeat;
+ (NSEvent *)microOSKeyEventWithCode:(unsigned short)code modifiers:(NSEventModifierFlags)mods characters:(NSString *)chars isARepeat:(BOOL)repeat;
+ (NSEvent *)microOSFlagsEventWithModifiers:(NSEventModifierFlags)mods;
@end

@implementation NSEvent {
    CGPoint _loc;
    unsigned short _key;
    NSEventModifierFlags _mods;
    NSString *_chars;
    CGFloat _dy;
    BOOL _repeat;
}
- (CGPoint)locationInWindow { return _loc; }
- (unsigned short)keyCode { return _key; }
- (NSEventModifierFlags)modifierFlags { return _mods; }
- (NSString *)characters { return _chars ?: @""; }
- (NSString *)charactersIgnoringModifiers { return _chars ?: @""; }
- (CGFloat)deltaY { return _dy; }
- (BOOL)isARepeat { return _repeat; }
+ (NSEvent *)microOSMouseEventAt:(CGPoint)loc {
    NSEvent *e = [NSEvent new]; e->_loc = loc; return e;
}
+ (NSEvent *)microOSKeyEventWithCode:(unsigned short)code modifiers:(NSEventModifierFlags)mods {
    return [self microOSKeyEventWithCode:code modifiers:mods characters:@"" isARepeat:NO];
}
+ (NSEvent *)microOSKeyEventWithCode:(unsigned short)code modifiers:(NSEventModifierFlags)mods characters:(NSString *)chars {
    return [self microOSKeyEventWithCode:code modifiers:mods characters:chars isARepeat:NO];
}
+ (NSEvent *)microOSKeyEventWithCode:(unsigned short)code modifiers:(NSEventModifierFlags)mods isARepeat:(BOOL)repeat {
    return [self microOSKeyEventWithCode:code modifiers:mods characters:@"" isARepeat:repeat];
}
+ (NSEvent *)microOSKeyEventWithCode:(unsigned short)code modifiers:(NSEventModifierFlags)mods characters:(NSString *)chars isARepeat:(BOOL)repeat {
    NSEvent *e = [NSEvent new]; e->_key = code; e->_mods = mods; e->_chars = [chars copy]; e->_repeat = repeat; return e;
}
+ (NSEvent *)microOSFlagsEventWithModifiers:(NSEventModifierFlags)mods {
    NSEvent *e = [NSEvent new]; e->_mods = mods; return e;
}
@end

// ---- NSColor / NSColorSpace / NSColorPanel ---------------------------------
@implementation NSColorSpace
+ (NSColorSpace *)sRGBColorSpace { return [NSColorSpace new]; }
@end

@implementation NSColor {
    CGFloat _r, _g, _b, _a;
}
+ (NSColor *)secondaryLabelColor { return [NSColor new]; }
+ (NSColor *)colorWithSRGBRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha {
    NSColor *c = [NSColor new];
    c->_r = red; c->_g = green; c->_b = blue; c->_a = alpha;
    return c;
}
- (NSColor *)colorUsingColorSpace:(NSColorSpace *)space { (void)space; return self; }
- (CGFloat)redComponent { return _r; }
- (CGFloat)greenComponent { return _g; }
- (CGFloat)blueComponent { return _b; }
@end

static UIViewController *microOSTopViewController(void);   // defined further below

static UIColor *microOSUIColorFromNS(NSColor *c) {
    if (!c) return UIColor.whiteColor;
    return [UIColor colorWithRed:c.redComponent green:c.greenComponent blue:c.blueComponent alpha:1.0];
}
static NSColor *microOSNSColorFromUI(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (c) [c getRed:&r green:&g blue:&b alpha:&a];
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

// A real system colour picker. gpu_pick_color seeds -color, calls
// -makeKeyAndOrderFront: then blocks on -[NSApp runModalForWindow:] until the
// picker is dismissed, then reads -color back. App code runs off-main (see
// -[NSApplication run]), so we present UIColorPickerViewController on the main
// thread and block the caller on a semaphore — mirroring NSAlert.
@interface NSColorPanel () <UIColorPickerViewControllerDelegate>
- (void)microOSWaitModal;
@end
@implementation NSColorPanel {
    NSColor *_color;
    dispatch_semaphore_t _modalSem;
}
+ (NSColorPanel *)sharedColorPanel {
    static NSColorPanel *panel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ panel = [NSColorPanel new]; });
    return panel;
}
- (NSColor *)color { return _color ?: [NSColor new]; }
- (void)setColor:(NSColor *)color { _color = color; }
- (void)makeKeyAndOrderFront:(id)sender {
    (void)sender;
    _modalSem = dispatch_semaphore_create(0);
    NSColor *seed = self.color;
    BOOL alpha = self.showsAlpha;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = microOSTopViewController();
        if (@available(iOS 14.0, *)) {
            if (!host) { [self microOSFinishModal]; return; }
            UIColorPickerViewController *picker = [UIColorPickerViewController new];
            picker.supportsAlpha = alpha;
            picker.selectedColor = microOSUIColorFromNS(seed);
            picker.delegate = self;   // self is the retained shared panel; weak delegate stays valid
            [host presentViewController:picker animated:YES completion:nil];
        } else {
            [self microOSFinishModal];   // no picker available: keep the seeded colour
        }
    });
}
// Runs on the app thread via -[NSApplication runModalForWindow:]; unblocks when the
// picker is dismissed on the main thread (or immediately if there is no host).
- (void)microOSWaitModal {
    dispatch_semaphore_t s = _modalSem;
    if (s) dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
}
- (void)microOSFinishModal {
    dispatch_semaphore_t s = _modalSem; _modalSem = nil;
    if (s) dispatch_semaphore_signal(s);
}
- (void)colorPickerViewController:(UIColorPickerViewController *)vc
                   didSelectColor:(UIColor *)color
                     continuously:(BOOL)continuously API_AVAILABLE(ios(14.0)) {
    (void)vc; (void)continuously;
    self.color = microOSNSColorFromUI(color);
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc API_AVAILABLE(ios(14.0)) {
    self.color = microOSNSColorFromUI(vc.selectedColor);
    [self microOSFinishModal];
}
@end

@implementation NSFont {
    NSString *_fontName;
}
+ (NSFont *)systemFontOfSize:(CGFloat)fontSize {
    (void)fontSize;
    NSFont *f = [NSFont new]; f->_fontName = @"System"; return f;
}
+ (NSFont *)fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    (void)fontSize;
    NSFont *f = [NSFont new]; f->_fontName = [fontName copy] ?: @"System"; return f;
}
+ (CGFloat)smallSystemFontSize { return 11.0; }
- (NSString *)fontName { return _fontName ?: @"System"; }
@end

// iOS has no modal NSFontPanel; the picker keeps the seeded font (no change) so
// the build runs. A real picker could use UIFontPickerVC later.
@implementation NSFontPanel
// Not a real wm window — the modal is faked (runModalForWindow: returns at once).
- (void)makeKeyAndOrderFront:(id)sender { (void)sender; }
@end

@implementation NSFontManager {
    NSFont *_selected;
}
+ (NSFontManager *)sharedFontManager {
    static NSFontManager *fm;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fm = [NSFontManager new]; });
    return fm;
}
- (void)setSelectedFont:(NSFont *)font isMultiple:(BOOL)flag { (void)flag; _selected = font; }
- (void)setTarget:(id)target { (void)target; }
- (void)setAction:(SEL)action { (void)action; }
- (NSFontPanel *)fontPanel:(BOOL)create { (void)create; return [NSFontPanel new]; }
- (NSFont *)convertFont:(NSFont *)font { return font; }
@end

// Front-most view controller to present a modal alert from. micro-os is a single
// app/address space, so the alert presents over whatever the wm desktop shows.
// Must be called on the main thread.
static UIViewController *microOSTopViewController(void) {
    UIWindow *key = nil, *anyWindow = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!anyWindow) anyWindow = w;
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    UIViewController *vc = (key ?: anyWindow).rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// A real modal alert backed by UIAlertController. App code (the VN engine) runs
// on its own thread — see -[NSApplication run] — so we present on the main thread
// and block the caller until a button is tapped, returning NSAlert*ButtonReturn
// for the i-th -addButtonWithTitle: in add order (first = 1000), matching AppKit.
@implementation NSAlert {
    NSMutableArray<NSString *> *_buttonTitles;
}
- (void)addButtonWithTitle:(NSString *)title {
    if (!title) return;
    if (!_buttonTitles) _buttonTitles = [NSMutableArray array];
    [_buttonTitles addObject:[title copy]];
}
- (NSModalResponse)runModal {
    NSArray<NSString *> *titles = _buttonTitles.count ? [_buttonTitles copy] : @[@"OK"];
    NSString *title = [self.messageText copy];
    NSString *message = [self.informativeText copy];
    __block NSModalResponse result = NSAlertFirstButtonReturn;
    __block BOOL done = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_block_t present = ^{
        UIViewController *host = microOSTopViewController();
        if (!host) { done = YES; dispatch_semaphore_signal(sem); return; }
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
        for (NSUInteger i = 0; i < titles.count; i++) {
            NSModalResponse code = NSAlertFirstButtonReturn + (NSModalResponse)i;
            [ac addAction:[UIAlertAction actionWithTitle:titles[i]
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
                (void)action; result = code; done = YES; dispatch_semaphore_signal(sem);
            }]];
        }
        [host presentViewController:ac animated:YES completion:nil];
    };

    if ([NSThread isMainThread]) {
        // App code runs off-main, but stay safe if ever called on main: present
        // and pump the runloop until tapped rather than deadlocking.
        present();
        while (!done) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), present);
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    }
    return result;
}
@end

@implementation NSWorkspace
+ (NSWorkspace *)sharedWorkspace {
    static NSWorkspace *ws;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ws = [NSWorkspace new]; });
    return ws;
}
- (BOOL)openURL:(NSURL *)url {
    if (!url) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    });
    return YES;
}
@end

@implementation NSTrackingArea
- (instancetype)initWithRect:(NSRect)rect
                     options:(NSTrackingAreaOptions)options
                       owner:(id)owner
                    userInfo:(NSDictionary *)userInfo {
    (void)rect; (void)options; (void)owner; (void)userInfo;
    return [super init];
}
@end

// ===========================================================================
//  Real-surface backing + frame driver
// ===========================================================================

// The UIKit view that backs an NSView: hosts the app's CALayer and forwards
// touches to the owning NSView's mouse methods.
@interface MicroOSBackingView : UIView <UIKeyInput>
@property(nonatomic, weak) NSView *owner;
@property(nonatomic, strong) CALayer *hostedLayer;
@property(nonatomic) CGSize logical;
@property(nonatomic) NSEventModifierFlags keyMods;   // tracked for flagsChanged:
@property(nonatomic) BOOL softKeyboardOn;            // wm keyboard button toggles this
@property(nonatomic) int32_t keyboardSinkID;
@property(nonatomic, strong) NSMutableDictionary *keyRepeatTimers;  // @(MicroOSKeyboardKey*) -> repeat source
@property(nonatomic, strong) UIView *softKeyboardAccessory;
@property(nonatomic, weak) UIButton *softControlButton;
@property(nonatomic, weak) UIButton *softOptionButton;
@property(nonatomic, weak) UIButton *softCommandButton;
@end

static uint32_t microOSKeyboardModifiersFromNSEvent(NSEventModifierFlags mods) {
    uint32_t result = 0;
    if (mods & NSEventModifierFlagControl) result |= MicroOSKeyboardModifierControl;
    if (mods & NSEventModifierFlagOption) result |= MicroOSKeyboardModifierOption;
    if (mods & NSEventModifierFlagCommand) result |= MicroOSKeyboardModifierCommand;
    return result;
}

static NSEventModifierFlags microOSNSEventModifiersFromKeyboard(uint32_t mods) {
    NSEventModifierFlags result = 0;
    if (mods & MicroOSKeyboardModifierControl) result |= NSEventModifierFlagControl;
    if (mods & MicroOSKeyboardModifierOption) result |= NSEventModifierFlagOption;
    if (mods & MicroOSKeyboardModifierCommand) result |= NSEventModifierFlagCommand;
    return result;
}

static int32_t microOSKeyboardKeyForHID(UIKeyboardHIDUsage hid) {
    switch (hid) {
        case UIKeyboardHIDUsageKeyboardReturnOrEnter:
        case UIKeyboardHIDUsageKeypadEnter:
            return MicroOSKeyboardKeyReturn;
        case UIKeyboardHIDUsageKeyboardSpacebar:
            return MicroOSKeyboardKeySpace;
        case UIKeyboardHIDUsageKeyboardEscape:
            return MicroOSKeyboardKeyEscape;
        case UIKeyboardHIDUsageKeyboardUpArrow:
            return MicroOSKeyboardKeyUpArrow;
        case UIKeyboardHIDUsageKeyboardDownArrow:
            return MicroOSKeyboardKeyDownArrow;
        case UIKeyboardHIDUsageKeyboardLeftArrow:
            return MicroOSKeyboardKeyLeftArrow;
        case UIKeyboardHIDUsageKeyboardRightArrow:
            return MicroOSKeyboardKeyRightArrow;
        default:
            return MicroOSKeyboardKeyText;
    }
}

static unsigned short microOSMacKeyCodeForKeyboardKey(int32_t key) {
    switch (key) {
        case MicroOSKeyboardKeyReturn:     return 36;
        case MicroOSKeyboardKeySpace:      return 49;
        case MicroOSKeyboardKeyEscape:     return 53;
        case MicroOSKeyboardKeyUpArrow:    return 126;
        case MicroOSKeyboardKeyDownArrow:  return 125;
        case MicroOSKeyboardKeyLeftArrow:  return 123;
        case MicroOSKeyboardKeyRightArrow: return 124;
        case MicroOSKeyboardKeyDelete:     return 51;
        case MicroOSKeyboardKeyTab:        return 48;
        default:                           return 0;
    }
}

static void microOSBackingKeyboardSinkCallback(int32_t phase, int32_t key, uint32_t modifiers, const char *text, void *context);

@implementation MicroOSBackingView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Pointer hover (iPad trackpad / mouse, and Apple Pencil hover on M2+
        // iPads) -> -mouseMoved:, so hover-driven UI such as menu highlights works
        // like on a Mac. Harmless where there is no pointer (plain iPhone touch).
        UIHoverGestureRecognizer *hover =
            [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(microOSHover:)];
        [self addGestureRecognizer:hover];
        _keyboardSinkID = micro_os_keyboard_device_subscribe(microOSBackingKeyboardSinkCallback, (__bridge void *)self);
    }
    return self;
}
- (void)dealloc {
    if (_keyboardSinkID >= 0) micro_os_keyboard_device_unsubscribe(_keyboardSinkID);
}
- (void)microOSHover:(UIHoverGestureRecognizer *)g {
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            [self.owner mouseMoved:[NSEvent microOSMouseEventAt:[self logicalPointForLocation:[g locationInView:self]]]];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            // Hover also "ends" the instant a click begins (the pointer makes
            // contact). Only treat it as the pointer LEAVING — and clear the cursor
            // — when it is actually outside the surface; otherwise this mouseExited
            // would wipe the click's -mouseDown: cursor before the game's frame loop
            // reads g_click_pending, making the click miss ("need to click twice").
            CGPoint p = [g locationInView:self];
            if (!CGRectContainsPoint(self.bounds, p)) {
                [self.owner mouseExited:[NSEvent microOSMouseEventAt:CGPointMake(-1, -1)]];
            }
            break;
        }
        default:
            break;
    }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.hostedLayer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.hostedLayer.frame = self.bounds;
        [CATransaction commit];
    }
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    // -layoutSubviews (which sizes the hosted Metal layer) is otherwise deferred by
    // UIKit until the first touch — leaving the surface black until the user taps,
    // since the layer has no correct size to draw into. Force a layout pass now so
    // the first rendered frame is visible immediately.
    [self.window layoutIfNeeded];
    [self setNeedsLayout];
    [self layoutIfNeeded];
}
- (CGPoint)logicalPointFor:(UITouch *)t {
    return [self logicalPointForLocation:[t locationInView:self]];
}
- (CGPoint)logicalPointForLocation:(CGPoint)p {
    CGFloat bw = self.bounds.size.width, bh = self.bounds.size.height;
    CGFloat lw = self.logical.width, lh = self.logical.height;
    if (bw <= 0 || bh <= 0 || lw <= 0 || lh <= 0) return CGPointMake(-1, -1);
    // The layer draws the content with kCAGravityResizeAspect — scaled to fit and
    // centered, so it is letterboxed whenever the view's aspect differs from the
    // content's (e.g. a 4:3 game in a tall fullscreen view). Map the touch relative
    // to that displayed rect, not the whole view, or hit-testing drifts; touches on
    // the bars return (-1,-1) (no hit), matching where there is no content.
    CGFloat scale = MIN(bw / lw, bh / lh);
    CGFloat cw = lw * scale, ch = lh * scale;
    CGFloat ox = (bw - cw) * 0.5, oy = (bh - ch) * 0.5;
    CGFloat lx = (p.x - ox) / scale, ly = (p.y - oy) / scale;
    if (lx < 0 || ly < 0 || lx > lw || ly > lh) return CGPointMake(-1, -1);
    return CGPointMake(lx, ly);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.owner mouseDown:[NSEvent microOSMouseEventAt:[self logicalPointFor:touches.anyObject]]];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSEvent *e = [NSEvent microOSMouseEventAt:[self logicalPointFor:touches.anyObject]];
    [self.owner mouseDragged:e];
    [self.owner mouseMoved:e];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.owner mouseUp:[NSEvent microOSMouseEventAt:[self logicalPointFor:touches.anyObject]]];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.owner mouseUp:[NSEvent microOSMouseEventAt:CGPointMake(-1, -1)]];
}

// ---- keyboard input -------------------------------------------------------
// wm toggles this view's first-responder state (its keyboard button); being first
// responder enables hardware keys (-pressesBegan:) and shows the system soft
// keyboard (UIKeyInput). Both are translated to AppKit NSEvents and forwarded to
// the owning NSView's -keyDown:/-keyUp:/-flagsChanged:, like a real Mac app.
- (BOOL)canBecomeFirstResponder { return YES; }

// Ctrl held -> -flagsChanged: (the engine's skip/advance). Hardware and soft
// keys both pass through the kernel keyboard sink before they become NSEvents.
- (void)microOSApplyModifiers:(NSEventModifierFlags)mods {
    if (mods == self.keyMods) return;
    self.keyMods = mods;
    [self.owner flagsChanged:[NSEvent microOSFlagsEventWithModifiers:mods]];
    [self microOSUpdateSoftKeyboardModifierButtons];
}
- (void)microOSDispatchModifiers:(NSEventModifierFlags)mods {
    micro_os_keyboard_device_input(
        MicroOSKeyboardPhaseModifiersChanged,
        MicroOSKeyboardKeyText,
        microOSKeyboardModifiersFromNSEvent(mods),
        ""
    );
}
- (void)microOSDispatchKey:(int32_t)key phase:(int32_t)phase text:(NSString *)text {
    micro_os_keyboard_device_input(
        phase,
        key,
        microOSKeyboardModifiersFromNSEvent(self.keyMods),
        text.UTF8String ?: ""
    );
}
- (void)microOSReceiveKernelKeyboardPhase:(int32_t)phase key:(int32_t)key modifiers:(uint32_t)modifiers text:(NSString *)text {
    NSEventModifierFlags mods = microOSNSEventModifiersFromKeyboard(modifiers);
    if (phase == MicroOSKeyboardPhaseModifiersChanged) {
        [self microOSApplyModifiers:mods];
        return;
    }

    unsigned short code = microOSMacKeyCodeForKeyboardKey(key);
    if (phase == MicroOSKeyboardPhaseKeyUp) {
        [self.owner keyUp:[NSEvent microOSKeyEventWithCode:code modifiers:mods characters:text ?: @""]];
    } else {
        BOOL repeat = phase == MicroOSKeyboardPhaseKeyRepeat;
        [self.owner keyDown:[NSEvent microOSKeyEventWithCode:code modifiers:mods characters:text ?: @"" isARepeat:repeat]];
    }
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    for (UIPress *press in presses) {
        UIKey *key = press.key; if (!key) continue;
        [self microOSDispatchModifiers:(NSEventModifierFlags)key.modifierFlags];
        int32_t keyboardKey = microOSKeyboardKeyForHID(key.keyCode);
        [self microOSDispatchKey:keyboardKey phase:MicroOSKeyboardPhaseKeyDown text:key.charactersIgnoringModifiers ?: @""];
        // iOS delivers a single press; macOS auto-repeats a held key. Start a timer
        // so a held key keeps sending -keyDown: like macOS would (modifiers excluded).
        if (keyboardKey != MicroOSKeyboardKeyText) [self microOSStartRepeat:keyboardKey];
        handled = YES;
    }
    if (!handled) [super pressesBegan:presses withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    for (UIPress *press in presses) {
        UIKey *key = press.key; if (!key) continue;
        [self microOSDispatchModifiers:(NSEventModifierFlags)key.modifierFlags];
        int32_t keyboardKey = microOSKeyboardKeyForHID(key.keyCode);
        [self microOSStopRepeat:keyboardKey];
        [self microOSDispatchKey:keyboardKey phase:MicroOSKeyboardPhaseKeyUp text:key.charactersIgnoringModifiers ?: @""];
        handled = YES;
    }
    if (!handled) [super pressesEnded:presses withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self microOSStopAllRepeats];
    [super pressesCancelled:presses withEvent:event];
}
- (BOOL)resignFirstResponder {
    [self microOSStopAllRepeats];   // a key may still be down when focus leaves
    return [super resignFirstResponder];
}
// macOS-style auto-repeat: after an initial delay, re-send -keyDown: at a fixed
// rate until the key is released. Timers run on the main queue (where presses and
// the keyDown forwarding already happen).
- (void)microOSStartRepeat:(int32_t)key {
    if (!self.keyRepeatTimers) self.keyRepeatTimers = [NSMutableDictionary dictionary];
    [self microOSStopRepeat:key];
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),   // delay until repeat
        (uint64_t)(0.05 * NSEC_PER_SEC),                                    // repeat interval
        (uint64_t)(0.01 * NSEC_PER_SEC));
    __weak MicroOSBackingView *weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        MicroOSBackingView *s = weakSelf; if (!s) return;
        [s microOSDispatchKey:key phase:MicroOSKeyboardPhaseKeyRepeat text:@""];
    });
    dispatch_resume(t);
    self.keyRepeatTimers[@(key)] = t;
}
- (void)microOSStopRepeat:(int32_t)key {
    dispatch_source_t t = self.keyRepeatTimers[@(key)];
    if (t) { dispatch_source_cancel(t); [self.keyRepeatTimers removeObjectForKey:@(key)]; }
}
- (void)microOSStopAllRepeats {
    for (id key in [self.keyRepeatTimers allKeys]) {
        dispatch_source_t t = self.keyRepeatTimers[key];
        if (t) dispatch_source_cancel(t);
    }
    [self.keyRepeatTimers removeAllObjects];
}

// UIKeyInput: the system soft keyboard. For this app only space/return matter
// (advance); other characters still send a -keyDown: (code 0) and are ignored.
- (BOOL)hasText { return NO; }
- (void)insertText:(NSString *)text {
    int32_t key = MicroOSKeyboardKeyText;
    if ([text isEqualToString:@" "]) key = MicroOSKeyboardKeySpace;
    else if ([text isEqualToString:@"\n"] || [text isEqualToString:@"\r"]) key = MicroOSKeyboardKeyReturn;
    [self microOSSendSoftKey:key text:text ?: @""];
}
- (void)deleteBackward {
    [self microOSSendSoftKey:MicroOSKeyboardKeyDelete text:@""];
}
- (UIKeyboardType)keyboardType { return UIKeyboardTypeDefault; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
// Being first responder is what routes hardware keys here (wm makes the active
// window's surface first responder). Whether the system SOFT keyboard shows is
// separate: an empty inputView hides it (hardware keys still work); nil shows it.
// The wm keyboard button flips this — so it never affects hardware keys.
- (UIView *)inputView {
    if (self.softKeyboardOn) return nil;                 // system soft keyboard
    static UIView *empty;
    if (!empty) empty = [[UIView alloc] initWithFrame:CGRectZero];
    return empty;                                        // no soft keyboard
}
- (UIView *)inputAccessoryView {
    if (!self.softKeyboardOn) return nil;
    return [self microOSSoftKeyboardAccessory];
}
- (void)microOSToggleSoftKeyboard {
    self.softKeyboardOn = !self.softKeyboardOn;
    if (!self.softKeyboardOn) [self microOSClearSoftKeyboardModifiers];
    if ([self isFirstResponder]) [self reloadInputViews];
    else [self becomeFirstResponder];
}
- (void)microOSSendSoftKey:(int32_t)key text:(NSString *)text {
    [self microOSDispatchKey:key phase:MicroOSKeyboardPhaseKeyDown text:text];
    [self microOSDispatchKey:key phase:MicroOSKeyboardPhaseKeyUp text:text];
    [self microOSClearSoftKeyboardModifiers];
}
- (UIView *)microOSSoftKeyboardAccessory {
    if (self.softKeyboardAccessory) return self.softKeyboardAccessory;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 58)];
    container.backgroundColor = UIColor.clearColor;
    [container addSubview:blur];
    [container.heightAnchor constraintEqualToConstant:58].active = YES;

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    [blur.contentView addSubview:scroll];

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    NSArray<NSArray<id> *> *keys = @[
        @[@"mod", @"Ctrl", @"control", @(MicroOSKeyboardModifierControl)],
        @[@"mod", @"Option", @"option", @(MicroOSKeyboardModifierOption)],
        @[@"mod", @"Command", @"command", @(MicroOSKeyboardModifierCommand)],
        @[@"key", @"Tab", @"arrow.right.to.line", @(MicroOSKeyboardKeyTab)],
        @[@"key", @"Esc", @"escape", @(MicroOSKeyboardKeyEscape)],
        @[@"key", @"Left", @"arrow.left", @(MicroOSKeyboardKeyLeftArrow)],
        @[@"key", @"Down", @"arrow.down", @(MicroOSKeyboardKeyDownArrow)],
        @[@"key", @"Up", @"arrow.up", @(MicroOSKeyboardKeyUpArrow)],
        @[@"key", @"Right", @"arrow.right", @(MicroOSKeyboardKeyRightArrow)],
    ];

    for (NSArray<id> *key in keys) {
        UIButton *button = [self microOSSoftKeyboardButtonWithTitle:key[1] symbol:key[2]];
        [stack addArrangedSubview:button];
        [button.widthAnchor constraintEqualToConstant:50].active = YES;
        [button.heightAnchor constraintEqualToConstant:38].active = YES;

        if ([key[0] isEqual:@"mod"]) {
            button.tag = [key[3] unsignedIntegerValue];
            [button addTarget:self action:@selector(microOSSoftKeyboardModifierTapped:) forControlEvents:UIControlEventTouchUpInside];
            if ([key[1] isEqual:@"Ctrl"]) self.softControlButton = button;
            else if ([key[1] isEqual:@"Option"]) self.softOptionButton = button;
            else if ([key[1] isEqual:@"Command"]) self.softCommandButton = button;
        } else {
            button.tag = [key[3] integerValue];
            [button addTarget:self action:@selector(microOSSoftKeyboardKeyTapped:) forControlEvents:UIControlEventTouchUpInside];
        }
    }

    UILayoutGuide *content = scroll.contentLayoutGuide;
    UILayoutGuide *frame = scroll.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [blur.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [blur.topAnchor constraintEqualToAnchor:container.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],

        [scroll.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor],

        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [stack.heightAnchor constraintEqualToAnchor:frame.heightAnchor],
    ]];

    self.softKeyboardAccessory = container;
    [self microOSUpdateSoftKeyboardModifierButtons];
    return container;
}
- (UIButton *)microOSSoftKeyboardButtonWithTitle:(NSString *)title symbol:(NSString *)symbol {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.image = [UIImage systemImageNamed:symbol];
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
    config.imagePlacement = NSDirectionalRectEdgeTop;
    config.baseBackgroundColor = [UIColor.secondarySystemFillColor colorWithAlphaComponent:0.68];
    config.baseForegroundColor = UIColor.labelColor;
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    button.configuration = config;
    button.accessibilityLabel = title;
    button.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.35].CGColor;
    button.layer.borderWidth = 0.5;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    return button;
}
- (void)microOSSoftKeyboardModifierTapped:(UIButton *)sender {
    uint32_t flag = (uint32_t)sender.tag;
    uint32_t mods = microOSKeyboardModifiersFromNSEvent(self.keyMods);
    mods = (mods & flag) ? (mods & ~flag) : (mods | flag);
    [self microOSDispatchModifiers:microOSNSEventModifiersFromKeyboard(mods)];
}
- (void)microOSSoftKeyboardKeyTapped:(UIButton *)sender {
    [self microOSSendSoftKey:(int32_t)sender.tag text:@""];
}
- (void)microOSClearSoftKeyboardModifiers {
    uint32_t mods = microOSKeyboardModifiersFromNSEvent(self.keyMods);
    mods &= ~(MicroOSKeyboardModifierControl | MicroOSKeyboardModifierOption | MicroOSKeyboardModifierCommand);
    [self microOSDispatchModifiers:microOSNSEventModifiersFromKeyboard(mods)];
}
- (void)microOSUpdateSoftKeyboardModifierButtons {
    [self microOSUpdateSoftKeyboardButton:self.softControlButton active:(self.keyMods & NSEventModifierFlagControl) != 0];
    [self microOSUpdateSoftKeyboardButton:self.softOptionButton active:(self.keyMods & NSEventModifierFlagOption) != 0];
    [self microOSUpdateSoftKeyboardButton:self.softCommandButton active:(self.keyMods & NSEventModifierFlagCommand) != 0];
}
- (void)microOSUpdateSoftKeyboardButton:(UIButton *)button active:(BOOL)active {
    if (!button) return;
    UIButtonConfiguration *config = button.configuration;
    config.baseBackgroundColor = active
        ? [UIColor.systemBlueColor colorWithAlphaComponent:0.72]
        : [UIColor.secondarySystemFillColor colorWithAlphaComponent:0.68];
    config.baseForegroundColor = active ? UIColor.whiteColor : UIColor.labelColor;
    button.configuration = config;
}
@end

static void microOSBackingKeyboardSinkCallback(int32_t phase, int32_t key, uint32_t modifiers, const char *text, void *context) {
    MicroOSBackingView *view = (__bridge MicroOSBackingView *)context;
    NSString *value = text ? [NSString stringWithUTF8String:text] : @"";
    [view microOSReceiveKernelKeyboardPhase:phase key:key modifiers:modifiers text:value ?: @""];
}

// A frame callback the app installed via NSView -displayLinkWithTarget:selector:;
// NSApplication.run invokes it directly so it never depends on a CADisplayLink
// firing on a non-main run loop.
static __weak id g_frameTarget;
static SEL g_frameSel;

// The shown surface window, and a flag the wm sets (via the runtime) when the
// user taps the wm window's close (X) button. The run loop drains the flag and
// runs -performClose: on the app's own thread so windowShouldClose: (the app's
// quit confirm) fires — exactly like the title "Exit" path.
static __weak NSWindow *g_surfaceWindow;
static _Atomic int g_closeRequested;

// Called (from the wm thread, via the vcocoa runtime's close handler) when the
// window's X button is tapped. Just flags it; the app thread acts on it.
void micro_os_appkit_request_close(int32_t windowID) {
    (void)windowID;   // one surface window per process
    atomic_store(&g_closeRequested, 1);
}

static inline void microOSRunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

// Called when the wm keyboard button is tapped: show/hide the soft keyboard for
// this surface (hardware keys are unaffected — they follow first-responder state,
// which wm drives from the active window).
void micro_os_appkit_toggle_soft_keyboard(void *surfaceView) {
    if (!surfaceView) return;
    MicroOSBackingView *bv = (__bridge MicroOSBackingView *)surfaceView;
    microOSRunOnMain(^{ [bv microOSToggleSoftKeyboard]; });
}

// ===========================================================================
//  NSView — real UIKit-backed; tracks structural children for the emit path
// ===========================================================================
@interface NSView ()
- (UIView *)microOSBackingView;
- (BOOL)microOSHasHostedLayer;
@end

@implementation NSView {
    MicroOSBackingView *_backing;
    CALayer *_hostedLayer;
    NSMutableArray<NSView *> *_subviews;
    NSRect _frame;
    BOOL _wantsLayer;
}

- (instancetype)init { return [self initWithFrame:CGRectZero]; }

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super init];
    if (self) {
        _frame = frame;
        _subviews = [NSMutableArray new];
        CGRect r = CGRectMake(0, 0, frame.size.width, frame.size.height);
        __weak NSView *weakSelf = self;
        microOSRunOnMain(^{
            MicroOSBackingView *bv = [[MicroOSBackingView alloc] initWithFrame:r];
            bv.owner = weakSelf;
            bv.logical = CGSizeMake(frame.size.width, frame.size.height);
            bv.opaque = YES;
            bv.multipleTouchEnabled = NO;
            bv.userInteractionEnabled = YES;
            bv.backgroundColor = [UIColor blackColor];
            self->_backing = bv;
        });
    }
    return self;
}

- (UIView *)microOSBackingView { return _backing; }
- (BOOL)microOSHasHostedLayer { return _hostedLayer != nil; }

- (void)addSubview:(NSView *)view {
    if (!view) return;
    [_subviews addObject:view];
    UIView *child = [view microOSBackingView];
    MicroOSBackingView *bv = _backing;
    if (child && bv) {
        // Synchronous so the real view hierarchy is consistent before an app
        // activates Auto Layout constraints between these views (UIKit throws if
        // the views have no common ancestor yet). Harmless for the structural
        // emit path, which never mounts these backing views.
        microOSRunOnMain(^{
            child.translatesAutoresizingMaskIntoConstraints = NO;
            [bv addSubview:child];
        });
    }
}

- (NSArray<NSView *> *)microOSSubviews { return [_subviews copy]; }

- (NSRect)frame { return _frame; }
- (void)setFrame:(NSRect)f { _frame = f; }
- (NSRect)bounds { return CGRectMake(0, 0, _frame.size.width, _frame.size.height); }

- (void)setWantsLayer:(BOOL)w { _wantsLayer = w; }
- (BOOL)wantsLayer { return _wantsLayer; }

- (CALayer *)layer { return _hostedLayer; }
- (void)setLayer:(CALayer *)layer {
    _hostedLayer = layer;
    MicroOSBackingView *bv = _backing;
    dispatch_block_t add = ^{
        bv.hostedLayer = layer;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        // Preserve a fixed render resolution / aspect (e.g. 800x600): letterbox
        // within whatever size the window gives us instead of stretching.
        layer.contentsGravity = kCAGravityResizeAspect;
        layer.frame = bv.bounds;
        [bv.layer addSublayer:layer];
        [CATransaction commit];
    };
    if ([NSThread isMainThread]) add(); else dispatch_async(dispatch_get_main_queue(), add);
}

- (BOOL)isFlipped { return NO; }                 // app NSView subclass overrides
- (BOOL)acceptsFirstResponder { return NO; }
- (void)addTrackingArea:(NSTrackingArea *)trackingArea { (void)trackingArea; }
- (NSPoint)convertPoint:(NSPoint)point fromView:(NSView *)view { (void)view; return point; }

// Auto Layout anchors map to the real backing view's anchors. The structural
// emit ignores layout, so for control apps these constraints are harmless.
- (NSLayoutAnchor *)topAnchor { return _backing.topAnchor; }
- (NSLayoutAnchor *)leadingAnchor { return _backing.leadingAnchor; }
- (NSLayoutAnchor *)trailingAnchor { return _backing.trailingAnchor; }
- (NSLayoutAnchor *)bottomAnchor { return _backing.bottomAnchor; }

- (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector {
    g_frameTarget = target;
    g_frameSel = selector;
    // Returned paused so the caller's addToRunLoop is a no-op; NSApplication.run
    // drives the target directly.
    CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:target selector:selector];
    dl.paused = YES;
    return dl;
}

// Base no-op event handlers; an app's NSView subclass overrides what it needs.
- (void)mouseMoved:(NSEvent *)event { (void)event; }
- (void)mouseDragged:(NSEvent *)event { (void)event; }
- (void)mouseExited:(NSEvent *)event { (void)event; }
- (void)mouseDown:(NSEvent *)event { (void)event; }
- (void)mouseUp:(NSEvent *)event { (void)event; }
- (void)scrollWheel:(NSEvent *)event { (void)event; }
- (void)rightMouseDown:(NSEvent *)event { (void)event; }
- (void)keyDown:(NSEvent *)event { (void)event; }
- (void)keyUp:(NSEvent *)event { (void)event; }
- (void)flagsChanged:(NSEvent *)event { (void)event; }
@end

// ---- structural control views ----------------------------------------------
@implementation NSStackView {
    NSMutableArray<NSView *> *_arrangedSubviews;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) { _arrangedSubviews = [NSMutableArray new]; }
    return self;
}
- (void)addArrangedSubview:(NSView *)view {
    if (view) { [_arrangedSubviews addObject:view]; [self addSubview:view]; }
}
- (NSArray<NSView *> *)microOSArrangedSubviews { return [_arrangedSubviews copy]; }
@end

@implementation NSTextField
+ (NSTextField *)labelWithString:(NSString *)stringValue {
    NSTextField *field = [NSTextField new];
    field.stringValue = stringValue;
    return field;
}
@end

@implementation NSButton
+ (NSButton *)buttonWithTitle:(NSString *)title target:(id)target action:(SEL)action {
    NSButton *button = [NSButton new];
    button.title = title;
    button.target = target;
    button.action = action;
    return button;
}
@end

@implementation NSBox
@end

// ===========================================================================
//  NSWindow — surface app -> wm window of the real view; control app -> emit
// ===========================================================================
@implementation NSWindow {
    NSString *_title;
    NSView *_contentView;
    NSRect _contentRect;
    NSWindowStyleMask _styleMask;
    micro_os_gui_window_t _structuralWindow;
    int32_t _surfaceWindowID;
    BOOL _mounted;
}

// Title changes after the window is shown are pushed to the wm window.
- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)title {
    _title = [title copy];
    if (_surfaceWindowID >= 0) {
        const char *t = _title.UTF8String;
        if (t) micro_os_vcocoa_set_window_title(_surfaceWindowID, t);
    }
}

- (instancetype)initWithContentRect:(NSRect)contentRect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backingStoreType
                              defer:(BOOL)flag {
    (void)backingStoreType; (void)flag;
    self = [super init];
    if (self) {
        _contentRect = contentRect;
        _styleMask = style;
        _contentView = [[NSView alloc] initWithFrame:contentRect];
        _title = @"Untitled";
        _structuralWindow = -1;
        _surfaceWindowID = -1;
    }
    return self;
}

- (NSView *)contentView { return _contentView; }
- (void)setContentView:(NSView *)view { _contentView = view; }
- (void)center {}
- (void)makeFirstResponder:(NSView *)responder { (void)responder; }
- (void)setAcceptsMouseMovedEvents:(BOOL)flag { (void)flag; }
- (NSWindowStyleMask)styleMask { return _styleMask; }
- (void)toggleFullScreen:(id)sender {
    (void)sender;
    // Flip the fullscreen bit so a later styleMask read reflects it (apps gate the
    // toggle on it), then ask wm to move this surface to/from a fullscreen layer.
    _styleMask ^= NSWindowStyleMaskFullScreen;
    if (_surfaceWindowID >= 0) {
        micro_os_vcocoa_set_fullscreen(
            _surfaceWindowID, (_styleMask & NSWindowStyleMaskFullScreen) ? 1 : 0);
    }
}

- (void)makeKeyAndOrderFront:(id)sender {
    (void)sender;
    if (_mounted) return;
    _mounted = YES;

    if ([_contentView microOSHasHostedLayer]) {
        // Surface app: mount the real backing view as a wm window.
        UIView *bv = [_contentView microOSBackingView];
        if (!bv) return;
        g_surfaceWindow = self;   // for the run loop's -performClose: on a wm X tap
        const char *title = self.title.UTF8String;
        _surfaceWindowID = micro_os_vcocoa_open_platform_window(
            title ? title : "Untitled", (__bridge void *)bv,
            _contentRect.size.width, _contentRect.size.height);
        // A window without a Resizable style mask is fixed-size (e.g. a typical
        // 800x600 game window) — turn off the wm window's Resize permission.
        if (_surfaceWindowID >= 0 && !(_styleMask & NSWindowStyleMaskResizable)) {
            micro_os_vcocoa_set_window_permission(_surfaceWindowID, "Resize", 0);
        }
    } else {
        // Control app: emit a widget document and show it through the wm.
        _structuralWindow = micro_os_gui_window_create(
            self.title.UTF8String,
            (double)_contentRect.size.width, (double)_contentRect.size.height);
        MicroOSAppKitEmitView(_structuralWindow, _contentView);
        micro_os_gui_window_show(_structuralWindow);
    }
}

- (void)performClose:(id)sender {
    (void)sender;
    id<NSWindowDelegate> d = self.delegate;
    BOOL shouldClose = YES;
    if ([d respondsToSelector:@selector(windowShouldClose:)]) shouldClose = [d windowShouldClose:self];
    if (shouldClose) {
        if ([d respondsToSelector:@selector(windowWillClose:)]) [d windowWillClose:nil];
        [[NSApplication sharedApplication] stop:nil];
    }
}
@end

static void MicroOSAppKitEmitView(micro_os_gui_window_t window, NSView *view) {
    if ([view isKindOfClass:[NSTextField class]]) {
        micro_os_gui_window_add_text(window, ((NSTextField *)view).stringValue.UTF8String);
        return;
    }
    if ([view isKindOfClass:[NSButton class]]) {
        NSButton *button = (NSButton *)view;
        NSString *controlID = [NSString stringWithFormat:@"button-%p", button];
        MicroOSAppKitButtonsByID()[controlID] = button;
        micro_os_gui_window_add_button(window, controlID.UTF8String, button.title.UTF8String);
        return;
    }
    if ([view isKindOfClass:[NSBox class]] && ((NSBox *)view).boxType == NSBoxSeparator) {
        micro_os_gui_window_add_divider(window);
        return;
    }
    NSArray<NSView *> *children = nil;
    if ([view respondsToSelector:@selector(microOSArrangedSubviews)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        children = [view performSelector:@selector(microOSArrangedSubviews)];
#pragma clang diagnostic pop
    }
    if (children == nil && [view respondsToSelector:@selector(microOSSubviews)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        children = [view performSelector:@selector(microOSSubviews)];
#pragma clang diagnostic pop
    }
    for (NSView *child in children) {
        MicroOSAppKitEmitView(window, child);
    }
}

// ===========================================================================
//  NSApplication — frame loop for surface apps, widget-event loop for controls
// ===========================================================================
@implementation NSApplication {
    atomic_bool _running;
}

+ (NSApplication *)sharedApplication {
    static NSApplication *application;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ application = [NSApplication new]; NSApp = application; });
    return application;
}

- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)activationPolicy { (void)activationPolicy; return YES; }
- (void)activateIgnoringOtherApps:(BOOL)flag { (void)flag; }
- (NSModalResponse)runModalForWindow:(id)window {
    // A panel that drives a real system picker (NSColorPanel) blocks here until it
    // is dismissed; everything else has a faked, non-blocking modal.
    if ([window respondsToSelector:@selector(microOSWaitModal)]) {
        [(NSColorPanel *)window microOSWaitModal];
    }
    return 0;
}
// runModalForWindow: never blocks (the panel modal is faked), so there is nothing
// to stop — a panel delegate's -windowWillClose: can still call this safely.
- (void)stopModal {}

- (void)run {
    atomic_store(&_running, true);
    id<NSApplicationDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(applicationDidFinishLaunching:)]) {
        [delegate applicationDidFinishLaunching:nil];
    }

    const NSTimeInterval period = 1.0 / 60.0;
    while (atomic_load(&_running)) {
        // Cooperative `kill`: when the kernel requests termination, break the loop
        // so -run returns and the app's own main() runs its cleanup (closes the
        // window, calls audio_shutdown, frees assets) — a force-killed thread
        // would otherwise leave AVAudioPlayers playing in the shared address space.
        if (micro_os_process_termination_requested()) break;
        // wm X button -> app-driven close: run -performClose: here (the app's
        // own thread) so windowShouldClose: (quit confirm) fires, matching Exit.
        if (atomic_exchange(&g_closeRequested, 0)) {
            NSWindow *surface = g_surfaceWindow;
            if (surface) [surface performClose:nil];
        }
        @autoreleasepool {
            id frameTarget = g_frameTarget;
            if (frameTarget && g_frameSel && [frameTarget respondsToSelector:g_frameSel]) {
                // Surface app: drive its frame callback on this thread.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [frameTarget performSelector:g_frameSel withObject:nil];
#pragma clang diagnostic pop
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:period];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
            } else {
                // Control app: dispatch widget click events.
                micro_os_gui_event event;
                if (micro_os_gui_next_event(&event) == 0) {
                    NSString *controlID = [NSString stringWithUTF8String:event.control];
                    NSButton *button = MicroOSAppKitButtonsByID()[controlID];
                    if (button && button.target && button.action &&
                        [button.target respondsToSelector:button.action]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [button.target performSelector:button.action withObject:button];
#pragma clang diagnostic pop
                    }
                } else {
                    usleep(16000);
                }
            }
        }
    }
}

- (void)stop:(id)sender { (void)sender; atomic_store(&_running, false); }
- (void)terminate:(id)sender { (void)sender; atomic_store(&_running, false); }
@end
