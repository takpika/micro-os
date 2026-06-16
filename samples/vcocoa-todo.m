#import <AppKit/AppKit.h>

@interface TodoAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation TodoAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 360)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"C GUI App";

    NSStackView *stack = [[NSStackView alloc] initWithFrame:window.contentView.bounds];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:window.contentView.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor],
    ]];

    NSTextField *label = [NSTextField labelWithString:@"Ported C GUI"];
    label.textColor = NSColor.secondaryLabelColor;
    label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [stack addArrangedSubview:label];

    [stack addArrangedSubview:[NSTextField labelWithString:@"This is ordinary AppKit code."]];

    NSBox *divider = [NSBox new];
    divider.boxType = NSBoxSeparator;
    [stack addArrangedSubview:divider];

    NSButton *printButton = [NSButton buttonWithTitle:@"Print message" target:self action:@selector(printMessage:)];
    [stack addArrangedSubview:printButton];

    NSButton *exitButton = [NSButton buttonWithTitle:@"Exit" target:self action:@selector(exitApp:)];
    [stack addArrangedSubview:exitButton];

    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)printMessage:(id)sender {
    (void)sender;
    puts("mac-gui: button clicked");
}

- (void)exitApp:(id)sender {
    (void)sender;
    puts("mac-gui: exiting");
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        TodoAppDelegate *delegate = [TodoAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
