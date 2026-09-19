//
//  IceMenuBarVisibility.m
//  Ice
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3
//
//  Adapted from Thaw/MenuBar/HiddenSectionPatch/ThawAssessmentModeHiding.
//

#import "IceMenuBarVisibility.h"
#import <dlfcn.h>

@interface MBAssessmentModeConfiguration : NSObject
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)systemItems
                  allowedBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers;
@end

@interface MBAssessmentModeAssertion : NSObject
- (void)activateWithConfiguration:(id)configuration
                completionHandler:(void (^)(NSError *_Nullable error))completionHandler;
- (void)invalidate;
@end

static const char * const kMenuBarClientCorePath =
    "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";
static NSString * const IceMenuBarVisibilityErrorDomain = @"IceMenuBarVisibilityError";

typedef NS_ENUM(NSInteger, IceMenuBarVisibilityErrorCode) {
    IceMenuBarVisibilityErrorUnavailable = 1,
    IceMenuBarVisibilityErrorActivationFailed = 2,
};

static BOOL IceMenuBarVisibilitySupportsMacOS27(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

static BOOL IceEnsureMenuBarClientCoreLoaded(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded;
    dispatch_once(&onceToken, ^{
        if (!IceMenuBarVisibilitySupportsMacOS27()) {
            return;
        }
        loaded = dlopen(kMenuBarClientCorePath, RTLD_NOW) != NULL;
        if (!loaded) {
            NSLog(@"[IceMenuBarVisibility] failed to load MenuBarClientCore: %s", dlerror());
        }
    });
    return loaded;
}

static BOOL IceAssessmentModeClassesAreUsable(Class _Nullable *configurationClass,
                                              Class _Nullable *assertionClass) {
    if (!IceEnsureMenuBarClientCoreLoaded()) {
        return NO;
    }

    Class configuration = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
    SEL configurationInitializer = @selector(initWithAllowedSystemItems:allowedBundleIdentifiers:);
    SEL activation = @selector(activateWithConfiguration:completionHandler:);
    SEL invalidation = @selector(invalidate);

    if (!configuration || !assertion ||
        ![configuration respondsToSelector:@selector(alloc)] ||
        ![assertion respondsToSelector:@selector(alloc)] ||
        ![configuration instancesRespondToSelector:configurationInitializer] ||
        ![assertion instancesRespondToSelector:@selector(init)] ||
        ![assertion instancesRespondToSelector:activation] ||
        ![assertion instancesRespondToSelector:invalidation]) {
        return NO;
    }

    if (configurationClass) {
        *configurationClass = configuration;
    }
    if (assertionClass) {
        *assertionClass = assertion;
    }
    return YES;
}

static NSError *IceMenuBarVisibilityError(IceMenuBarVisibilityErrorCode code,
                                          NSString *description) {
    return [NSError errorWithDomain:IceMenuBarVisibilityErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: description }];
}

static void IceMenuBarVisibilityComplete(void (^_Nullable completion)(NSError *_Nullable),
                                         NSError *_Nullable error) {
    if (!completion) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(error);
    });
}

BOOL IceMenuBarVisibilityAvailable(void) {
    return IceAssessmentModeClassesAreUsable(NULL, NULL);
}

void *IceMenuBarVisibilityActivate(NSArray<NSString *> *allowedBundleIdentifiers,
                                   NSArray<NSNumber *> *allowedSystemItems,
                                   void (^completion)(NSError *_Nullable)) {
    Class configurationClass;
    Class assertionClass;
    if (!IceAssessmentModeClassesAreUsable(&configurationClass, &assertionClass)) {
        IceMenuBarVisibilityComplete(completion,
            IceMenuBarVisibilityError(IceMenuBarVisibilityErrorUnavailable,
                                      @"Menu bar visibility is unavailable on this macOS version."));
        return NULL;
    }

    @try {
        MBAssessmentModeConfiguration *configuration =
            [[configurationClass alloc] initWithAllowedSystemItems:allowedSystemItems ?: @[]
                                          allowedBundleIdentifiers:allowedBundleIdentifiers ?: @[]];
        if (!configuration) {
            IceMenuBarVisibilityComplete(completion,
                IceMenuBarVisibilityError(IceMenuBarVisibilityErrorActivationFailed,
                                          @"Could not create the menu bar visibility configuration."));
            return NULL;
        }

        MBAssessmentModeAssertion *assertion = [[assertionClass alloc] init];
        if (!assertion) {
            IceMenuBarVisibilityComplete(completion,
                IceMenuBarVisibilityError(IceMenuBarVisibilityErrorActivationFailed,
                                          @"Could not create the menu bar visibility assertion."));
            return NULL;
        }

        [assertion activateWithConfiguration:configuration
                           completionHandler:^(NSError *_Nullable error) {
            IceMenuBarVisibilityComplete(completion, error);
        }];
        return (void *)CFBridgingRetain(assertion);
    } @catch (NSException *exception) {
        NSLog(@"[IceMenuBarVisibility] activation threw: %@", exception);
        IceMenuBarVisibilityComplete(completion,
            IceMenuBarVisibilityError(IceMenuBarVisibilityErrorActivationFailed,
                                      exception.reason ?: @"Menu bar visibility activation failed."));
        return NULL;
    }
}

void IceMenuBarVisibilityInvalidate(void *handle) {
    if (!handle) {
        return;
    }

    MBAssessmentModeAssertion *assertion = (MBAssessmentModeAssertion *)CFBridgingRelease(handle);
    @try {
        if ([assertion respondsToSelector:@selector(invalidate)]) {
            [assertion invalidate];
        }
    } @catch (NSException *exception) {
        NSLog(@"[IceMenuBarVisibility] invalidation threw: %@", exception);
    }
}
