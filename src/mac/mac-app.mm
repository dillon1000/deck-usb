#include "mac.hpp"
#include "mac-stats.hpp"
#include "mac-decoder.hpp"
#include <cmath>

@implementation App
// Every state sets all transient controls. Reconnects cannot leave a stale Skip
// button, a running progress bar, or game input active under the connection card.
- (void)card:(NSString*)title message:(NSString*)message icon:(NSString*)icon {
    forwardingInput = false; showingVideo = false; [self.view releaseInput];
    self.performance.stringValue = @""; self.pointer.enabled = NO;
    self.usbWarning.hidden = !usb || !usb->running() || usb->speed() != LIBUSB_SPEED_HIGH;
    self.overlay.hidden = NO; self.headline.stringValue = title; self.message.stringValue = message;
    self.heroIcon.image = [symbol(icon) imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:30 weight:NSFontWeightRegular]]; self.metric.hidden = YES;
    self.progress.hidden = YES; [self.progress stopAnimation:nil];
    self.primary.hidden = YES; self.secondary.hidden = YES; self.actionsWidth.constant = 180; self.testGraph.hidden = YES;

    self.apply.enabled = NO; self.retest.enabled = NO; [self.displaySettings close]; [self.details close];
}
- (void)waitingCard {
    [self card:@"Connect your Steam Deck" message:@"Connect a USB-C data cable, then start DeckUSB on the Deck.\nThis window connects automatically." icon:@"cable.connector"];
    self.progress.hidden = NO; self.progress.indeterminate = YES; [self.progress startAnimation:nil];
    self.secondary.hidden = NO; self.secondary.title = @"Skip cable test";
    self.secondary.enabled = testNeeded;
    if (!testNeeded) self.secondary.title = @"Cable test skipped";
    self.status.stringValue = @"Waiting for your Deck"; self.connection.stringValue = @"Not connected"; self.window.subtitle = @"Not connected";
}
- (void)connectDeck {
    if (self.closing) return;
    NSUInteger attempt = ++generation;
    usb.reset(); audioOutput.reset(); receivedFirst = false; liveMeter = TransferMeter{}; [self.graph clear];
    try {
        usb = std::make_unique<USB>(pipelinedUSB); usb->connect();
        audioOutput = std::make_unique<AudioOutput>();
        self.connection.stringValue = [NSString stringWithUTF8String:USB::speedName(usb->speed())];
        self.window.subtitle = usb->speed() >= LIBUSB_SPEED_SUPER ? @"USB 3 · Direct connection" : @"USB 2 · Limited bandwidth";
        auto decoder = std::make_shared<H264Worker>(((CAMetalLayer*)self.view.layer).device,
            [view=self.view](std::shared_ptr<DisplayFrame> frame) { if (showingVideo.load()) [view receive:std::move(frame)]; },
            [connection=usb.get()](const Header& header, const std::string& error) {
                fprintf(stderr, "H.264 unavailable: %s; restoring raw video\n", error.c_str());
                Command c; c.type = configure; c.x = header.width; c.y = header.height;
                c.value = header.reserved[2]; c.code = nv12; connection->enqueue(c);
            });
        usb->start([decoder](std::shared_ptr<Frame> frame) {
                if (showingVideo.load()) decoder->submit(std::move(frame));
            }, [owner=self, attempt](std::string error) {
                NSString* message = [NSString stringWithUTF8String:error.c_str()];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (owner.closing || attempt != owner->generation) return;
                    owner.lastError = message; owner->testStarted = false;
                    if (owner->screen != Screen::applying) {
                        // A physical reconnect gets a fresh measurement. An
                        // interrupted startup test remains skippable.
                        if (owner->screen == Screen::playing || owner->screen == Screen::result)
                            owner->testNeeded = owner.startupTest.state == NSControlStateValueOn;
                        owner->screen = Screen::waiting; [owner waitingCard];
                        owner.headline.stringValue = @"Reconnecting to your Deck";
                        owner.message.stringValue = @"The USB connection was interrupted. Keep the cable connected; playback resumes here.";
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        if (attempt == owner->generation) [owner connectDeck];
                    });
                });
            }, [](const AudioPacket& packet) { audioOutput->receive(packet); });
    } catch (const std::exception& e) {
        self.lastError = [NSString stringWithUTF8String:e.what()];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (attempt == generation) [self connectDeck];
        });
    }
}
- (void)setSelections:(VideoSetting)s {
    NSString* title = [NSString stringWithFormat:@"%u × %u", s.width, s.height];
    if ([self.resolution indexOfItemWithTitle:title] >= 0) [self.resolution selectItemWithTitle:title];
    [self.rate selectItemWithTag:s.fps]; [self.codec selectItemWithTag:s.format];
    [self.quality selectItemWithTag:s.quality];
}
- (VideoSetting)selection {
    unsigned width = unsigned(self.resolution.selectedTag);
    return {width, [self.resolution.selectedItem.representedObject unsignedIntValue], unsigned(self.rate.selectedTag),
        unsigned(self.codec.selectedTag), unsigned(self.quality.selectedTag)};
}
- (void)play {
    // Stop benchmark mode before accepting input. The next live frame confirms
    // the transition; the audio and video clocks continue independently.
    if (usb) { Command c; c.type = measure; c.value = 0; usb->enqueue(c); }
    if (usb && !usb->live()) { [self changeTo:[self selection]]; return; }
    screen = Screen::playing; awaitingLive = true;
    self.overlay.hidden = YES; self.apply.enabled = YES; self.retest.enabled = YES;
    showingVideo = true; forwardingInput = false;
    self.status.stringValue = @"Starting playback…";
    [self.window makeFirstResponder:self.view];
    lastTime = nowNs(); lastFrames = usb ? usb->frames() : 0; lastBytes = usb ? usb->bytes() : 0;
}
- (void)beginTest:(id)sender {
    (void)sender;
    if (!usb || !usb->running() || screen == Screen::testing || screen == Screen::applying) return;
    screen = Screen::testing; testStarted = false; testRequest = nowNs();
    [self card:@"Checking your USB cable" message:@"Measuring transfer speed to find a smooth display setting.\nYour game keeps running on the Deck." icon:@"bolt.horizontal.circle.fill"];
    [self.testGraph clear]; self.testGraph.hidden = NO;
    self.metric.hidden = NO; self.metric.stringValue = @"Measuring…";
    self.progress.hidden = NO; self.progress.indeterminate = NO;
    self.progress.minValue = 0; self.progress.maxValue = 100; self.progress.doubleValue = 0;
    self.secondary.hidden = NO; self.secondary.enabled = YES; self.secondary.title = @"Skip test & play";
    self.status.stringValue = @"Cable test · about 4 seconds";
    Command c; c.type = measure; c.value = 1; usb->enqueue(c);
}
- (void)finishTest {
    testNeeded = false; screen = Screen::result;
    Command c; c.type = measure; c.value = 0; usb->enqueue(c);
    recommended = recommend(measuredMB);
    double minimum = (frameBytes(640, 400, nv12) * 30.0 / 1e6 + 0.2) / 0.95;
    [self card:measuredMB >= minimum ? @"Ready to play" : @"This connection is slow"
       message:[NSString stringWithFormat:@"%u × %u at %u fps is recommended for this cable.\n%@", recommended.width, recommended.height, recommended.fps,
           measuredMB >= minimum ? @"You can change this in Display settings." : @"Even the lowest setting may stutter. Try another data cable."]
       icon:measuredMB >= minimum ? @"checkmark.circle.fill" : @"exclamationmark.triangle.fill"];
    self.metric.stringValue = [NSString stringWithFormat:@"Measured speed  ·  %.1f MB/s", measuredMB]; self.metric.hidden = NO;
    self.primary.hidden = NO; self.primary.title = @"Use recommended"; self.actionsWidth.constant = 372;
    self.secondary.hidden = NO; self.secondary.enabled = YES; self.secondary.title = @"Keep current";
    self.status.stringValue = @"Cable test complete";
    [[NSUserDefaults standardUserDefaults] setDouble:measuredMB forKey:@"lastCableMB"];
}
- (void)primaryAction:(id)sender { (void)sender; [self changeTo:recommended]; }
- (void)secondaryAction:(id)sender {
    (void)sender; testNeeded = false;
    if (screen == Screen::waiting) { self.secondary.enabled = NO; self.secondary.title = @"Cable test skipped"; return; }
    [self play];
}
- (void)startupChanged:(id)sender {
    (void)sender;
    [[NSUserDefaults standardUserDefaults] setBool:self.startupTest.state == NSControlStateValueOn forKey:@"testOnStart"];
}
- (void)changeTo:(VideoSetting)setting {
    if (!usb || !usb->running()) return;
    auto current = usb->setting();
    if (usb->live() && current.width == setting.width && current.height == setting.height && current.fps == setting.fps && current.format == setting.format &&
        (setting.format != h264 || current.quality == setting.quality)) {
        [self setSelections:setting]; [self play]; return;
    }
    requested = setting; testNeeded = false; screen = Screen::applying;
    [self card:@"Updating your display" message:[NSString stringWithFormat:@"Switching to %u × %u at %u fps.\nPlayback resumes automatically.", setting.width, setting.height, setting.fps] icon:@"display"];
    self.progress.hidden = NO; self.progress.indeterminate = YES; [self.progress startAnimation:nil];
    self.status.stringValue = @"Applying display settings…";
    Command c; c.type = configure; c.x = setting.width; c.y = setting.height; c.value = setting.fps; c.code = setting.format;
    c.nonce = setting.quality;
    usb->enqueue(c);
}
- (void)applySelection:(id)sender { (void)sender; [self.displaySettings close]; [self changeTo:[self selection]]; }
- (void)muteAudio:(id)sender {
    (void)sender; bool muted = !mutingAudio.load(); mutingAudio = muted;
    self.mute.image = symbol(muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill");
    self.mute.toolTip = muted ? @"Unmute audio" : @"Mute audio"; self.mute.accessibilityLabel = self.mute.toolTip;
}
- (void)capturePointer:(id)sender { [self.view togglePointer:sender]; [self.window makeFirstResponder:self.view]; }
- (void)fullScreen:(id)sender { [self.window toggleFullScreen:sender]; }
- (void)showDetails:(id)sender {
    (void)sender;
    [self.displaySettings close];
    if (self.details.shown) { [self.details close]; return; }
    // The footer disappears in full screen; the menu shortcut uses the video
    // corner as its anchor so diagnostics remain accessible without a toolbar.
    bool fullScreen = self.window.styleMask & NSWindowStyleMaskFullScreen;
    NSView* anchor = fullScreen ? self.view : self.infoButton;
    NSRect rect = fullScreen ? NSMakeRect(NSWidth(anchor.bounds) - 24, 8, 1, 1) : anchor.bounds;
    [self.details showRelativeToRect:rect ofView:anchor preferredEdge:NSRectEdgeMaxY];
}
- (void)tick {
    if (demo) return;
    auto sensors = usb ? usb->deckStats() : DeckStats{};
    if (sensors.sampledNs != lastSensorSample || !self.deckStats.toolTip) {
        lastSensorSample = sensors.sampledNs;
        self.deckStats.stringValue = deckStatsSummary(sensors);
        self.deckStats.toolTip = deckStatsDetails(sensors);
        self.deckStats.accessibilityLabel = self.deckStats.toolTip;
    }
    if (!usb || !usb->running()) {
        self.graphConnection.stringValue = @"Reconnecting…"; self.liveRate.stringValue = @"—";
        self.graphNote.stringValue = @"Waiting for the USB connection.";
    }
    if (!usb || !usb->running() || !usb->frames()) return;
    if (!receivedFirst) {
        receivedFirst = true;
        [self setSelections:usb->setting()];
        if (screen == Screen::applying) {
            auto actual = usb->setting();
            if (actual.width != requested.width || actual.height != requested.height || actual.fps != requested.fps || actual.format != requested.format ||
                (requested.format == h264 && actual.quality != requested.quality)) {
                self.lastError = @"The Deck did not apply the requested display setting.";
                [self card:@"Display setting was not applied" message:@"The Deck kept its previous setting. You can resume playback and try again." icon:@"exclamationmark.triangle"];
                self.secondary.hidden = NO; self.secondary.enabled = YES; self.secondary.title = @"Resume playback";
                return;
            }
            [self play];
        } else if (testNeeded) [self beginTest:nil];
        else [self play];
    }
    uint64_t now = nowNs();
    if (!liveMeter.time || now - liveMeter.time >= 250000000ULL) {
        if (liveMeter.update(now, usb->bytes(), usb->frames())) {
            [self.graph sample:liveMeter.megabytesPerSecond];
            self.liveRate.stringValue = [NSString stringWithFormat:@"%.1f", liveMeter.megabytesPerSecond];
            self.liveFrames.stringValue = [NSString stringWithFormat:@"%.0f fps", liveMeter.framesPerSecond];
            self.liveRTT.stringValue = [NSString stringWithFormat:@"%.2f ms", usb->medianRTT()];
            self.liveAudio.stringValue = [NSString stringWithFormat:@"%.0f ms", audioOutput ? audioOutput->bufferedMilliseconds() : 0];
            bool usb2 = usb->speed() == LIBUSB_SPEED_HIGH;
            self.graphConnection.stringValue = usb2 ? @"⚠ USB 2 · 480 Mbit/s · Limited bandwidth" : self.connection.stringValue;
            self.graphConnection.textColor = usb2 ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
            uint64_t gaps = audioOutput ? audioOutput->underruns() : 0;
            self.graphNote.stringValue = [NSString stringWithFormat:@"Audio target %.0f ms · %llu interruptions", audioOutput ? audioOutput->targetMilliseconds() : 0, (unsigned long long)gaps];
            double presented = [self.view presentationDelay];
            self.displayTiming.stringValue = presented >= 0 ? [NSString stringWithFormat:@"Mac display %.0f fps · receive → display %.1f ms", [self.view presentationFPS], presented] : @"Mac display not presenting";
            self.cableResult.stringValue = measuredMB > 0 ? [NSString stringWithFormat:@"Cable test  %.1f MB/s", measuredMB] : @"Cable not tested";
            if (screen == Screen::testing && testStarted) {
                [self.testGraph sample:liveMeter.megabytesPerSecond];
                self.metric.stringValue = [NSString stringWithFormat:@"%.1f MB/s", liveMeter.megabytesPerSecond];
            }
        }
    }
    if (screen == Screen::testing) {
        if (!testStarted && usb->measuring() && now - testRequest >= 500000000ULL) {
            testStarted = true; testStart = now; testBytes = usb->bytes();
        }
        if (!testStarted && now - testRequest > 5000000000ULL) {
            screen = Screen::result; testNeeded = false;
            [self card:@"The cable test did not start" message:@"You can keep your current display settings and play. Use Test cable to try again." icon:@"exclamationmark.triangle"];
            self.secondary.hidden = NO; self.secondary.enabled = YES; self.secondary.title = @"Skip test & play";
            return;
        }
        if (testStarted) {
            double seconds = (now - testStart) / 1e9;
            self.progress.doubleValue = std::min(100.0, seconds / 3 * 100);
            self.status.stringValue = [NSString stringWithFormat:@"Testing cable · %.0f s remaining", std::max(0.0, std::ceil(3 - seconds))];
            if (seconds >= 3) { measuredMB = (usb->bytes() - testBytes) / seconds / 1e6; [self finishTest]; }
        }
    }
    if (screen == Screen::playing) {
        if (awaitingLive && !usb->measuring()) { awaitingLive = false; forwardingInput = true; self.pointer.enabled = YES; }
        if (now - lastTime >= 1000000000ULL) {
            double seconds = (now - lastTime) / 1e9;
            uint64_t frames = usb->frames(), bytes = usb->bytes();
            auto setting = usb->setting();
            self.status.stringValue = [NSString stringWithFormat:@"●  Connected · %u × %u · %@", setting.width, setting.height, setting.format == h264 ? @"H.264" : @"Raw"];
            self.performance.stringValue = [NSString stringWithFormat:@"%.0f fps   ·   %.1f MB/s   ·   USB audio", (frames - lastFrames) / seconds, (bytes - lastBytes) / seconds / 1e6];
            self.status.toolTip = self.status.stringValue; self.performance.toolTip = self.performance.stringValue;
            if (frames / 300 != lastFrames / 300)
                fprintf(stderr, "Timing: Deck queue %.2f ms, USB payload %.2f ms, decode %.2f ms, Mac submit %.2f ms, present %.2f ms at %.1f fps; %s; %s\n", usb->deckQueueMilliseconds(), usb->payloadMilliseconds(), [self.view decodeDelay], [self.view submitDelay], [self.view presentationDelay], [self.view presentationFPS], usb->stats().c_str(), audioOutput ? audioOutput->stats().c_str() : "no audio");
            lastTime = now; lastFrames = frames; lastBytes = bytes;
        }
    }
}
- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar {
    (void)toolbar;
    return @[NSToolbarFlexibleSpaceItemIdentifier, @"audio", @"pointer", NSToolbarSpaceItemIdentifier, @"cable", @"display"];
}
- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}
- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)inserted {
    (void)toolbar; (void)inserted;
    NSDictionary* buttons = @{@"audio": self.mute, @"pointer": self.pointer, @"cable": self.retest, @"display": self.displayButton};
    NSButton* button = buttons[identifier];
    if (!button) return nil;
    auto item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    item.view = button; item.label = button.toolTip; item.paletteLabel = button.toolTip;
    item.autovalidates = NO;
    return item;
}
// Settings use a transient native popover. Pending selections stay in the
// controls when dismissed; Apply is explicit because it restarts the stream.
- (void)showDisplay:(id)sender {
    (void)sender; [self.details close];
    if (self.displaySettings.shown) { [self.displaySettings close]; return; }
    [self updateBandwidth:nil];
    [self.displaySettings showRelativeToRect:self.displayButton.bounds ofView:self.displayButton preferredEdge:NSRectEdgeMinY];
}
- (void)selectLowLatency:(id)sender {
    (void)sender;
    [self setSelections:recommend(measuredMB, true)]; [self updateBandwidth:nil];
}
// HUD instrumentation is selected at launch, so disabling it also removes its
// measurement overhead on restart. Keep the preference local to this app.
- (void)metalHUDChanged:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setBool:self.metalHUD.state == NSControlStateValueOn forKey:@"MetalHUDForceEnabled"];
    self.restartViewer.enabled = YES;
}
- (void)displaySyncChanged:(id)sender {
    (void)sender;
    syncDisplay = self.displaySync.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:syncDisplay forKey:@"syncDisplay"];
    [self.view setDisplaySync:syncDisplay];
    fprintf(stderr, "Display sync: %s\n", syncDisplay ? "on" : "off");
}
- (void)restartViewer:(id)sender {
    (void)sender; [self.view releaseInput];
    auto configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    configuration.arguments = [NSProcessInfo.processInfo.arguments subarrayWithRange:NSMakeRange(1, NSProcessInfo.processInfo.arguments.count - 1)];
    configuration.environment = @{@"MTL_HUD_ENABLED": self.metalHUD.state == NSControlStateValueOn ? @"1" : @"0"};
    [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:configuration
        completionHandler:^(NSRunningApplication* application, NSError* error) {
            (void)application;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) { self.bandwidth.stringValue = error.localizedDescription; return; }
                [NSApp terminate:nil];
            });
        }];
}
- (void)updateBandwidth:(id)sender {
    (void)sender;
    auto s = [self selection];
    self.quality.enabled = s.format == h264;
    if (s.format == h264) {
        self.bandwidth.textColor = NSColor.secondaryLabelColor;
        self.bandwidth.stringValue = @"Hardware H.264 uses less USB bandwidth. Image quality and data rate depend on the scene.";
        return;
    }
    double required = frameBytes(s.width, s.height, nv12) * double(s.fps) / 1e6 + 0.2;
    bool exceeds = measuredMB > 0 && required > measuredMB;
    self.bandwidth.textColor = exceeds ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    self.bandwidth.stringValue = measuredMB > 0 ? [NSString stringWithFormat:@"Needs %.1f MB/s. Your cable measured %.1f MB/s.%@", required, measuredMB,
        exceeds ? @" A lower setting will play more smoothly." : @""] : @"Test your cable to find the best display setting.";
}
- (void)applicationDidFinishLaunching:(NSNotification*)note { (void)note; [self buildInterface]; }
// Menu commands remain available when the toolbar is hidden or customized.
// Their titles and enabled states reflect the current playback state.
- (BOOL)validateMenuItem:(NSMenuItem*)item {
    if (item.action == @selector(beginTest:)) return usb && usb->running() && screen != Screen::testing && screen != Screen::applying;
    if (item.action == @selector(capturePointer:)) return forwardingInput;
    if (item.action == @selector(muteAudio:)) item.title = mutingAudio ? @"Unmute Audio" : @"Mute Audio";
    if (item.action == @selector(fullScreen:)) item.title = (self.window.styleMask & NSWindowStyleMaskFullScreen) ? @"Exit Full Screen" : @"Enter Full Screen";
    return YES;
}
- (void)windowDidResignKey:(NSNotification*)note { (void)note; [self.view releaseInput]; }
// Let the opaque Metal surface fill the full-screen content area. Keeping a
// separate footer can prevent the system's direct-to-display composition path.
- (void)windowDidEnterFullScreen:(NSNotification*)note {
    (void)note; [self.details close]; self.footerHeight.constant = 0; self.status.superview.hidden = YES;
}
- (void)windowDidExitFullScreen:(NSNotification*)note {
    (void)note; [self.details close]; self.footerHeight.constant = 30; self.status.superview.hidden = NO;
}
- (void)applicationWillResignActive:(NSNotification*)note { (void)note; [self.view releaseInput]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app { (void)app; return YES; }
- (void)windowWillClose:(NSNotification*)note { (void)note; self.closing = YES; }
- (void)applicationWillTerminate:(NSNotification*)note { (void)note; self.closing = YES; ++generation; [self.view releaseInput]; [self.view stopRendering]; if (usb) usb->stop(); }
@end
