#if !defined(MICRO_OS_APPKIT_SHIM)
#if __has_include_next(<AppKit/AppKit.h>)
#include_next <AppKit/AppKit.h>
#else
#error "AppKit is unavailable. Define MICRO_OS_APPKIT_SHIM when building for microOS."
#endif
#else

#ifndef MICRO_OS_APPKIT_H
#define MICRO_OS_APPKIT_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <TargetConditionals.h>
// The shim is backed by real UIKit views, so it uses UIKit's Auto Layout types
// (NSLayoutAnchor/NSLayoutConstraint/NSLayoutAttribute) rather than redeclaring
// them. AppKit-only classes (NSWindow/NSView/NSColor/…) are declared below.
#if TARGET_OS_IPHONE || TARGET_OS_TV || TARGET_OS_VISION
#import <UIKit/UIKit.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

#if TARGET_OS_IPHONE || TARGET_OS_TV || TARGET_OS_VISION
typedef CGRect NSRect;
typedef CGSize NSSize;
typedef CGPoint NSPoint;

static inline NSRect NSMakeRect(CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    return CGRectMake(x, y, width, height);
}

typedef struct NSEdgeInsets {
    CGFloat top;
    CGFloat left;
    CGFloat bottom;
    CGFloat right;
} NSEdgeInsets;

static inline NSEdgeInsets NSEdgeInsetsMake(CGFloat top, CGFloat left, CGFloat bottom, CGFloat right) {
    NSEdgeInsets insets = { top, left, bottom, right };
    return insets;
}
#endif

typedef NS_OPTIONS(NSUInteger, NSWindowStyleMask) {
    NSWindowStyleMaskTitled = 1 << 0,
    NSWindowStyleMaskClosable = 1 << 1,
    NSWindowStyleMaskMiniaturizable = 1 << 2,
    NSWindowStyleMaskResizable = 1 << 3,
    NSWindowStyleMaskFullScreen = 1 << 14,
};

typedef NS_ENUM(NSInteger, NSApplicationActivationPolicy) {
    NSApplicationActivationPolicyRegular = 0,
    NSApplicationActivationPolicyAccessory = 1,
    NSApplicationActivationPolicyProhibited = 2,
};

typedef NS_OPTIONS(NSUInteger, NSEventModifierFlags) {
    NSEventModifierFlagShift   = 1 << 17,
    NSEventModifierFlagControl = 1 << 18,
    NSEventModifierFlagOption  = 1 << 19,
    NSEventModifierFlagCommand = 1 << 20,
};

typedef NS_OPTIONS(NSUInteger, NSTrackingAreaOptions) {
    NSTrackingMouseEnteredAndExited = 1 << 0,
    NSTrackingMouseMoved            = 1 << 1,
    NSTrackingActiveAlways          = 1 << 7,
};

typedef NSInteger NSModalResponse;
static const NSModalResponse NSAlertFirstButtonReturn  = 1000;
static const NSModalResponse NSAlertSecondButtonReturn = 1001;

typedef NS_ENUM(NSUInteger, NSBackingStoreType) {
    NSBackingStoreBuffered = 2,
};

typedef NS_ENUM(NSInteger, NSUserInterfaceLayoutOrientation) {
    NSUserInterfaceLayoutOrientationHorizontal = 0,
    NSUserInterfaceLayoutOrientationVertical = 1,
};

typedef NS_ENUM(NSInteger, NSBoxType) {
    NSBoxPrimary = 0,
    NSBoxSeparator = 2,
};

@class NSApplication;
@class NSView;
@class NSWindow;
@class NSEvent;
@class NSTrackingArea;
@class NSColor;
@class NSFont;

@protocol NSWindowDelegate <NSObject>
@optional
- (BOOL)windowShouldClose:(id)sender;
- (void)windowWillClose:(NSNotification *)notification;
@end

// Mouse/keyboard event synthesized by the runtime from UIKit touches.
@interface NSEvent : NSObject
@property(nonatomic, readonly) CGPoint locationInWindow;
@property(nonatomic, readonly) unsigned short keyCode;
@property(nonatomic, readonly) NSEventModifierFlags modifierFlags;
@property(nonatomic, readonly) CGFloat deltaY;
@property(nonatomic, readonly) BOOL isARepeat;   // YES for auto-repeat keyDowns
@end

@interface NSTrackingArea : NSObject
- (instancetype)initWithRect:(NSRect)rect
                     options:(NSTrackingAreaOptions)options
                       owner:(id)owner
                    userInfo:(NSDictionary *)userInfo;
@end

@interface NSAlert : NSObject
@property(nonatomic, copy) NSString *messageText;
@property(nonatomic, copy) NSString *informativeText;
- (void)addButtonWithTitle:(NSString *)title;
- (NSModalResponse)runModal;
@end

@interface NSWorkspace : NSObject
+ (NSWorkspace *)sharedWorkspace;
- (BOOL)openURL:(NSURL *)url;
@end

@protocol NSApplicationDelegate <NSObject>
@optional
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
@end


@interface NSView : NSObject
- (instancetype)initWithFrame:(NSRect)frame;
- (void)addSubview:(NSView *)view;
@property(nonatomic) NSRect frame;
@property(nonatomic, readonly) NSRect bounds;
@property(nonatomic) BOOL translatesAutoresizingMaskIntoConstraints;
@property(nonatomic, readonly) NSLayoutAnchor *topAnchor;
@property(nonatomic, readonly) NSLayoutAnchor *leadingAnchor;
@property(nonatomic, readonly) NSLayoutAnchor *trailingAnchor;
@property(nonatomic, readonly) NSLayoutAnchor *bottomAnchor;
// Real-surface (Metal) support: a layer-backed view that hosts a CAMetalLayer
// and receives synthesized mouse/keyboard events.
@property(nonatomic) BOOL wantsLayer;
@property(nonatomic, strong) CALayer *layer;
@property(nonatomic, readonly) BOOL isFlipped;
@property(nonatomic, readonly) BOOL acceptsFirstResponder;
- (void)addTrackingArea:(NSTrackingArea *)trackingArea;
- (NSPoint)convertPoint:(NSPoint)point fromView:(NSView *)view;
- (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector;
- (void)mouseMoved:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)mouseExited:(NSEvent *)event;
- (void)mouseDown:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
- (void)scrollWheel:(NSEvent *)event;
- (void)rightMouseDown:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;
- (void)flagsChanged:(NSEvent *)event;
@end

@interface NSWindow : NSObject
- (instancetype)initWithContentRect:(NSRect)contentRect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backingStoreType
                              defer:(BOOL)flag;
- (void)center;
- (void)makeKeyAndOrderFront:(id)sender;
- (void)makeFirstResponder:(NSView *)responder;
- (void)setContentView:(NSView *)view;
- (void)setAcceptsMouseMovedEvents:(BOOL)flag;
- (void)performClose:(id)sender;
- (void)toggleFullScreen:(id)sender;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) NSView *contentView;
// AppKit declares this `weak`, but apps assign a freshly-made delegate and expect
// it to live as long as the window (`[window setDelegate:[WindowDelegate new]]`).
// On a real Mac the app keeps its own reference; here the window owns it. No
// retain cycle — a window delegate does not hold the window back.
@property(nonatomic, strong) id<NSWindowDelegate> delegate;
@property(nonatomic, readonly) NSWindowStyleMask styleMask;
@end

@interface NSApplication : NSObject
+ (NSApplication *)sharedApplication;
- (void)run;
- (void)stop:(id)sender;
- (void)terminate:(id)sender;
- (void)activateIgnoringOtherApps:(BOOL)flag;
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)activationPolicy;
- (NSModalResponse)runModalForWindow:(id)window;
- (void)stopModal;
@property(nonatomic, weak) id<NSApplicationDelegate> delegate;
@end

extern NSApplication *NSApp;

@interface NSColorSpace : NSObject
+ (NSColorSpace *)sRGBColorSpace;
@end

// NSColorPanel/NSFontPanel are NSPanel : NSWindow in real AppKit, so they get
// -makeKeyAndOrderFront: and the `delegate` property from NSWindow. NSColorPanel
// drives a real UIColorPickerViewController and blocks runModalForWindow: until
// dismissed; NSFontPanel still fakes the modal (returns immediately).
@interface NSColorPanel : NSWindow
+ (NSColorPanel *)sharedColorPanel;
@property(nonatomic) BOOL showsAlpha;
@property(nonatomic, strong) NSColor *color;
@end

@interface NSStackView : NSView
- (void)addArrangedSubview:(NSView *)view;
@property(nonatomic) NSUserInterfaceLayoutOrientation orientation;
@property(nonatomic) NSLayoutAttribute alignment;
@property(nonatomic) CGFloat spacing;
@property(nonatomic) NSEdgeInsets edgeInsets;
@end

@interface NSTextField : NSView
+ (NSTextField *)labelWithString:(NSString *)stringValue;
@property(nonatomic, copy) NSString *stringValue;
@property(nonatomic, strong) NSColor *textColor;
@property(nonatomic, strong) NSFont *font;
@end

@interface NSButton : NSView
+ (NSButton *)buttonWithTitle:(NSString *)title target:(id)target action:(SEL)action;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@end

@interface NSBox : NSView
@property(nonatomic) NSBoxType boxType;
@end

@interface NSColor : NSObject
+ (NSColor *)secondaryLabelColor;
+ (NSColor *)colorWithSRGBRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha;
- (NSColor *)colorUsingColorSpace:(NSColorSpace *)space;
@property(nonatomic, readonly) CGFloat redComponent;
@property(nonatomic, readonly) CGFloat greenComponent;
@property(nonatomic, readonly) CGFloat blueComponent;
@end

@interface NSFont : NSObject
+ (NSFont *)systemFontOfSize:(CGFloat)fontSize;
+ (NSFont *)fontWithName:(NSString *)fontName size:(CGFloat)fontSize;
+ (CGFloat)smallSystemFontSize;
@property(nonatomic, readonly, copy) NSString *fontName;
@end

@interface NSFontPanel : NSWindow
@end

@interface NSFontManager : NSObject
+ (NSFontManager *)sharedFontManager;
- (void)setSelectedFont:(NSFont *)font isMultiple:(BOOL)flag;
- (void)setTarget:(id)target;
- (void)setAction:(SEL)action;
- (NSFontPanel *)fontPanel:(BOOL)create;
- (NSFont *)convertFont:(NSFont *)font;
@end

#ifdef __cplusplus
}
#endif

#endif
#endif
