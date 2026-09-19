//
//  HostedVisibilitySmoke.m
//  Ice
//
//  Opt-in native smoke test for the macOS 27 hosted menu-bar visibility bridge.
//  The same executable runs either as an isolated fixture app or as its
//  controller. The fixture is built into a temporary app bundle by the script.
//

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "IceMenuBarVisibility.h"

static NSString * const IceProbeTitle = @"IceProbe";

static BOOL IceElementHasProbeIdentity(AXUIElementRef element) {
    for (NSString *attribute in @[ (__bridge NSString *)kAXTitleAttribute,
                                   (__bridge NSString *)kAXDescriptionAttribute,
                                   (__bridge NSString *)kAXIdentifierAttribute,
                                   (__bridge NSString *)kAXValueAttribute ]) {
        CFTypeRef value = NULL;
        if (AXUIElementCopyAttributeValue(element, (__bridge CFStringRef)attribute, &value) == kAXErrorSuccess) {
            BOOL matches = CFGetTypeID(value) == CFStringGetTypeID() &&
                [(__bridge NSString *)value isEqualToString:IceProbeTitle];
            CFRelease(value);
            if (matches) {
                return YES;
            }
        }
    }
    return NO;
}

static AXUIElementRef IceCopyProbeElement(AXUIElementRef element, NSUInteger depth, pid_t expectedPID) {
    if (depth == 0) {
        return NULL;
    }

    pid_t elementPID = 0;
    if (IceElementHasProbeIdentity(element) &&
        AXUIElementGetPid(element, &elementPID) == kAXErrorSuccess && elementPID == expectedPID) {
        return (AXUIElementRef)CFRetain(element);
    }

    CFTypeRef childrenValue = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &childrenValue) != kAXErrorSuccess) {
        return NULL;
    }
    NSArray *children = CFBridgingRelease(childrenValue);
    for (id child in children) {
        if (CFGetTypeID((__bridge CFTypeRef)child) == AXUIElementGetTypeID()) {
            AXUIElementRef probe = IceCopyProbeElement((__bridge AXUIElementRef)child, depth - 1, expectedPID);
            if (probe) {
                return probe;
            }
        }
    }
    return NULL;
}

static BOOL IceCopyProbeFrame(NSString *fixtureBundleIdentifier, CGRect *frame, pid_t *fixturePID) {
    NSRunningApplication *fixture =
        [[NSRunningApplication runningApplicationsWithBundleIdentifier:fixtureBundleIdentifier] firstObject];
    if (!fixture) {
        return NO;
    }
    AXUIElementRef application = AXUIElementCreateApplication(fixture.processIdentifier);
    CFTypeRef extrasValue = NULL;
    AXError error = AXUIElementCopyAttributeValue(application, kAXExtrasMenuBarAttribute, &extrasValue);
    CFRelease(application);
    if (error != kAXErrorSuccess || CFGetTypeID(extrasValue) != AXUIElementGetTypeID()) {
        if (extrasValue) {
            CFRelease(extrasValue);
        }
        return NO;
    }
    AXUIElementRef probe = IceCopyProbeElement((AXUIElementRef)extrasValue, 8, fixture.processIdentifier);
    CFRelease(extrasValue);
    if (!probe) {
        return NO;
    }
    CFTypeRef positionValue = NULL;
    CFTypeRef sizeValue = NULL;
    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL copiedFrame =
        AXUIElementCopyAttributeValue(probe, kAXPositionAttribute, &positionValue) == kAXErrorSuccess &&
        CFGetTypeID(positionValue) == AXValueGetTypeID() &&
        AXValueGetValue((AXValueRef)positionValue, kAXValueCGPointType, &position) &&
        AXUIElementCopyAttributeValue(probe, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess &&
        CFGetTypeID(sizeValue) == AXValueGetTypeID() &&
        AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);
    if (positionValue) {
        CFRelease(positionValue);
    }
    if (sizeValue) {
        CFRelease(sizeValue);
    }
    CFRelease(probe);
    if (copiedFrame) {
        *frame = (CGRect){ position, size };
    }
    if (copiedFrame && fixturePID) {
        *fixturePID = fixture.processIdentifier;
    }
    return copiedFrame;
}

typedef NS_ENUM(NSInteger, IceProbeRenderState) {
    IceProbeRenderStateUnknown,
    IceProbeRenderStateAbsent,
    IceProbeRenderStatePresent,
};

// Source-app AXExtrasMenuBar proxies survive concealment on macOS 27.
// Inspect the rendered MenuBarAgent window tree instead.
static IceProbeRenderState IceProbeRenderStateInMenuBand(CGRect frame, pid_t fixturePID) {
    (void)frame;
    if (![NSRunningApplication runningApplicationWithProcessIdentifier:fixturePID]) {
        return IceProbeRenderStateUnknown;
    }
    NSRunningApplication *host = [[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MenuBarAgent"] firstObject];
    if (!host) { return IceProbeRenderStateUnknown; }
    AXUIElementRef application = AXUIElementCreateApplication(host.processIdentifier);
    CFTypeRef windowsValue = NULL;
    AXError error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, &windowsValue);
    CFRelease(application);
    if (error != kAXErrorSuccess || !windowsValue || CFGetTypeID(windowsValue) != CFArrayGetTypeID()) {
        if (windowsValue) { CFRelease(windowsValue); }
        return IceProbeRenderStateUnknown;
    }
    NSArray *windows = CFBridgingRelease(windowsValue);
    if (!windows.count) { return IceProbeRenderStateUnknown; }
    for (id window in windows) {
        AXUIElementRef probe = IceCopyProbeElement((__bridge AXUIElementRef)window, 12, fixturePID);
        if (probe) { CFRelease(probe); return IceProbeRenderStatePresent; }
    }
    return IceProbeRenderStateAbsent;
}

static BOOL IceWaitForProbeRenderState(CGRect frame, pid_t fixturePID, BOOL expected, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        IceProbeRenderState state = IceProbeRenderStateInMenuBand(frame, fixturePID);
        if ((state == IceProbeRenderStatePresent) == expected && state != IceProbeRenderStateUnknown) {
            return YES;
        }
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    } while (deadline.timeIntervalSinceNow > 0);
    IceProbeRenderState state = IceProbeRenderStateInMenuBand(frame, fixturePID);
    return (state == IceProbeRenderStatePresent) == expected && state != IceProbeRenderStateUnknown;
}

static BOOL IceWaitForProbeFrame(NSString *fixtureBundleIdentifier, CGRect *frame, pid_t *fixturePID,
                                 NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        if (IceCopyProbeFrame(fixtureBundleIdentifier, frame, fixturePID) && !CGRectIsEmpty(*frame)) {
            return YES;
        }
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    } while (deadline.timeIntervalSinceNow > 0);
    return IceCopyProbeFrame(fixtureBundleIdentifier, frame, fixturePID) && !CGRectIsEmpty(*frame);
}

static int IceRunFixture(void) {
    [NSApplication sharedApplication];
    __block NSStatusItem *statusItem;
    // Match production AppKit lifecycle: create the hosted scene only after
    // the app has entered its run loop, and retain the item through teardown.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
        statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        statusItem.autosaveName = IceProbeTitle;
        statusItem.button.title = IceProbeTitle;
        statusItem.button.accessibilityIdentifier = IceProbeTitle;
        NSLog(@"[HostedVisibilitySmoke] fixture ready (%@)", NSBundle.mainBundle.bundleIdentifier);
    });

    // The fixture owns its lifetime and cannot leave a permanent status item.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (statusItem) { [[NSStatusBar systemStatusBar] removeStatusItem:statusItem]; }
        [NSApp terminate:nil];
    });
    [NSApp run];
    return 0;
}

static NSArray<NSString *> *IceAllowedBundleIdentifiers(NSString *fixtureBundleIdentifier) {
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
        NSString *bundleIdentifier = application.bundleIdentifier;
        if (bundleIdentifier.length > 0 && ![bundleIdentifier isEqualToString:fixtureBundleIdentifier]) {
            [identifiers addObject:bundleIdentifier];
        }
    }
    return identifiers.array;
}

static int IceFinishController(int result, NSString *resultPath) {
    [[NSString stringWithFormat:@"%d\n", result] writeToFile:resultPath
                                                       atomically:YES
                                                         encoding:NSUTF8StringEncoding
                                                            error:nil];
    return result;
}

static int IceRunController(NSString *fixtureBundleIdentifier, NSString *resultPath,
                            BOOL verifyAllowlistedFixture) {
    [NSApplication sharedApplication];
    if (!AXIsProcessTrusted()) {
        NSLog(@"[HostedVisibilitySmoke] Accessibility permission is required.");
        return IceFinishController(2, resultPath);
    }
    if (!IceMenuBarVisibilityAvailable()) {
        NSLog(@"[HostedVisibilitySmoke] IceMenuBarVisibility is unavailable.");
        return IceFinishController(3, resultPath);
    }
    CGRect probeFrame = CGRectZero;
    pid_t fixturePID = 0;
    if (!IceWaitForProbeFrame(fixtureBundleIdentifier, &probeFrame, &fixturePID, 4.0)) {
        NSLog(@"[HostedVisibilitySmoke] fixture %@ has no usable AXExtrasMenuBar frame.", fixtureBundleIdentifier);
        return IceFinishController(4, resultPath);
    }
    NSLog(@"[HostedVisibilitySmoke] fixture source AX frame=(%.1f, %.1f, %.1f, %.1f), pid=%d.",
          probeFrame.origin.x, probeFrame.origin.y, probeFrame.size.width, probeFrame.size.height, fixturePID);
    if (
        !IceWaitForProbeRenderState(probeFrame, fixturePID, YES, 4.0)) {
        NSLog(@"[HostedVisibilitySmoke] fixture %@ did not appear as a rendered AXExtrasMenuBar item.", fixtureBundleIdentifier);
        return IceFinishController(4, resultPath);
    }

    // Optional diagnostic for the positive half of the private API contract.
    // Temporary app bundles can be classified differently from a canonical
    // LaunchServices installation on macOS 27, so this remains a strict opt-in
    // probe rather than weakening the default concealment smoke test.
    if (verifyAllowlistedFixture) {
    __block BOOL allowCompletionCalled = NO;
    __block NSError *allowCompletionError = nil;
    NSMutableOrderedSet<NSString *> *positiveAllowed = [NSMutableOrderedSet orderedSetWithArray:
        IceAllowedBundleIdentifiers(fixtureBundleIdentifier)];
    [positiveAllowed addObject:fixtureBundleIdentifier];
    void *allowHandle = IceMenuBarVisibilityActivate(
        positiveAllowed.array,
        @[ @0, @1, @2, @3, @4, @5, @6, @7, @8 ],
        ^(NSError *error) {
            allowCompletionCalled = YES;
            allowCompletionError = error;
        });
    if (!allowHandle) {
        NSLog(@"[HostedVisibilitySmoke] positive allowlist activation could not start.");
        return IceFinishController(5, resultPath);
    }
    NSDate *allowCompletionDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!allowCompletionCalled && allowCompletionDeadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    BOOL allowSucceeded = allowCompletionCalled && allowCompletionError == nil;
    if (!allowSucceeded) {
        NSLog(@"[HostedVisibilitySmoke] positive allowlist activation completion failed: %@", allowCompletionError);
    } else {
        // Give MenuBarAgent enough time to apply and composite the new scene
        // even when the activation callback arrives before the visual reflow.
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        allowSucceeded = IceWaitForProbeRenderState(probeFrame, fixturePID, YES, 2.5);
        if (!allowSucceeded) {
            NSLog(@"[HostedVisibilitySmoke] explicitly allowlisted fixture disappeared after activation.");
        }
    }
    IceMenuBarVisibilityInvalidate(allowHandle);
    if (!allowSucceeded || !IceWaitForProbeRenderState(probeFrame, fixturePID, YES, 3.0)) {
        NSLog(@"[HostedVisibilitySmoke] positive allowlist phase failed or did not restore cleanly.");
        return IceFinishController(5, resultPath);
    }
    NSLog(@"[HostedVisibilitySmoke] positive allowlist phase passed: fixture remained rendered.");
    }

    for (NSUInteger cycle = 1; cycle <= 3; cycle++) {
    __block BOOL completionCalled = NO;
    __block NSError *completionError = nil;
    __block void *handle = NULL;
    __block BOOL invalidated = NO;
    void (^cleanup)(void) = ^{
        if (handle && !invalidated) {
            IceMenuBarVisibilityInvalidate(handle);
            invalidated = YES;
            handle = NULL;
        }
    };

    handle = IceMenuBarVisibilityActivate(
        IceAllowedBundleIdentifiers(fixtureBundleIdentifier),
        @[ @0, @1, @2, @3, @4, @5, @6, @7, @8 ],
        ^(NSError *error) {
            completionCalled = YES;
            completionError = error;
        });

    // The owner is guaranteed to release the assertion before ten seconds.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), cleanup);

    BOOL succeeded = handle != NULL;
    if (!succeeded) {
        NSLog(@"[HostedVisibilitySmoke] activation could not start.");
    }
    if (succeeded) {
        NSDate *completionDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (!completionCalled && completionDeadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        succeeded = completionCalled && completionError == nil;
        if (!succeeded) {
            NSLog(@"[HostedVisibilitySmoke] activation completion failed: %@", completionError);
        }
    }
    if (succeeded) {
        succeeded = IceWaitForProbeRenderState(probeFrame, fixturePID, NO, 3.0);
        if (!succeeded) {
            NSLog(@"[HostedVisibilitySmoke] fixture remained visible after activation.");
        }
    }

    cleanup();
    BOOL restored = IceWaitForProbeRenderState(probeFrame, fixturePID, YES, 3.0);
    if (!restored) {
        NSLog(@"[HostedVisibilitySmoke] fixture did not reappear after invalidation.");
    }
    if (!succeeded || !restored) {
        return IceFinishController(5, resultPath);
    }
    NSLog(@"[HostedVisibilitySmoke] cycle %lu passed: hide, completion, and restoration observed.", (unsigned long)cycle);
    }
    for (NSRunningApplication *fixture in [NSRunningApplication runningApplicationsWithBundleIdentifier:fixtureBundleIdentifier]) {
        [fixture terminate];
    }
    return IceFinishController(0, resultPath);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--fixture") == 0) {
            return IceRunFixture();
        }
        if ((argc == 4 || argc == 5) && strcmp(argv[1], "--controller") == 0) {
            BOOL verifyAllowlistedFixture = argc == 5 &&
                strcmp(argv[4], "--verify-allowlisted-fixture") == 0;
            if (argc == 5 && !verifyAllowlistedFixture) {
                fprintf(stderr, "unknown controller option: %s\n", argv[4]);
                return 64;
            }
            return IceRunController([NSString stringWithUTF8String:argv[2]],
                                    [NSString stringWithUTF8String:argv[3]],
                                    verifyAllowlistedFixture);
        }
        fprintf(stderr,
                "usage: %s --fixture | --controller <fixture-bundle-id> <result-path> "
                "[--verify-allowlisted-fixture]\\n",
                argv[0]);
        return 64;
    }
}
