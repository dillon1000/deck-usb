#pragma once
#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <AudioToolbox/AudioToolbox.h>
#include "usb.hpp"
#include "audio-buffer.hpp"
#include "mac-frame.hpp"
using namespace deckusb;

// One viewer session, defined in mac.mm. Stop USB workers before destroying
// audioOutput. Atomic gates are shared with USB, audio, and rendering callbacks.
extern std::atomic<bool> forwardingInput, showingVideo, mutingAudio;
extern std::unique_ptr<USB> usb;
extern bool demo, syncDisplay, pipelinedUSB, useDisplayLink, tracePresentation;
extern double sensitivity;

// Pull bounded PCM from the USB receiver into Core Audio. Construction throws
// on device errors; destruction stops the callback before releasing its state.
class AudioOutput {
    AudioUnit unit = nullptr;
    std::mutex mutex;
    PcmBuffer buffer;
    uint64_t packets = 0, nonzero = 0, callbacks = 0;
    static void check(OSStatus result);
    static OSStatus render(void* context, AudioUnitRenderActionFlags*, const AudioTimeStamp*,
                           UInt32, UInt32 frames, AudioBufferList* output);
public:
    AudioOutput();
    ~AudioOutput();
    void receive(const AudioPacket& packet);
    std::string stats();
    double bufferedMilliseconds();
    uint64_t underruns();
    double targetMilliseconds();
    void report();
};
extern std::unique_ptr<AudioOutput> audioOutput;

// A native Metal surface. There is one pending frame and one GPU submission.
// New arrivals replace the pending frame; GPU completion schedules the newest.
@interface DeckView : NSView <CAMetalDisplayLinkDelegate> {
    CAMetalDisplayLink* displayLink;
    std::atomic<bool> displayLinked;
    CAMetalLayer* metalLayer;
    dispatch_queue_t renderQueue;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLTexture> plane0, plane1;
    std::shared_ptr<DisplayFrame> latest;
    std::mutex frameMutex;
    std::atomic<bool> drawQueued, renderStopped;
    std::atomic<unsigned> inputWidth, inputHeight;
    std::atomic<double> presentedDelayMs;
    double latestReceiveTime;
    bool gpuBusy, captured;
    uint64_t displayedFrames, lastDisplayedFrames, displayRateTime;
    std::atomic<double> displayFPS;
    std::atomic<uint64_t> presentedAtNs;
    uint32_t width, height, format;
    double motionX, motionY, scrollX, scrollY;
    uint64_t rendered;
    std::atomic<double> submitDelayMs, decodeDelayMs;
    NSTrackingArea* tracking;
}
- (instancetype)initWithFrame:(NSRect)rect device:(id<MTLDevice>)device;
- (void)receive:(std::shared_ptr<DisplayFrame>)frame;
- (void)renderFrame;
- (void)renderDrawable:(id<CAMetalDrawable>)drawable;
- (void)stopRendering;
- (void)setDisplaySync:(BOOL)enabled;
- (double)presentationDelay;
- (double)presentationFPS;
- (void)scheduleDraw;
- (void)releaseInput;
- (void)togglePointer:(id)sender;
- (double)submitDelay;
- (double)decodeDelay;
@end


@interface BandwidthGraph : NSView {
    std::vector<std::pair<uint64_t, double>> points;
}
@property double windowSeconds;
@property NSString* timeLabel;
- (void)sample:(double)rate;
- (void)clear;
@end
// Native controls stay outside the Metal surface, so UI updates never add work
// to the video or audio render callbacks. Only the live surface forwards input.
enum class Screen { waiting, testing, result, playing, applying };
NSImage* symbol(NSString* name);

@interface App : NSObject <NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation> {
    Screen screen;
    NSUInteger generation;
    bool testNeeded, testStarted, receivedFirst, awaitingLive;
    uint64_t testRequest, testStart, testBytes, lastTime, lastBytes, lastFrames;
    double measuredMB;
    VideoSetting recommended, requested;
    TransferMeter liveMeter;
    uint64_t lastSensorSample;
}
@property BOOL closing;
@property NSButton* displayButton;
@property NSButton* infoButton;
@property NSPopover* displaySettings;
@property NSTextField* bandwidth;
@property NSWindow* window;
@property DeckView* view;
@property NSView* overlay;
@property NSImageView* heroIcon;
@property NSTextField* headline;
@property NSTextField* message;
@property NSTextField* usbWarning;
@property NSTextField* metric;
@property NSTextField* connection;
@property NSTextField* status;
@property NSTextField* performance;
@property NSTextField* deckStats;
@property NSProgressIndicator* progress;
@property NSButton* primary;
@property NSButton* secondary;
@property NSButton* startupTest;
@property NSButton* metalHUD;
@property NSButton* displaySync;
@property NSButton* restartViewer;
@property NSPopUpButton* resolution;
@property NSPopUpButton* rate;
@property NSPopUpButton* codec;
@property NSButton* apply;
@property NSButton* retest;
@property NSButton* mute;
@property NSButton* pointer;
@property NSPopover* details;
@property BandwidthGraph* graph;
@property BandwidthGraph* testGraph;
@property NSTextField* liveRate;
@property NSTextField* liveFrames;
@property NSTextField* liveRTT;
@property NSTextField* liveAudio;
@property NSTextField* graphConnection;
@property NSTextField* graphNote;
@property NSTextField* cableResult;
@property NSTextField* displayTiming;
@property NSLayoutConstraint* actionsWidth;
@property NSLayoutConstraint* footerHeight;
@property NSString* lastError;
// Playback and connection transitions run on the AppKit main thread.
- (void)card:(NSString*)title message:(NSString*)message icon:(NSString*)icon;
- (void)waitingCard;
- (void)connectDeck;
- (void)setSelections:(VideoSetting)s;
- (VideoSetting)selection;
- (void)play;
- (void)beginTest:(id)sender;
- (void)finishTest;
- (void)primaryAction:(id)sender;
- (void)secondaryAction:(id)sender;
- (void)startupChanged:(id)sender;
- (void)metalHUDChanged:(id)sender;
- (void)displaySyncChanged:(id)sender;
- (void)restartViewer:(id)sender;
- (void)changeTo:(VideoSetting)setting;
- (void)applySelection:(id)sender;
- (void)muteAudio:(id)sender;
- (void)capturePointer:(id)sender;
- (void)fullScreen:(id)sender;
- (void)showDetails:(id)sender;
- (void)tick;
- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar;
- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar;
- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)inserted;
- (void)showDisplay:(id)sender;
- (void)updateBandwidth:(id)sender;
- (void)selectLowLatency:(id)sender;
- (void)applicationDidFinishLaunching:(NSNotification*)note;
- (BOOL)validateMenuItem:(NSMenuItem*)item;
- (void)windowDidResignKey:(NSNotification*)note;
- (void)windowDidEnterFullScreen:(NSNotification*)note;
- (void)windowDidExitFullScreen:(NSNotification*)note;
- (void)applicationWillResignActive:(NSNotification*)note;
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app;
- (void)windowWillClose:(NSNotification*)note;
- (void)applicationWillTerminate:(NSNotification*)note;
@end

// The layout category builds native controls on the main thread. It starts
// connection polling only after the controls exist; missing resources terminate.
@interface App (Layout)
- (void)buildInterface;
- (NSButton*)button:(NSString*)title action:(SEL)action;
- (NSButton*)iconButton:(NSString*)name help:(NSString*)help action:(SEL)action;
@end
