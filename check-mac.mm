#include "mac-keys.hpp"
#include <cassert>
using namespace deckusb;
int main() { @autoreleasepool {
    std::vector<Command> sent;
    auto event = [&](NSEventType type, unsigned code, NSUInteger flags, bool repeat = false) {
        auto e = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags
            timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@""
            isARepeat:repeat keyCode:code];
        forwardMacKey(e, type == NSEventTypeKeyDown, [&](Command c) { assert(valid(c)); sent.push_back(c); });
    };
    // Real NSEvent objects exercise the property guard that previously aborted.
    for (auto [mac, flag, side] : {std::array<NSUInteger, 3>{56, NSEventModifierFlagShift, NX_DEVICELSHIFTKEYMASK},
        {60, NSEventModifierFlagShift, NX_DEVICERSHIFTKEYMASK},
        {59, NSEventModifierFlagControl, NX_DEVICELCTLKEYMASK}, {62, NSEventModifierFlagControl, NX_DEVICERCTLKEYMASK},
        {58, NSEventModifierFlagOption, NX_DEVICELALTKEYMASK}, {61, NSEventModifierFlagOption, NX_DEVICERALTKEYMASK},
        {55, NSEventModifierFlagCommand, NX_DEVICELCMDKEYMASK}, {54, NSEventModifierFlagCommand, NX_DEVICERCMDKEYMASK}}) {
        sent.clear();
        event(NSEventTypeFlagsChanged, mac, flag | side);
        event(NSEventTypeKeyDown, 8, flag | side); // Physical C with a held modifier.
        event(NSEventTypeKeyDown, 8, flag | side, true);
        event(NSEventTypeKeyUp, 8, flag | side);
        event(NSEventTypeFlagsChanged, mac, 0);
        assert(sent.size() == 4 && sent[0].code == linuxKey(mac) && sent[0].value == 1);
        assert(sent[1].code == 46 && sent[1].value == 1 && sent[2].value == 0);
        assert(sent[3].code == linuxKey(mac) && sent[3].value == 0);
        sent.clear(); event(NSEventTypeFlagsChanged, mac, flag);
        assert(sent.size() == 1 && sent[0].value == 1);
    }
    sent.clear();
    event(NSEventTypeFlagsChanged, 56, NSEventModifierFlagShift | NX_DEVICERSHIFTKEYMASK);
    assert(sent.size() == 1 && sent[0].code == 42 && sent[0].value == 0);
    sent.clear(); event(NSEventTypeFlagsChanged, 57, NSEventModifierFlagCapsLock);
    assert(sent.size() == 2 && sent[0].code == 58 && sent[0].value == 1 && sent[1].value == 0);
    puts("Mac modifier event checks passed");
} }
