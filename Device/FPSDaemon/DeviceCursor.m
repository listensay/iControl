/* iControl passive on-device cursor. Copyright (c) 2026 iControl contributors.
 * SPDX-License-Identifier: GPL-2.0-only
 * UIKit plugin/window-hosting API sequence follows Lessica's TrollSpeed (MIT).
 * Its notice is included in CursorHosting-NOTICE.txt. No touch/event fetching
 * code is used: this window must never intercept the game's input. */
#import <Foundation/Foundation.h>
#include "DeviceCursor.h"
#include <stdatomic.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <math.h>

static atomic_bool gCursorAvailable, gCursorVisible;

#ifdef FPSD_SIMULATOR
static bool renderer_initialize(void) {
    fprintf(stderr, "FPS_CURSOR_RENDERER pid=%d\n", getpid());
    atomic_store(&gCursorAvailable, getenv("ICONTROL_FPSD_TEST_NO_CURSOR") == NULL);
    return atomic_load(&gCursorAvailable);
}
static void renderer_update(bool visible, FPSContact point, unsigned rotation) {
    (void)point; (void)rotation;
    if (atomic_load(&gCursorVisible) != visible) {
        fprintf(stderr, "FPS_CURSOR_RENDERER visible=%u\n", visible); fflush(stderr);
    }
    atomic_store(&gCursorVisible, visible);
}
#else
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>

@interface UIApplication (FPSCursorPlugin)
- (void)_accessibilityInit;
- (void)__completeAndRunAsPlugin;
@end
@interface UIWindow (FPSCursorContext)
- (unsigned)_contextId;
@end
@protocol FPSCursorHosting
- (void)registerWindowWithContextID:(unsigned)context atLevel:(double)level;
@end

@interface FPSCursorWindow : UIWindow
@end
@implementation FPSCursorWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return YES; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@interface FPSCursorRoot : UIViewController
@end
@implementation FPSCursorRoot
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.fixedCoordinateSpace.bounds];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = NO;
}
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
@end

static FPSCursorWindow *gCursorWindow;
static CAShapeLayer *gCursorLayer;
static id<FPSCursorHosting> gCursorHost;

static bool make_cursor_window(void) {
    if (gCursorWindow) return true;
    Class hostClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    id<FPSCursorHosting> host = (id)[[hostClass alloc] init];
    if (!host || ![(id)host respondsToSelector:@selector(registerWindowWithContextID:atLevel:)]) return false;
    FPSCursorWindow *window = [[FPSCursorWindow alloc] initWithFrame:UIScreen.mainScreen.fixedCoordinateSpace.bounds];
    window.backgroundColor = UIColor.clearColor; window.opaque = NO;
    window.userInteractionEnabled = NO; window.windowLevel = 10000010.0;
    FPSCursorRoot *root = [FPSCursorRoot new]; window.rootViewController = root;
    // Keep a transparent hosted context alive; only the arrow layer is hidden.
    // This avoids focus changes or re-registering a window while keys are held.
    window.hidden = NO;
    unsigned context = [window _contextId];
    if (!context) { window.hidden = YES; return false; }
    [host registerWindowWithContextID:context atLevel:window.windowLevel];
    fprintf(stderr, "FPS device cursor window context=%u bundle=%s\n", context,
            NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "unavailable");
    CAShapeLayer *arrow = [CAShapeLayer layer];
    arrow.bounds = CGRectMake(0, 0, 24, 32); arrow.anchorPoint = CGPointZero;
    arrow.fillColor = UIColor.whiteColor.CGColor; arrow.strokeColor = UIColor.blackColor.CGColor;
    arrow.lineWidth = 1.5; arrow.lineJoin = kCALineJoinRound;
    arrow.shadowColor = UIColor.blackColor.CGColor; arrow.shadowOpacity = 0.5;
    arrow.shadowRadius = 2; arrow.shadowOffset = CGSizeMake(0, 1);
    arrow.contentsScale = UIScreen.mainScreen.scale; arrow.hidden = YES;
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, 0, 0); CGPathAddLineToPoint(path, NULL, 0, 25);
    CGPathAddLineToPoint(path, NULL, 7, 19); CGPathAddLineToPoint(path, NULL, 13, 30);
    CGPathAddLineToPoint(path, NULL, 18, 27); CGPathAddLineToPoint(path, NULL, 12, 16);
    CGPathAddLineToPoint(path, NULL, 22, 16); CGPathCloseSubpath(path);
    arrow.path = path; CGPathRelease(path);
    [root.view.layer addSublayer:arrow];
    gCursorWindow = window; gCursorLayer = arrow; gCursorHost = host;
    return true;
}

@interface FPSCursorDelegate : NSObject <UIApplicationDelegate>
@end
@implementation FPSCursorDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)app; (void)options;
    atomic_store(&gCursorAvailable, make_cursor_window()); return YES;
}
@end
static FPSCursorDelegate *gCursorDelegate;

static bool renderer_initialize(void) {
    @try {
        void *gs = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_NOW);
        void *bk = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        void *sb = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        void (*gsInitialize)(void) = gs ? dlsym(gs, "GSInitialize") : NULL;
        void (*displayStart)(void) = bk ? dlsym(bk, "BKSDisplayServicesStart") : NULL;
        void (*appInitialize)(void) = dlsym(RTLD_DEFAULT, "UIApplicationInitialize");
        void (*instantiate)(Class) = dlsym(RTLD_DEFAULT, "UIApplicationInstantiateSingleton");
        if (!gsInitialize || !displayStart || !appInitialize || !instantiate || !sb) return false;
        [UIScreen initialize]; CFRunLoopGetCurrent(); gsInitialize(); displayStart(); appInitialize();
        instantiate(UIApplication.class);
        UIApplication *app = UIApplication.sharedApplication;
        if (![app respondsToSelector:@selector(__completeAndRunAsPlugin)]) return false;
        gCursorDelegate = [FPSCursorDelegate new]; app.delegate = gCursorDelegate;
        if ([app respondsToSelector:@selector(_accessibilityInit)]) [app _accessibilityInit];
        void (*eventInitialize)(int) = dlsym(gs, "GSEventInitialize");
        void (*pushMode)(CFStringRef) = dlsym(gs, "GSEventPushRunLoopMode");
        if (eventInitialize) eventInitialize(0);
        if (pushMode) pushMode(kCFRunLoopDefaultMode);
        [app __completeAndRunAsPlugin];
        // Some releases don't invoke a delegate callback for a plugin.
        atomic_store(&gCursorAvailable, make_cursor_window());
        fprintf(stderr, "FPS device cursor hosting=%s\n", atomic_load(&gCursorAvailable) ? "ready" : "unavailable");
    } @catch (NSException *exception) {
        fprintf(stderr, "FPS device cursor initialization failed: %s\n", exception.name.UTF8String);
        atomic_store(&gCursorAvailable, false);
    }
    return atomic_load(&gCursorAvailable);
}

static void renderer_update(bool visible, FPSContact point, unsigned rotation) {
    void (^update)(void) = ^{
        @try {
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            if (visible && atomic_load(&gCursorAvailable)) {
                FPSContact physical = fps_rotate(point, rotation);
                CGRect screen = UIScreen.mainScreen.fixedCoordinateSpace.bounds;
                CGPoint tip = CGPointMake(screen.origin.x + physical.x * screen.size.width,
                                          screen.origin.y + physical.y * screen.size.height);
                tip = [gCursorWindow convertPoint:tip fromCoordinateSpace:UIScreen.mainScreen.fixedCoordinateSpace];
                gCursorLayer.position = tip;
                gCursorLayer.affineTransform = CGAffineTransformMakeRotation(-(double)rotation * M_PI_2);
                gCursorLayer.hidden = NO; atomic_store(&gCursorVisible, true);
            } else { gCursorLayer.hidden = YES; atomic_store(&gCursorVisible, false); }
            [CATransaction commit];
        } @catch (NSException *exception) {
            (void)exception; atomic_store(&gCursorAvailable, false); atomic_store(&gCursorVisible, false);
        }
    };
    if (NSThread.isMainThread) update(); else dispatch_sync(dispatch_get_main_queue(), update);
}
#endif

int fps_cursor_renderer_run(int fd) {
    @autoreleasepool {
        uint8_t ready = renderer_initialize() ? 1 : 0;
        if (send(fd, &ready, 1, 0) != 1 || !ready) { close(fd); return ready ? 1 : 2; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            while (true) {
                struct pollfd item = {fd, POLLIN, 0};
                int result = poll(&item, 1, FPS_WATCHDOG_MS);
                if (result == 0) { renderer_update(false, (FPSContact){0}, 0); continue; }
                if (result < 0) break;
                FPSCursorMessage message;
                if (recv(fd, &message, sizeof(message), MSG_WAITALL) != sizeof(message)) break;
                if (message.visible > 1 || message.rotation > 3 || !isfinite(message.x) || !isfinite(message.y)
                    || message.x < 0 || message.x > 1 || message.y < 0 || message.y > 1) break;
                renderer_update(message.visible, (FPSContact){true, message.x, message.y}, message.rotation);
                uint8_t flags = (atomic_load(&gCursorAvailable) ? 1 : 0) | (atomic_load(&gCursorVisible) ? 2 : 0);
                if (send(fd, &flags, 1, 0) != 1) break;
            }
            renderer_update(false, (FPSContact){0}, 0); close(fd);
            // Only the isolated renderer exits. The touch service is unaffected.
            exit(0);
        });
        CFRunLoopRun();
        return 0;
    }
}
