#import <mpv/client.h>
#import <mpv/opengl_cb.h>

#import <OpenGL/gl.h>
#import <stdio.h>
#import <stdlib.h>

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>


static void* get_proc_address(void* ctx, const char* name)
{
    CFStringRef symbol = CFStringCreateWithCString(
        kCFAllocatorDefault, name, kCFStringEncodingASCII);
    void* addr = CFBundleGetFunctionPointerForName(
        CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl")), symbol);
    CFRelease(symbol);
    return addr;
}

static inline void check_error(int status)
{
    if (status < 0) {
        printf("mpv API error: %s\n", mpv_error_string(status));
        exit(1);
    }
}

@interface VideoLayer : CAOpenGLLayer {
    mpv_handle* mpv;
    mpv_opengl_cb_context* mpv_cb_ctx;
    BOOL inLiveResize;
    NSSize surfaceSize;
    CVDisplayLinkRef link;
}
@property(nonatomic, assign) dispatch_queue_t queue;
@end

@implementation VideoLayer

- (id)init
{
    if (self = [super init]) {
        //[self setAsynchronous:YES];
        // XXX : need to sync with render/updateCallback on playback
        //[self setNeedsDisplayOnBoundsChange:YES];
        [self setAutoresizingMask:kCALayerWidthSizable|kCALayerHeightSizable];
        [self setBackgroundColor:[NSColor blackColor].CGColor];
        inLiveResize = NO;
    }
    return self;
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf
        forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts
{
    return YES;
}

- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf
        forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts
{
    GLint i = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &i);

    if (mpv_cb_ctx) {
        if (!inLiveResize)
            surfaceSize = self.bounds.size;
        mpv_opengl_cb_draw(mpv_cb_ctx, i, surfaceSize.width, -surfaceSize.height);
    } else {
        glClearColor( 0.0, 0.0, 0.0, 1.0 );
        glClear( GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT );
    }

    CGLFlushDrawable(ctx);
}

- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask
{
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute) kCGLOGLPVersion_3_2_Core,
        kCGLPFADoubleBuffer,
        kCGLPFAAllowOfflineRenderers,
        kCGLPFABackingStore,
        kCGLPFAAccelerated,
        kCGLPFASupportsAutomaticGraphicsSwitching,
        0
    };

    GLint npix;
    CGLPixelFormatObj pix;
    CGLChoosePixelFormat(attrs, &pix, &npix);

    return pix;
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pf
{
    CGLContextObj ctx = [super copyCGLContextForPixelFormat:pf];

    GLint i = 1;
    CGLSetParameter(ctx, kCGLCPSwapInterval, &i);
    CGLEnable(ctx, kCGLCEMPEngine);
    CGLSetCurrentContext(ctx);

    [self initMPV];
    [self initDisplaylink];

    return ctx;
}

- (void)display
{
    [super display];
    [CATransaction flush];
}

static void updateCallback(void* ctx)
{
    VideoLayer* videoLayer = (__bridge VideoLayer*)ctx;
    dispatch_async(videoLayer.queue, ^{
        if (![videoLayer isAsynchronous])
            [videoLayer display];
    });

}

- (void)initMPV
{
    NSArray* args = [NSProcessInfo processInfo].arguments;
    if (args.count < 2) {
        NSLog(@"Expected filename on command line");
        exit(1);
    }
    NSString* filename = args[1];

    mpv = mpv_create();
    if (!mpv) {
        printf("failed creating context\n");
        exit(1);
    }

    check_error(mpv_set_option_string(mpv, "terminal", "yes"));
    check_error(mpv_set_option_string(mpv, "input-media-keys", "yes"));
    check_error(mpv_set_option_string(mpv, "input-ipc-server", "/tmp/mpvsocket"));
    check_error(mpv_set_option_string(mpv, "input-default-bindings", "yes"));
    check_error(mpv_set_option_string(mpv, "config", "yes"));
    //check_error(mpv_set_option_string(mpv, "msg-level", "all=v"));
    check_error(mpv_set_option_string(mpv, "config-dir", [NSString stringWithFormat:@"%@/.config/mpv", NSHomeDirectory()].UTF8String));
    check_error(mpv_set_option_string(mpv, "vo", "opengl-cb"));
    check_error(mpv_set_option_string(mpv, "display-fps", "60"));

    check_error(mpv_initialize(mpv));

    mpv_cb_ctx = mpv_get_sub_api(mpv, MPV_SUB_API_OPENGL_CB);
    if (!mpv_cb_ctx) {
        printf("libmpv does not have the opengl-cb sub-API.\n");
        exit(1);
    }

    int r = mpv_opengl_cb_init_gl(mpv_cb_ctx, NULL, get_proc_address, NULL);
    if (r < 0) {
        printf("gl init has failed.\n");
        exit(1);
    }

    mpv_opengl_cb_set_update_callback(mpv_cb_ctx, updateCallback, (__bridge void*)self);

    mpv_set_wakeup_callback(mpv, wakeup, (__bridge void *)self);

    self.queue = dispatch_queue_create("io.mpv.callbackQueue", DISPATCH_QUEUE_SERIAL);
    dispatch_async(self.queue, ^{
        const char* cmd[] = { "loadfile", filename.UTF8String, NULL };
        check_error(mpv_command(mpv, cmd));
    });
}

- (void)uninitMPV
{
    const char* cmd[] = { "quit", NULL };
    check_error(mpv_command(mpv, cmd));
}

static void wakeup(void *context)
{
    VideoLayer *vlayer = (__bridge VideoLayer *) context;
    [vlayer readEvents];
}

- (void) readEvents
{
    dispatch_async(dispatch_get_main_queue(), ^{
        while (mpv) {
            mpv_event *event = mpv_wait_event(mpv, 0);
            if (event->event_id == MPV_EVENT_NONE)
                break;
            [self handleEvent:event];
        }
    });
}

- (void) handleEvent:(mpv_event *)event
{
    switch (event->event_id) {
    case MPV_EVENT_SHUTDOWN: {
        mpv_opengl_cb_uninit_gl(mpv_cb_ctx);
        mpv_cb_ctx = NULL;
        mpv_detach_destroy(mpv);
        mpv = NULL;
        [NSApp terminate:self];
        break;
    }
    case MPV_EVENT_LOG_MESSAGE: {
        struct mpv_event_log_message *msg = (struct mpv_event_log_message *)event->data;
        printf("[%s] %s: %s", msg->prefix, msg->level, msg->text);
    }
    default:
        printf("event: %s\n", mpv_event_name(event->event_id));
    }
}

static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp* now,
                                    const CVTimeStamp* outputTime, CVOptionFlags flagsIn,
                                    CVOptionFlags* flagsOut, void* displayLinkContext)
{
    struct mpv_opengl_cb_context* ctx = displayLinkContext;

    if (ctx)
        mpv_opengl_cb_report_flip(ctx, 0);

    return kCVReturnSuccess;
}

- (void)initDisplaylink
{
    NSDictionary* sinfo = [[NSScreen mainScreen] deviceDescription];
    CGDirectDisplayID display_id = [[sinfo objectForKey:@"NSScreenNumber"] longValue];

    CVDisplayLinkCreateWithCGDisplay(display_id, &link);
    CVDisplayLinkSetOutputCallback(link, &displayLinkCallback, mpv_cb_ctx);
    CVDisplayLinkStart(link);
}

- (void)uninitDisplaylink
{
    if (CVDisplayLinkIsRunning(link))
        CVDisplayLinkStop(link);
    CVDisplayLinkRelease(link);
}

- (void)isInLiveResize:(BOOL)live
{
    inLiveResize = live;
    if (!inLiveResize) {
        [self setAsynchronous:NO];
        dispatch_async(self.queue, ^{
            [self display];
        });
    } else {
        [self setAsynchronous:YES];
    }
}

@end

@interface VideoView : NSView
@end

@implementation VideoView

- (id)initWithFrame:(NSRect)frame
{
    if (self = [super initWithFrame:frame]) {
        [self setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
        [self setWantsBestResolutionOpenGLSurface:YES];
    }
    return self;
}
@end

@interface VideoWindow : NSWindow <NSWindowDelegate> {
    NSRect windowFrame;
    VideoLayer* vlayer;
}
@end

@implementation VideoWindow

- (id)initWithContentRect:(NSRect)contentRect
                styleMask:(NSWindowStyleMask)style
                  backing:(NSBackingStoreType)bufferingType
                    defer:(BOOL)flag
{
    if (self = [super initWithContentRect:contentRect
                                styleMask:style
                                  backing:bufferingType
                                    defer:flag]) {
        [self setTitle:@"test"];
        [self setMinSize:NSMakeSize(200, 200)];
        [self makeMainWindow];
        [self makeKeyAndOrderFront:nil];
        self.delegate = self;

        windowFrame = [self convertRectToScreen:[[self contentView] frame]];
        [self setContentAspectRatio:[[self contentView] frame].size];
    }
    return self;
}

- (BOOL)canBecomeMainWindow { return YES; }
- (BOOL)canBecomeKeyWindow { return YES; }

- (void)setLayer:(VideoLayer *)videoLayer
{
    vlayer = videoLayer;
}

- (void)windowWillStartLiveResize:(NSNotification *)notification
{
    [vlayer isInLiveResize:YES];
}

- (void)windowDidEndLiveResize:(NSNotification *)notification
{
    [vlayer isInLiveResize:NO];
}

- (NSArray *)customWindowsToEnterFullScreenForWindow:(NSWindow *)window
{
    return [NSArray arrayWithObject:window];
}

- (NSArray*)customWindowsToExitFullScreenForWindow:(NSWindow*)window
{
    return [NSArray arrayWithObject:window];
}

- (void)window:(NSWindow *)window startCustomAnimationToEnterFullScreenWithDuration:(NSTimeInterval)duration
{
    windowFrame = [self convertRectToScreen:[[self contentView] frame]];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [context setDuration:duration*0.9];
        [[window animator] setFrame:[self screen].frame display:YES];
    } completionHandler:^{}];
}

- (void)window:(NSWindow *)window startCustomAnimationToExitFullScreenWithDuration:(NSTimeInterval)duration
{
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [context setDuration:duration*0.9];
        [[window animator] setFrame:windowFrame display:YES];
    } completionHandler:^{
    }];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
    [self setContentAspectRatio:windowFrame.size];
}

- (void)windowDidFailToEnterFullScreen:(NSWindow *)window {}

- (void)windowDidFailToExitFullScreen:(NSWindow *)window {}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
    [vlayer uninitMPV];
    return false;
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate> {
    VideoWindow* vwindow;
    VideoView* vview;
    VideoLayer* vlayer;
}
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    atexit_b(^{
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    });

    int mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

    vwindow =
        [[VideoWindow alloc] initWithContentRect:NSMakeRect(300, 300, 1280, 720)
                                       styleMask:mask
                                         backing:NSBackingStoreBuffered
                                           defer:NO];

    vview = [[VideoView alloc] initWithFrame:[[vwindow contentView] bounds]];
    [vwindow.contentView addSubview:vview];

    vlayer = [[VideoLayer alloc] init];
    [vview setLayer:vlayer];
    vview.wantsLayer = YES;
    [vwindow setLayer:vlayer];

    [NSApp setMenu:[self mainMenu]];

    [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    NSAppleEventManager *em = [NSAppleEventManager sharedAppleEventManager];
    [em setEventHandler:self
            andSelector:@selector(quit)
          forEventClass:kCoreEventClass
             andEventID:kAEQuitApplication];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return YES;
}

- (NSMenu *)mainMenu
{
    NSMenu* m = [[NSMenu alloc] initWithTitle:@"AMainMenu"];
    NSMenuItem* item = [m addItemWithTitle:@"Apple" action:nil keyEquivalent:@""];
    NSMenu* sm = [[NSMenu alloc] initWithTitle:@"Apple"];
    [m setSubmenu:sm forItem:item];

    [sm addItemWithTitle:@"Fullscreen" action:@selector(fullscreen) keyEquivalent:@"f"];
    [sm addItemWithTitle:@"Quit" action:@selector(quit) keyEquivalent:@"q"];

    return m;
}

- (void)quit
{
    [vlayer uninitMPV];
}

- (void)fullscreen
{
    [vwindow toggleFullScreen:self];
}

@end


int main(int argc, const char* argv[])
{
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        AppDelegate* delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
