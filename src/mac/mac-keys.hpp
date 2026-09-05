#pragma once
#import <Cocoa/Cocoa.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#include "protocol.hpp"

namespace deckusb {
// Translate AppKit keyboard events into physical evdev transitions. The caller
// owns focus/USB lifetime and sends commands in order. Repeats come from Linux.
// isARepeat is invalid on flagsChanged: querying it prevents ALL modifiers from
// reaching USB. Keep this type check ahead of any key-only property access.
template<class Send> void forwardMacKey(NSEvent* event, bool down, Send send) {
    auto type = event.type;
    if (type != NSEventTypeFlagsChanged && type != NSEventTypeKeyDown && type != NSEventTypeKeyUp) return;
    if (type == NSEventTypeKeyDown && event.isARepeat) return;
    int code = linuxKey(event.keyCode);
    if (!code) return;
    Command c; c.type = key; c.code = code;
    if (type == NSEventTypeFlagsChanged) {
        NSUInteger side = 0, pair = 0, aggregate = 0;
        switch (event.keyCode) {
            case 56: side = NX_DEVICELSHIFTKEYMASK; break;
            case 60: side = NX_DEVICERSHIFTKEYMASK; break;
            case 59: side = NX_DEVICELCTLKEYMASK; break;
            case 62: side = NX_DEVICERCTLKEYMASK; break;
            case 58: side = NX_DEVICELALTKEYMASK; break;
            case 61: side = NX_DEVICERALTKEYMASK; break;
            case 55: side = NX_DEVICELCMDKEYMASK; break;
            case 54: side = NX_DEVICERCMDKEYMASK; break;
            case 57: c.value = 1; send(c); c.value = 0; send(c); return;
            default: return;
        }
        if (event.keyCode == 56 || event.keyCode == 60) { pair = NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK; aggregate = NSEventModifierFlagShift; }
        if (event.keyCode == 59 || event.keyCode == 62) { pair = NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK; aggregate = NSEventModifierFlagControl; }
        if (event.keyCode == 58 || event.keyCode == 61) { pair = NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK; aggregate = NSEventModifierFlagOption; }
        if (event.keyCode == 55 || event.keyCode == 54) { pair = NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK; aggregate = NSEventModifierFlagCommand; }
        // Device bits distinguish releasing one side while the other stays held.
        // Some event sources supply only aggregate flags; accept those as well.
        down = event.modifierFlags & (event.modifierFlags & pair ? side : aggregate);
    }
    c.value = down; send(c);
}
}
