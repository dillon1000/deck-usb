#include "mac.hpp"
#import <QuartzCore/CAMetalLayer.h>
#include "mac-keys.hpp"

@implementation DeckView
- (instancetype)initWithFrame:(NSRect)rect device:(id<MTLDevice>)device {
    self = [super initWithFrame:rect];
    if (!self) return nil;
    self.wantsLayer = YES; self.layer = metalLayer = [CAMetalLayer layer];
    metalLayer.device = device; metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metalLayer.opaque = YES; metalLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    metalLayer.maximumDrawableCount = 2; metalLayer.displaySyncEnabled = syncDisplay;
    self.accessibilityLabel = @"Steam Deck display";
    renderQueue = dispatch_queue_create("DeckUSB.render", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    presentedDelayMs = -1; presentedAtNs = 0; displayedFrames = lastDisplayedFrames = 0; displayRateTime = nowNs(); displayFPS = 0;
    queue = [device newCommandQueue];
    NSError* error = nil;
    NSString* source = @R"(
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V vertexMain(uint i [[vertex_id]]) {
            const float2 xy[] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
            const float2 uv[] = { {0,1}, {1,1}, {0,0}, {1,0} };
            return {float4(xy[i], 0, 1), uv[i]};
        }
        fragment float4 fragmentMain(V v [[stage_in]], texture2d<float> t0 [[texture(0)]],
            texture2d<float> t1 [[texture(1)]], constant uint& format [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            if (format == 2) return float4(t0.sample(s, v.uv).rgb, 1);
            float y = 1.164383 * (t0.sample(s, v.uv).r - 16.0/255.0);
            float2 uv = t1.sample(s, v.uv).rg - 128.0/255.0;
            return float4(y + 1.792741 * uv.y, y - 0.213249 * uv.x - 0.532909 * uv.y,
                          y + 2.112402 * uv.x, 1);
        }
    )";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) throw std::runtime_error(error.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"vertexMain"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"fragmentMain"];
    descriptor.colorAttachments[0].pixelFormat = metalLayer.pixelFormat;
    pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) throw std::runtime_error(error.localizedDescription.UTF8String);
    if (@available(macOS 14.0, *)) {
        if (useDisplayLink && syncDisplay) {
            displayLink = [[CAMetalDisplayLink alloc] initWithMetalLayer:metalLayer];
            displayLink.delegate = self;
            // One display interval is the requested render budget, not a frame
            // queue. A callback takes the latest frame and never duplicates it.
            displayLink.preferredFrameLatency = 1;
            float maximum = NSScreen.mainScreen.maximumFramesPerSecond;
            displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, maximum, maximum);
            [displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            displayLinked = true;
        }
    }
    fprintf(stderr, "Presentation: %s\n", displayLinked ? "display link" : "arrival driven");
    if (tracePresentation) fprintf(stderr, "Display sync: %s\n", syncDisplay ? "on" : "off");
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
// Both the video shader and letterbox clear write alpha 1. Tell AppKit it does
// not need to draw content behind this surface, including before its first frame.
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (tracking) [self removeTrackingArea:tracking];
    tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:tracking];
}
// AppKit geometry remains on the main thread. Rendering reads dimensions from
// the acquired texture, so a resize cannot race with viewport construction.
- (void)layout {
    [super layout];
    CGSize size = [self convertRectToBacking:self.bounds].size;
    if (size.width > 0 && size.height > 0) metalLayer.drawableSize = size;
    [self scheduleDraw];
}
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self setNeedsLayout:YES]; }
- (void)receive:(std::shared_ptr<DisplayFrame>)frame {
    if (renderStopped) return;
    decodeDelayMs = frame->decodeMs;
    inputWidth = frame->header.width; inputHeight = frame->header.height;
    // Map USB receipt into the presentation clock before moving the frame.
    // Starting here without its elapsed age would hide hardware decode latency.
    double receivedTime = CACurrentMediaTime() - (nowNs() - frame->receivedNs) / 1e9;
    { std::lock_guard lock(frameMutex); latest = std::move(frame); latestReceiveTime = receivedTime; }
    [self scheduleDraw];
}
- (void)scheduleDraw {
    if (displayLinked || !renderQueue || renderStopped || drawQueued.exchange(true)) return;
    dispatch_async(renderQueue, ^{ @autoreleasepool {
        drawQueued = false;
        if (!gpuBusy && !renderStopped) [self renderFrame];
    }});
}
// Display-link callbacks arrive on the main run loop. Only one queued callback
// may retain a drawable; texture uploads and command encoding stay off AppKit.
- (void)metalDisplayLink:(CAMetalDisplayLink*)link needsUpdate:(CAMetalDisplayLinkUpdate*)update API_AVAILABLE(macos(14.0)) {
    (void)link;
    if (!showingVideo || renderStopped || drawQueued.exchange(true)) return;
    dispatch_async(renderQueue, ^{ @autoreleasepool {
        drawQueued = false;
        [self renderDrawable:update.drawable];
    }});
}
- (void)stopRendering {
    renderStopped = true;
    if (@available(macOS 14.0, *)) [displayLink invalidate];
    std::lock_guard lock(frameMutex); latest.reset();
}
// The settings action runs on AppKit. Pausing the optional display link lets
// arrival-driven rendering take over immediately; no USB reconnect is needed.
- (void)setDisplaySync:(BOOL)enabled {
    metalLayer.displaySyncEnabled = enabled;
    if (displayLink) { displayLinked = enabled; displayLink.paused = !enabled; }
    [self scheduleDraw];
}
// Only this serial queue touches GPU state. Acquire the drawable before taking
// the latest frame, and never run AppKit methods while waiting for scanout.
- (void)renderFrame {
    if (!showingVideo || renderStopped || gpuBusy) return;
    { std::lock_guard lock(frameMutex); if (!latest) return; }
    [self renderDrawable:[metalLayer nextDrawable]];
}
- (void)renderDrawable:(id<CAMetalDrawable>)drawable {
    if (!drawable || !showingVideo || renderStopped || gpuBusy) return;
    std::shared_ptr<DisplayFrame> frame;
    double receivedTime;
    { std::lock_guard lock(frameMutex); frame.swap(latest); receivedTime = latestReceiveTime; }
    if (!frame) return;
    double renderStart = CACurrentMediaTime();
    auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    auto& h = frame->header;
    width = h.width; height = h.height; format = h.format;
    id<MTLTexture> texture0, texture1;
    if (frame->surface) {
        texture0 = CVMetalTextureGetTexture(frame->luma.get());
        texture1 = CVMetalTextureGetTexture(frame->chroma.get());
    } else {
        MTLPixelFormat pixelFormat = format == nv12 ? MTLPixelFormatR8Unorm : MTLPixelFormatBGRA8Unorm;
        if (!plane0 || plane0.width != width || plane0.height != height || plane0.pixelFormat != pixelFormat) {
            auto texture = [&](MTLPixelFormat pixels, unsigned w, unsigned hh) {
                auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixels width:w height:hh mipmapped:NO];
                d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
                return [metalLayer.device newTextureWithDescriptor:d];
            };
            plane0 = texture(pixelFormat, width, height);
            plane1 = texture(MTLPixelFormatRG8Unorm, width / 2, height / 2);
        }
        [plane0 replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
            withBytes:frame->pixels.data() bytesPerRow:width * (format == nv12 ? 1 : 4)];
        if (format == nv12) [plane1 replaceRegion:MTLRegionMake2D(0, 0, width/2, height/2) mipmapLevel:0
            withBytes:frame->pixels.data() + width*height bytesPerRow:width];
        texture0 = plane0; texture1 = plane1;
    }
    auto command = [queue commandBuffer];
    auto encoder = [command renderCommandEncoderWithDescriptor:pass];
    CGSize drawableSize = CGSizeMake(drawable.texture.width, drawable.texture.height);
    double scale = std::min(drawableSize.width / width, drawableSize.height / height);
    [encoder setViewport:MTLViewport{(drawableSize.width-width*scale)/2,
        (drawableSize.height-height*scale)/2, width*scale, height*scale, 0, 1}];
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:texture0 atIndex:0]; [encoder setFragmentTexture:texture1 atIndex:1];
    [encoder setFragmentBytes:&format length:sizeof(format) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    submitDelayMs = (nowNs() - frame->receivedNs) / 1e6; ++rendered;
    double submittedTime = CACurrentMediaTime();
    uint64_t sequence = h.sequence;
    gpuBusy = true;
    // presentedTime and CACurrentMediaTime use the same host clock. This excludes
    // Deck capture/USB time and measures presentation, not callback delivery lag.
    [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
        double displayed = presented.presentedTime;
        dispatch_async(renderQueue, ^{
            if (displayed < receivedTime) return;
            // Match all stages to one frame. The UI's latest-stage values can
            // refer to different frames and cannot form a latency distribution.
            if (tracePresentation) fprintf(stderr, "Present: %llu %.9f %.9f %.9f %.9f\n",
                static_cast<unsigned long long>(sequence), receivedTime, renderStart, submittedTime, displayed);
            presentedDelayMs = (displayed - receivedTime) * 1000; presentedAtNs = nowNs();
            ++displayedFrames;
            double seconds = (nowNs() - displayRateTime) / 1e9;
            if (seconds >= 1) {
                displayFPS = (displayedFrames - lastDisplayedFrames) / seconds;
                lastDisplayedFrames = displayedFrames; displayRateTime = nowNs();
            }
        });
    }];
    [command presentDrawable:drawable];
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        // Keep the pixel buffer and CVMetalTexture wrappers alive through GPU use.
        (void)frame;
        dispatch_async(renderQueue, ^{
            gpuBusy = false;
            if (completed.status == MTLCommandBufferStatusError)
                NSLog(@"Metal: %@", completed.error);
            // Already on the render queue. A queued draw or display-link tick
            // keeps ownership of pacing; otherwise render the newest frame now.
            if (!displayLinked && !renderStopped && !drawQueued.load()) [self renderFrame];
        });
    }];
    [command commit];
}
- (double)decodeDelay { return decodeDelayMs.load(); }
- (double)submitDelay { return submitDelayMs.load(); }
- (double)presentationFPS { return nowNs() - presentedAtNs.load() < 1000000000ULL ? displayFPS.load() : 0; }
- (double)presentationDelay { return nowNs() - presentedAtNs.load() < 1000000000ULL ? presentedDelayMs.load() : -1; }
- (void)releaseInput {
    if (usb) { Command c; c.type = release; usb->enqueue(c); }
    if (captured) { CGAssociateMouseAndMouseCursorPosition(true); [NSCursor unhide]; captured = false; }
    motionX = motionY = scrollX = scrollY = 0;
}
- (void)togglePointer:(id)sender {
    (void)sender;
    if (!forwardingInput) return;
    bool enable = !captured;
    [self releaseInput];
    if (enable) { captured = true; [NSCursor hide]; CGAssociateMouseAndMouseCursorPosition(false); }
}
- (void)key:(NSEvent*)event down:(bool)down {
    if (!usb || !forwardingInput) return;
    forwardMacKey(event, down, [](const Command& c) { usb->enqueue(c); });
}
- (void)keyDown:(NSEvent*)event { [self key:event down:true]; }
- (void)keyUp:(NSEvent*)event { [self key:event down:false]; }
- (void)flagsChanged:(NSEvent*)event { [self key:event down:false]; }
// AppKit sends Command combinations here before keyDown. Give the viewer menu
// first refusal; forward other combinations only while the game has focus.
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    if (!usb || !forwardingInput || self.window.firstResponder != self ||
        !(event.modifierFlags & NSEventModifierFlagCommand)) return [super performKeyEquivalent:event];
    if ([NSApp.mainMenu performKeyEquivalent:event]) return YES;
    if (!linuxKey(event.keyCode)) return NO;
    [self keyDown:event]; return YES;
}
- (void)mouseMoved:(NSEvent*)event {
    unsigned inputW = inputWidth.load(), inputH = inputHeight.load();
    if (!usb || !forwardingInput || !inputW || !inputH) return;
    Command c;
    if (captured) {
        motionX += event.deltaX * sensitivity; motionY += event.deltaY * sensitivity;
        c.type = relative; c.x = std::clamp(int(motionX), -32767, 32767); c.y = std::clamp(int(motionY), -32767, 32767);
        motionX -= c.x; motionY -= c.y;
    } else {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        double scale = std::min(self.bounds.size.width / inputW, self.bounds.size.height / inputH);
        double x = (p.x - (self.bounds.size.width - inputW*scale)/2) / (inputW*scale);
        double y = 1 - (p.y - (self.bounds.size.height - inputH*scale)/2) / (inputH*scale);
        c.type = absolute; c.x = std::clamp(int(x*65535), 0, 65535); c.y = std::clamp(int(y*65535), 0, 65535);
    }
    usb->enqueue(c);
}
- (void)mouseDragged:(NSEvent*)event { [self mouseMoved:event]; }
- (void)rightMouseDragged:(NSEvent*)event { [self mouseMoved:event]; }
- (void)otherMouseDragged:(NSEvent*)event { [self mouseMoved:event]; }
- (void)button:(NSEvent*)event down:(bool)down {
    if (!usb || !forwardingInput || event.buttonNumber > 7) return;
    [self mouseMoved:event];
    Command c; c.type = key; c.code = 272 + int(event.buttonNumber); c.value = down; usb->enqueue(c);
}
- (void)mouseDown:(NSEvent*)event { [self button:event down:true]; }
- (void)mouseUp:(NSEvent*)event { [self button:event down:false]; }
- (void)rightMouseDown:(NSEvent*)event { [self button:event down:true]; }
- (void)rightMouseUp:(NSEvent*)event { [self button:event down:false]; }
- (void)otherMouseDown:(NSEvent*)event { [self button:event down:true]; }
- (void)otherMouseUp:(NSEvent*)event { [self button:event down:false]; }
- (void)scrollWheel:(NSEvent*)event {
    if (!usb || !forwardingInput) return;
    double divisor = event.hasPreciseScrollingDeltas ? 10 : 1;
    scrollX += event.scrollingDeltaX / divisor; scrollY += event.scrollingDeltaY / divisor;
    Command c; c.type = wheel; c.x = std::clamp(int(scrollX), -32767, 32767); c.y = std::clamp(int(scrollY), -32767, 32767);
    scrollX -= c.x; scrollY -= c.y;
    if (c.x || c.y) usb->enqueue(c);
}
@end
