#pragma once
#include "deck-io.hpp"
#include <filesystem>
#include <linux/input.h>
#include <linux/uinput.h>
#include <mutex>
#include <sys/ioctl.h>
#include <thread>

// Only this local USB session can inject input. The watchdog and focus-release
// command release each pressed key. Closing the process destroys the device.
class Input {
    int fd, absoluteFd;
    std::mutex mutex;
    std::array<bool, KEY_MAX + 1> pressed{}, pressedAbsolute{};
    bool absoluteMode = false;
    void event(uint16_t type, uint16_t code, int32_t value, bool absoluteDevice = false) {
        input_event e{}; e.type = type; e.code = code; e.value = value;
        require(write(absoluteDevice ? absoluteFd : fd, &e, sizeof(e)) == sizeof(e), "uinput write");
    }
public:
    Input() : fd(openFd("/dev/uinput", O_WRONLY)), absoluteFd(openFd("/dev/uinput", O_WRONLY)) {
        // Linux ignores absolute motion on a device that also advertises relative
        // X/Y. Expose a separate absolute mouse, as USB tablets do.
        for (int type : {EV_KEY, EV_REL, EV_REP}) require(ioctl(fd, UI_SET_EVBIT, type) == 0, "uinput event type");
        for (int type : {EV_KEY, EV_ABS}) require(ioctl(absoluteFd, UI_SET_EVBIT, type) == 0, "absolute event type");
        require(ioctl(absoluteFd, UI_SET_PROPBIT, INPUT_PROP_POINTER) == 0, "absolute pointer property");
        // Do not advertise touch/pen/gamepad buttons: libinput would classify
        // this keyboard and mouse as an unrelated device and ignore motion.
        for (int key = 1; key <= 248; ++key) require(ioctl(fd, UI_SET_KEYBIT, key) == 0, "uinput key");
        for (int key = BTN_LEFT; key <= BTN_TASK; ++key) {
            require(ioctl(fd, UI_SET_KEYBIT, key) == 0, "uinput button");
            require(ioctl(absoluteFd, UI_SET_KEYBIT, key) == 0, "absolute button");
        }
        for (int rel : {REL_X, REL_Y, REL_WHEEL, REL_HWHEEL}) require(ioctl(fd, UI_SET_RELBIT, rel) == 0, "uinput relative axis");
        for (int axis : {ABS_X, ABS_Y}) {
            require(ioctl(absoluteFd, UI_SET_ABSBIT, axis) == 0, "uinput absolute axis");
            uinput_abs_setup a{}; a.code = axis; a.absinfo.maximum = 65535;
            require(ioctl(absoluteFd, UI_ABS_SETUP, &a) == 0, "uinput absolute range");
        }
        uinput_setup setup{};
        setup.id.bustype = BUS_USB; setup.id.vendor = vendor; setup.id.product = product;
        strcpy(setup.name, "DeckUSB keyboard and pointer");
        require(ioctl(fd, UI_DEV_SETUP, &setup) == 0 && ioctl(fd, UI_DEV_CREATE) == 0, "uinput create");
        strcpy(setup.name, "DeckUSB absolute pointer");
        require(ioctl(absoluteFd, UI_DEV_SETUP, &setup) == 0 && ioctl(absoluteFd, UI_DEV_CREATE) == 0, "absolute pointer create");
    }
    // Root-only hardware check: grab only these newly created test devices so
    // test presses never reach the desktop. Verify kernel state, not just bytes.
    void selfCheck() {
        auto reader = [](int device) {
            char name[128]{};
            require(ioctl(device, UI_GET_SYSNAME(sizeof(name)), name) >= 0, "uinput sysname");
            for (const auto& entry : std::filesystem::directory_iterator(std::string("/sys/devices/virtual/input/") + name)) {
                auto filename = entry.path().filename().string();
                if (!filename.starts_with("event")) continue;
                int result = openFd("/dev/input/" + filename, O_RDONLY | O_NONBLOCK);
                require(ioctl(result, EVIOCGRAB, 1) == 0, "Grab test input");
                return result;
            }
            throw std::runtime_error("Test input event node is missing");
        };
        int keyboard = reader(fd), mouse = reader(absoluteFd);
        auto expect = [](int device, std::initializer_list<int> held) {
            std::array<uint8_t, (KEY_MAX + 8) / 8> bits{};
            require(ioctl(device, EVIOCGKEY(sizeof(bits)), bits.data()) >= 0, "Read held keys");
            for (int code = 1; code <= KEY_MAX; ++code) {
                bool expected = std::find(held.begin(), held.end(), code) != held.end();
                if (bool(bits[code / 8] & (1 << (code % 8))) != expected)
                    throw std::runtime_error("Held-key check failed for " + std::to_string(code));
            }
        };
        auto press = [&](int code, int value) { Command c; c.type = key; c.code = code; c.value = value; apply(c); };
        press(KEY_A, 1); press(KEY_W, 1); press(KEY_LEFTSHIFT, 1); press(KEY_RIGHTSHIFT, 1);
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
        expect(keyboard, {KEY_A, KEY_W, KEY_LEFTSHIFT, KEY_RIGHTSHIFT});
        press(KEY_LEFTSHIFT, 0); expect(keyboard, {KEY_A, KEY_W, KEY_RIGHTSHIFT});
        Command move; move.type = absolute; move.x = 1000; move.y = 2000; apply(move);
        press(BTN_LEFT, 1); press(BTN_RIGHT, 1);
        move.x = 30000; move.y = 40000; apply(move);
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
        expect(mouse, {BTN_LEFT, BTN_RIGHT});
        input_absinfo position{};
        require(ioctl(mouse, EVIOCGABS(ABS_X), &position) >= 0 && position.value == move.x, "Held drag position");
        press(BTN_LEFT, 0); expect(mouse, {BTN_RIGHT});
        releaseAll(); expect(keyboard, {}); expect(mouse, {});
        unsigned repeat[2]{};
        require(ioctl(keyboard, EVIOCGREP, repeat) >= 0 && repeat[0] && repeat[1], "Key repeat settings");
        close(keyboard); close(mouse);
        puts("Input kernel check: multi-key, held keys, both Shift keys, right click, held drag, release-all, and repeat: PASS");
    }
    void releaseAll() {
        std::lock_guard lock(mutex);
        for (unsigned i = 1; i < pressed.size(); ++i) if (pressed[i]) {
            event(EV_KEY, i, 0, pressedAbsolute[i]); pressed[i] = false;
        }
        event(EV_SYN, SYN_REPORT, 0);
        event(EV_SYN, SYN_REPORT, 0, true);
    }
    void apply(const Command& c) {
        if (!valid(c)) throw std::runtime_error("Invalid USB input command");
        if (c.type == release) { releaseAll(); return; }
        if (c.type == ping) return;
        std::lock_guard lock(mutex);
        if (c.type == key) {
            if (c.value) pressedAbsolute[c.code] = c.code >= BTN_LEFT && absoluteMode;
            event(EV_KEY, c.code, c.value, pressedAbsolute[c.code]); pressed[c.code] = c.value;
        }
        if (c.type == relative) { absoluteMode = false; event(EV_REL, REL_X, c.x); event(EV_REL, REL_Y, c.y); }
        if (c.type == absolute) { absoluteMode = true; event(EV_ABS, ABS_X, c.x, true); event(EV_ABS, ABS_Y, c.y, true); }
        if (c.type == wheel) { event(EV_REL, REL_HWHEEL, c.x); event(EV_REL, REL_WHEEL, c.y); }
        event(EV_SYN, SYN_REPORT, 0);
        event(EV_SYN, SYN_REPORT, 0, true);
    }
};
