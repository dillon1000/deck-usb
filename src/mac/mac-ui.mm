#include "mac.hpp"
#include <cmath>

static NSTextField* label(NSString* text, CGFloat size, NSFontWeight weight = NSFontWeightRegular) {
    auto field = [NSTextField wrappingLabelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = NSColor.labelColor;
    return field;
}
NSImage* symbol(NSString* name) {
    return [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
}
static NSStackView* row(NSArray<NSView*>* views, CGFloat spacing = 10) {
    auto stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY; stack.spacing = spacing;
    return stack;
}

// Opaque semantic surfaces keep graphs and settings legible over moving games.
@interface PanelSurface : NSView @end
@implementation PanelSurface
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)rect { [NSColor.windowBackgroundColor setFill]; NSRectFill(rect); }
@end

@implementation BandwidthGraph
- (void)clear { points.clear(); self.needsDisplay = YES; }
- (void)sample:(double)rate {
    uint64_t now = nowNs();
    while (!points.empty() && (now - points.front().first) / 1e9 > self.windowSeconds) points.erase(points.begin());
    points.emplace_back(now, std::max(0.0, rate)); self.needsDisplay = YES;
    self.accessibilityElement = YES; self.accessibilityRole = NSAccessibilityImageRole;
    self.accessibilityLabel = [NSString stringWithFormat:@"USB throughput graph, current %.1f megabytes per second", rate];
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    double peak = 0;
    for (const auto& point : points) peak = std::max(peak, point.second);
    double ceiling = std::max(50.0, std::ceil(peak / 25) * 25);
    NSRect plot = NSMakeRect(0, 22, self.bounds.size.width, self.bounds.size.height - 42);
    NSDictionary* textStyle = @{NSFontAttributeName:[NSFont systemFontOfSize:10], NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
    [[NSString stringWithFormat:@"%.0f MB/s", ceiling] drawAtPoint:NSMakePoint(0, NSMaxY(plot) + 5) withAttributes:textStyle];
    [self.timeLabel drawAtPoint:NSMakePoint(0, 0) withAttributes:textStyle];
    [@"Now" drawAtPoint:NSMakePoint(NSMaxX(plot) - 23, 0) withAttributes:textStyle];
    [[NSColor.separatorColor colorWithAlphaComponent:0.5] setStroke];
    for (unsigned i = 0; i < 3; ++i) {
        auto line = [NSBezierPath bezierPath]; line.lineWidth = 0.5;
        CGFloat y = plot.origin.y + plot.size.height * i / 2;
        [line moveToPoint:NSMakePoint(0, y)]; [line lineToPoint:NSMakePoint(NSMaxX(plot), y)]; [line stroke];
    }
    if (points.empty()) return;
    auto line = [NSBezierPath bezierPath]; line.lineWidth = 2; line.lineJoinStyle = NSLineJoinStyleRound;
    // Use monotonic sample times so delayed UI ticks do not distort the axis.
    auto xFor = [&](uint64_t time) { return plot.size.width * (1 - (points.back().first - time) / 1e9 / self.windowSeconds); };
    CGFloat start = xFor(points.front().first);
    NSPoint last{};
    for (size_t i = 0; i < points.size(); ++i) {
        last = NSMakePoint(xFor(points[i].first), plot.origin.y + plot.size.height * points[i].second / ceiling);
        if (!i) [line moveToPoint:last]; else [line lineToPoint:last];
    }
    NSBezierPath* area = [line copy];
    [area lineToPoint:NSMakePoint(last.x, plot.origin.y)]; [area lineToPoint:NSMakePoint(start, plot.origin.y)]; [area closePath];
    NSColor* accent = NSColor.controlAccentColor;
    auto fill = [[NSGradient alloc] initWithStartingColor:[accent colorWithAlphaComponent:0.03] endingColor:[accent colorWithAlphaComponent:0.22]];
    [fill drawInBezierPath:area angle:90]; [accent setStroke]; [line stroke];
    [accent setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(last.x - 3, last.y - 3, 6, 6)] fill];
}
@end

@implementation App (Layout)
- (NSButton*)button:(NSString*)title action:(SEL)action {
    auto b = [NSButton buttonWithTitle:title target:self action:action];
    b.bezelStyle = NSBezelStyleRounded;
    b.controlSize = NSControlSizeLarge;
    return b;
}
- (NSButton*)iconButton:(NSString*)name help:(NSString*)help action:(SEL)action {
    auto b = [NSButton buttonWithImage:symbol(name) target:self action:action];
    b.bordered = NO; b.toolTip = help; b.accessibilityLabel = help;
    b.frame = NSMakeRect(0, 0, 32, 32);
    return b;
}
- (void)buildInterface {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"testOnStart": @YES}];
    testNeeded = [[NSUserDefaults standardUserDefaults] boolForKey:@"testOnStart"];
    measuredMB = [[NSUserDefaults standardUserDefaults] doubleForKey:@"lastCableMB"];
    screen = Screen::waiting;
    auto device = MTLCreateSystemDefaultDevice();
    if (!device) { NSLog(@"Metal is unavailable"); [NSApp terminate:nil]; return; }
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 820, 560)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    // Let AppKit draw the title bar, toolbar material, accent, and Light/Dark
    // appearance. Window titles identify the content, as required by the HIG.
    self.window.title = @"Steam Deck"; self.window.subtitle = @"Not connected";
    self.window.delegate = self; self.window.contentMinSize = NSMakeSize(640, 500);
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;
    self.window.backgroundColor = NSColor.windowBackgroundColor;
    self.window.acceptsMouseMovedEvents = YES;
    // Bundle the supplied artwork unchanged; AppKit renders the SVG at any scale.
    NSImage* deckImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"deck" ofType:@"svg"]];
    if (!deckImage) { NSLog(@"The bundled Deck icon could not be loaded"); [NSApp terminate:nil]; return; }
    NSApp.applicationIconImage = deckImage;
    NSView* root = self.window.contentView;
    self.view = [[DeckView alloc] initWithFrame:NSZeroRect device:device];
    self.view.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:self.view];
    self.connection = label(@"Not connected", 12);
    self.mute = [self iconButton:@"speaker.wave.2" help:@"Mute audio" action:@selector(muteAudio:)];
    self.pointer = [self iconButton:@"cursorarrow.motionlines" help:@"Capture pointer" action:@selector(capturePointer:)];
    self.retest = [self iconButton:@"cable.connector" help:@"Test cable" action:@selector(beginTest:)];
    self.displayButton = [self iconButton:@"slider.horizontal.3" help:@"Display settings" action:@selector(showDisplay:)];
    auto toolbar = [[NSToolbar alloc] initWithIdentifier:@"DeckUSB.playback"];
    toolbar.delegate = self; toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization = YES; toolbar.autosavesConfiguration = YES;
    self.window.toolbar = toolbar;

    self.resolution = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (auto size : {std::array<unsigned, 2>{640, 400}, {800, 500}, {960, 600}, {1280, 800},
        {1600, 1000}, {1920, 1080}, {1920, 1200}}) {
        [self.resolution addItemWithTitle:[NSString stringWithFormat:@"%u × %u", size[0], size[1]]];
        self.resolution.lastItem.tag = size[0];
        self.resolution.lastItem.representedObject = @(size[1]);
    }
    self.resolution.accessibilityLabel = @"Resolution";
    self.resolution.target = self; self.resolution.action = @selector(updateBandwidth:);
    self.rate = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (unsigned fps : {30u, 60u, 90u}) { [self.rate addItemWithTitle:[NSString stringWithFormat:@"%u fps", fps]]; self.rate.lastItem.tag = fps; }
    self.rate.accessibilityLabel = @"Frame rate"; self.rate.target = self; self.rate.action = @selector(updateBandwidth:);
    self.codec = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.codec addItemWithTitle:@"Uncompressed"]; self.codec.lastItem.tag = nv12;
    [self.codec addItemWithTitle:@"H.264"]; self.codec.lastItem.tag = h264;
    self.codec.accessibilityLabel = @"Video format"; self.codec.target = self; self.codec.action = @selector(updateBandwidth:);
    [self setSelections:{800, 500, 60}];
    self.apply = [self button:@"Apply" action:@selector(applySelection:)]; self.apply.keyEquivalent = @"\r";
    self.bandwidth = label(@"", 12); self.bandwidth.textColor = NSColor.secondaryLabelColor;
    self.startupTest = [NSButton checkboxWithTitle:@"Test cable at startup" target:self action:@selector(startupChanged:)];
    self.startupTest.state = testNeeded ? NSControlStateValueOn : NSControlStateValueOff;
    self.metalHUD = [NSButton checkboxWithTitle:@"Metal performance HUD" target:self action:@selector(metalHUDChanged:)];
    self.metalHUD.state = [NSUserDefaults.standardUserDefaults boolForKey:@"MetalHUDForceEnabled"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.metalHUD.toolTip = @"Apple’s graphics statistics overlay. Restart the viewer to apply a change.";
    self.displaySync = [NSButton checkboxWithTitle:@"Prevent screen tearing" target:self action:@selector(displaySyncChanged:)];
    self.displaySync.state = syncDisplay ? NSControlStateValueOn : NSControlStateValueOff;
    self.displaySync.toolTip = @"Turn off for lower display delay. Fast movement may show tearing. Changes apply immediately.";
    auto syncNote = label(@"Turn off for less delay. Fast movement may show tearing.", 12);
    syncNote.textColor = NSColor.secondaryLabelColor;
    [syncNote.widthAnchor constraintEqualToConstant:300].active = YES;
    auto syncControls = [NSStackView stackViewWithViews:@[self.displaySync, syncNote]];
    syncControls.orientation = NSUserInterfaceLayoutOrientationVertical;
    syncControls.alignment = NSLayoutAttributeLeading; syncControls.spacing = 4;
    self.restartViewer = [self button:@"Restart viewer" action:@selector(restartViewer:)];
    self.restartViewer.enabled = NO;
    auto resolutionNote = label(@"Desktop Mode renders at larger sizes after updating Deck setup. Games may need borderless mode. Gaming Mode currently scales larger streams.", 12);
    resolutionNote.textColor = NSColor.secondaryLabelColor;
    [resolutionNote.widthAnchor constraintEqualToConstant:300].active = YES;
    NSGridView* form = [NSGridView gridViewWithViews:@[@[label(@"Resolution", 13), self.resolution], @[label(@"Frame rate", 13), self.rate], @[label(@"Video", 13), self.codec]]];
    form.rowSpacing = 16; form.columnSpacing = 24;
    [form columnAtIndex:0].xPlacement = NSGridCellPlacementLeading;
    [form columnAtIndex:1].xPlacement = NSGridCellPlacementTrailing;
    auto lowLatency = [self button:@"Low latency preset" action:@selector(selectLowLatency:)];
    lowLatency.toolTip = @"Choose 640 × 400 at up to 90 fps, within the measured cable speed. Click Apply to use it.";
    auto settingsBody = [NSStackView stackViewWithViews:@[label(@"Display", 17, NSFontWeightSemibold), form, resolutionNote, lowLatency, self.bandwidth, syncControls, self.startupTest, row(@[self.metalHUD, self.restartViewer], 12), self.apply]];
    settingsBody.orientation = NSUserInterfaceLayoutOrientationVertical; settingsBody.alignment = NSLayoutAttributeLeading; settingsBody.spacing = 20;
    [self.bandwidth.widthAnchor constraintEqualToConstant:300].active = YES;
    [form.widthAnchor constraintEqualToConstant:300].active = YES;
    self.displaySettings = [NSPopover new]; self.displaySettings.behavior = NSPopoverBehaviorTransient;
    auto settingsController = [NSViewController new]; settingsController.view = [[PanelSurface alloc] initWithFrame:NSMakeRect(0, 0, 348, 590)];
    settingsBody.translatesAutoresizingMaskIntoConstraints = NO; [settingsController.view addSubview:settingsBody];
    [NSLayoutConstraint activateConstraints:@[[settingsBody.leadingAnchor constraintEqualToAnchor:settingsController.view.leadingAnchor constant:24],
        [settingsBody.topAnchor constraintEqualToAnchor:settingsController.view.topAnchor constant:24]]];
    self.displaySettings.contentViewController = settingsController;

    self.status = label(@"Waiting for your Deck", 11); self.status.textColor = NSColor.secondaryLabelColor;
    self.performance = label(@"", 11); self.performance.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.performance.textColor = NSColor.secondaryLabelColor;
    self.deckStats = [NSTextField labelWithString:@"Deck stats unavailable"];
    self.deckStats.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.deckStats.textColor = NSColor.secondaryLabelColor; self.deckStats.alignment = NSTextAlignmentCenter;
    // Center on the window, not on the space left by unequal side labels.
    // Side text truncates first on narrow windows; full readings stay in tooltips.
    for (NSTextField* field in @[self.status, self.performance, self.deckStats]) {
        field.maximumNumberOfLines = 1; field.lineBreakMode = NSLineBreakByTruncatingTail;
        [field setContentCompressionResistancePriority:field == self.deckStats ? 750 : 250 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [field.widthAnchor constraintGreaterThanOrEqualToConstant:0].active = YES;
    }
    self.infoButton = [NSButton buttonWithImage:symbol(@"info.circle") target:self action:@selector(showDetails:)];
    self.infoButton.bordered = NO; self.infoButton.toolTip = @"Connection details"; self.infoButton.accessibilityLabel = @"Connection details";
    auto footerRight = row(@[self.performance, self.infoButton], 12);
    auto footer = [NSView new]; footer.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:footer];
    self.footerHeight = [footer.heightAnchor constraintEqualToConstant:30];
    self.status.translatesAutoresizingMaskIntoConstraints = footerRight.translatesAutoresizingMaskIntoConstraints = NO;
    self.deckStats.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:self.status]; [footer addSubview:self.deckStats]; [footer addSubview:footerRight];

    NSVisualEffectView* background = [NSVisualEffectView new];
    background.material = NSVisualEffectMaterialWindowBackground;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.overlay = background; self.overlay.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:self.overlay];
    // Device symbols communicate the connection without a logo banner or a
    // decorative dashboard. Explicit symbol sizes prevent intrinsic 13 pt glyphs.
    auto macIcon = [NSImageView imageViewWithImage:[symbol(@"laptopcomputer") imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:76 weight:NSFontWeightLight]]];
    auto deckIcon = [NSImageView imageViewWithImage:deckImage];
    for (NSImageView* icon in @[macIcon, deckIcon]) {
        icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        [icon.widthAnchor constraintEqualToConstant:110].active = YES; [icon.heightAnchor constraintEqualToConstant:94].active = YES;
    }
    macIcon.contentTintColor = NSColor.secondaryLabelColor;
    macIcon.accessibilityLabel = @"Mac"; deckIcon.accessibilityLabel = @"Steam Deck";
    self.heroIcon = [NSImageView new]; self.heroIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.heroIcon.contentTintColor = NSColor.controlAccentColor;
    [self.heroIcon.widthAnchor constraintEqualToConstant:32].active = YES; [self.heroIcon.heightAnchor constraintEqualToConstant:32].active = YES;
    auto devices = row(@[macIcon, self.heroIcon, deckIcon], 24);
    self.headline = label(@"Connect your Steam Deck", 25, NSFontWeightSemibold); self.headline.alignment = NSTextAlignmentCenter;
    self.message = label(@"", 13); self.message.alignment = NSTextAlignmentCenter; self.message.textColor = NSColor.secondaryLabelColor;
    [self.message.widthAnchor constraintEqualToConstant:400].active = YES;
    self.usbWarning = label(@"⚠ USB 2 connection limits display bandwidth.\nCheck the cable, port, and Deck USB setup for USB 3 support.", 12);
    self.usbWarning.alignment = NSTextAlignmentCenter; self.usbWarning.textColor = NSColor.systemOrangeColor;
    [self.usbWarning.widthAnchor constraintEqualToConstant:400].active = YES;
    self.metric = label(@"", 13); self.metric.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    self.metric.textColor = NSColor.secondaryLabelColor;
    self.progress = [NSProgressIndicator new]; self.progress.style = NSProgressIndicatorStyleBar;
    [self.progress.widthAnchor constraintEqualToConstant:260].active = YES;
    self.primary = [self button:@"Play" action:@selector(primaryAction:)]; self.primary.keyEquivalent = @"\r";
    self.secondary = [self button:@"Skip" action:@selector(secondaryAction:)];
    auto actions = row(@[self.secondary, self.primary], 12);
    actions.distribution = NSStackViewDistributionFillEqually;
    self.actionsWidth = [actions.widthAnchor constraintEqualToConstant:372]; self.actionsWidth.active = YES;
    self.testGraph = [[BandwidthGraph alloc] initWithFrame:NSZeroRect];
    self.testGraph.windowSeconds = 3; self.testGraph.timeLabel = @"Cable test · 3 seconds";
    [self.testGraph.widthAnchor constraintEqualToConstant:372].active = YES;
    [self.testGraph.heightAnchor constraintEqualToConstant:100].active = YES;
    auto card = [NSStackView stackViewWithViews:@[devices, self.headline, self.message, self.usbWarning, self.metric, self.testGraph, self.progress, actions]];
    card.orientation = NSUserInterfaceLayoutOrientationVertical; card.alignment = NSLayoutAttributeCenterX; card.spacing = 18;
    [card setCustomSpacing:26 afterView:devices]; [card setCustomSpacing:24 afterView:self.message];
    card.translatesAutoresizingMaskIntoConstraints = NO; [self.overlay addSubview:card];
    [card.widthAnchor constraintEqualToConstant:460].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor], self.footerHeight,
        [self.status.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16], [self.status.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [footerRight.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-14], [footerRight.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [self.deckStats.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor], [self.deckStats.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [self.deckStats.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.status.trailingAnchor constant:12],
        [self.deckStats.trailingAnchor constraintLessThanOrEqualToAnchor:footerRight.leadingAnchor constant:-12],
        [self.view.topAnchor constraintEqualToAnchor:root.topAnchor], [self.view.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [self.view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [self.view.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor], [self.overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [self.overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [card.centerXAnchor constraintEqualToAnchor:self.overlay.centerXAnchor], [card.centerYAnchor constraintEqualToAnchor:self.overlay.centerYAnchor constant:-8]
    ]];
    self.details = [NSPopover new]; self.details.behavior = NSPopoverBehaviorTransient;
    auto detailController = [NSViewController new]; detailController.view = [[PanelSurface alloc] initWithFrame:NSMakeRect(0, 0, 440, 446)];
    NSView* panel = detailController.view;
    auto heading = label(@"Connection", 17, NSFontWeightSemibold); heading.frame = NSMakeRect(24, 403, 392, 23);
    self.graphConnection = label(@"Connected over USB", 12); self.graphConnection.textColor = NSColor.secondaryLabelColor;
    self.graphConnection.toolTip = @"USB speed depends on the cable, port, and Deck USB setup. USB 2 limits the bandwidth available for higher resolutions and frame rates.";
    self.graphConnection.frame = NSMakeRect(24, 381, 392, 18);
    auto rateCaption = label(@"Transfer rate", 12); rateCaption.textColor = NSColor.secondaryLabelColor; rateCaption.frame = NSMakeRect(24, 345, 392, 18);
    self.liveRate = label(@"—", 42, NSFontWeightMedium); self.liveRate.font = [NSFont monospacedDigitSystemFontOfSize:42 weight:NSFontWeightMedium];
    self.liveRate.frame = NSMakeRect(22, 293, 155, 52);
    auto units = label(@"MB/s", 14); units.textColor = NSColor.secondaryLabelColor; units.frame = NSMakeRect(177, 303, 70, 22);
    auto liveBadge = label(@"● Live", 11, NSFontWeightMedium); liveBadge.textColor = NSColor.systemGreenColor; liveBadge.frame = NSMakeRect(370, 307, 50, 18);
    self.graph = [[BandwidthGraph alloc] initWithFrame:NSMakeRect(24, 144, 392, 145)]; self.graph.windowSeconds = 30; self.graph.timeLabel = @"30 seconds ago";
    self.liveFrames = label(@"—", 20, NSFontWeightMedium); self.liveRTT = label(@"—", 20, NSFontWeightMedium); self.liveAudio = label(@"—", 20, NSFontWeightMedium);
    NSArray<NSTextField*>* values = @[self.liveFrames, self.liveRTT, self.liveAudio];
    NSArray<NSString*>* captions = @[@"Frame rate", @"USB round trip", @"Audio buffer"];
    for (unsigned i = 0; i < 3; ++i) {
        CGFloat x = 24 + i * 136;
        auto caption = label(captions[i], 11); caption.textColor = NSColor.secondaryLabelColor; caption.frame = NSMakeRect(x, 113, 130, 18);
        values[i].font = [NSFont monospacedDigitSystemFontOfSize:20 weight:NSFontWeightMedium]; values[i].frame = NSMakeRect(x, 83, 130, 28);
        [panel addSubview:caption]; [panel addSubview:values[i]];
    }
    self.graphNote = label(@"Audio waiting", 11); self.graphNote.textColor = NSColor.secondaryLabelColor; self.graphNote.frame = NSMakeRect(24, 49, 392, 18);
    self.cableResult = label(@"Cable not tested", 11); self.cableResult.textColor = NSColor.secondaryLabelColor; self.cableResult.frame = NSMakeRect(24, 25, 392, 18);
    for (NSView* view in @[heading, self.graphConnection, rateCaption, self.liveRate, units, liveBadge, self.graph, self.graphNote, self.cableResult]) [panel addSubview:view];
    // Add a separate local-display measurement without compressing the graph.
    for (NSView* item in panel.subviews) { NSRect frame = item.frame; frame.origin.y += 32; item.frame = frame; }
    [panel setFrameSize:NSMakeSize(440, 478)];
    self.displayTiming = label(@"Mac receive → display  —", 12);
    self.displayTiming.textColor = NSColor.secondaryLabelColor; self.displayTiming.frame = NSMakeRect(24, 20, 392, 20);
    self.displayTiming.toolTip = @"Time from a complete frame reaching the Mac to its presentation. Excludes Deck capture and USB transfer; not total game input latency.";
    [panel addSubview:self.displayTiming];
    self.details.contentViewController = detailController;
    NSMenu* bar = [NSMenu new]; NSMenuItem* appItem = [NSMenuItem new]; [bar addItem:appItem];
    NSMenu* menu = [NSMenu new]; appItem.submenu = menu;
    [menu addItemWithTitle:@"Display Settings…" action:@selector(showDisplay:) keyEquivalent:@","].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit DeckUSB" action:@selector(terminate:) keyEquivalent:@"q"];
    auto playbackItem = [[NSMenuItem alloc] initWithTitle:@"Playback" action:nil keyEquivalent:@""];
    auto playback = [[NSMenu alloc] initWithTitle:@"Playback"]; playbackItem.submenu = playback; [bar addItem:playbackItem];
    [playback addItemWithTitle:@"Test Cable" action:@selector(beginTest:) keyEquivalent:@"t"].target = self;
    [playback addItemWithTitle:@"Mute Audio" action:@selector(muteAudio:) keyEquivalent:@""].target = self;
    auto pointer = [playback addItemWithTitle:@"Capture or Release Pointer" action:@selector(capturePointer:) keyEquivalent:@"m"];
    pointer.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift; pointer.target = self;
    [playback addItemWithTitle:@"Enter Full Screen" action:@selector(fullScreen:) keyEquivalent:@"f"].target = self;
    [playback addItemWithTitle:@"Connection Details" action:@selector(showDetails:) keyEquivalent:@"i"].target = self;
    NSApp.mainMenu = bar;
    [self waitingCard]; [self.window center];
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    if (!demo) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self connectDeck]; });
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer* timer) { (void)timer; [self tick]; }];
}
@end
