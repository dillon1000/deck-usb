#include "mac.hpp"
#include <cmath>

std::atomic<bool> forwardingInput{false}, showingVideo{false}, mutingAudio{false};
std::unique_ptr<USB> usb;
std::unique_ptr<AudioOutput> audioOutput;
// New installations prevent tearing by default; a saved user choice overrides it.
bool demo = false, syncDisplay = true, pipelinedUSB = true, useDisplayLink = false;
// Optional per-frame timing writes to stderr; leave off during normal playback.
bool tracePresentation = false;
double sensitivity = 1.0;
double audioMinimumMs = 20; // Original stable default; lower floors are opt-in.

int main(int argc, const char** argv) {
    @autoreleasepool {
        try {
            [NSUserDefaults.standardUserDefaults registerDefaults:@{@"syncDisplay": @YES, @"audioBufferMs": @20}];
            syncDisplay = [NSUserDefaults.standardUserDefaults boolForKey:@"syncDisplay"];
            audioMinimumMs = [NSUserDefaults.standardUserDefaults doubleForKey:@"audioBufferMs"];
            if (audioMinimumMs != 12 && audioMinimumMs != 15 && audioMinimumMs != 20) audioMinimumMs = 20;
            double seconds = 0;
            bool list = false;
            for (int i=1; i<argc; ++i) {
                std::string arg = argv[i];
                if (arg == "--demo") demo = true;
                else if (arg == "--list") list = true;
                else if (arg == "--display-link") useDisplayLink = true;
                else if (arg == "--trace-present") tracePresentation = true;
                else if (arg == "--serial-usb") pipelinedUSB = false;
                else if (arg == "--vsync") syncDisplay = true;
                else if (arg == "--no-vsync") syncDisplay = false;
                else if ((arg == "--bench" || arg == "--sensitivity") && i+1<argc) {
                    double value = std::stod(argv[++i]);
                    if (!std::isfinite(value) || value <= 0 || value > 3600) throw std::runtime_error("Invalid numeric option");
                    if (arg == "--bench") seconds = value; else sensitivity = value;
                } else throw std::runtime_error("Usage: deck-usb [--list|--demo|--bench SECONDS] [--no-vsync] [--serial-usb] [--display-link] [--trace-present] [--sensitivity N]");
            }
            if (!demo) {
                usb = std::make_unique<USB>(pipelinedUSB);
                if (list) { usb->list(); return 0; }
                if (seconds) {
                    usb->connect();
                    usb->start([](std::shared_ptr<Frame>) {}, [](std::string e) { fprintf(stderr,"%s\n", e.c_str()); });
                    auto end = nowNs() + uint64_t(seconds*1e9);
                    while (usb->running() && nowNs()<end) std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    bool success = usb->running();
                    puts(usb->stats().c_str()); usb->stop(); return success ? 0 : 1;
                }
            }
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            App* app = [App new]; NSApp.delegate = app;
            // AppKit can consume key-up events while Command is held. Route
            // those releases once to the focused game view so keys cannot stick.
            id keyUps = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp handler:^NSEvent*(NSEvent* event) {
                NSResponder* target = NSApp.keyWindow.firstResponder;
                if (forwardingInput && [target isKindOfClass:DeckView.class] &&
                    (event.modifierFlags & NSEventModifierFlagCommand)) {
                    [target keyUp:event]; return nil;
                }
                return event;
            }];
            [NSApp run]; [NSEvent removeMonitor:keyUps]; usb.reset(); if (audioOutput) audioOutput->report(); audioOutput.reset();
        } catch (const std::exception& e) { fprintf(stderr,"DeckUSB: %s\n",e.what()); return 1; }
    }
    return 0;
}
