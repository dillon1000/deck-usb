#pragma once
#include "deck-io.hpp"
#include <cstdio>

// Root owns both fixed configuration paths. Replace bounded data atomically,
// then restart the stream. Never interpret configuration as shell commands.
static void applyConfiguration(const std::string& path, const std::string& text) {
    std::string next = path + ".next." + std::to_string(getpid());
    const char* temporary = next.c_str();
    int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
    require(fd >= 0, "Create Deck settings");
    try {
        require(write(fd, text.data(), text.size()) == ssize_t(text.size()), "Write Deck settings");
        require(rename(temporary, path.c_str()) == 0, "Apply Deck settings");
    } catch (...) { close(fd); unlink(temporary); throw; }
    close(fd);
    int control = openFd("/run/deckusb/control", O_WRONLY | O_NONBLOCK);
    require(write(control, "live\n", 5) == 5, "Restart live capture"); close(control);
}
// User selections and decoder recovery share the same validation and restart.
static void applyVideoSetting(VideoSetting setting) {
    Command command; command.type = configure;
    command.x = setting.width; command.y = setting.height;
    command.value = setting.fps; command.code = setting.format; command.nonce = setting.quality;
    if (!valid(command) || !validQuality(setting.quality)) throw std::runtime_error("Invalid video setting");
    applyConfiguration("/run/deckusb-video.conf", std::to_string(setting.width) + " " + std::to_string(setting.height) + " " +
        std::to_string(setting.fps) + (setting.format == h264 ? " h264 " : setting.format == nv12 ? " nv12 " : " bgra ") +
        std::to_string(setting.quality) + "\n");
}
static void applyWriteSetting(unsigned mode) {
    if (mode > 2) throw std::runtime_error("Invalid USB write mode");
    const char* names[]{"serial\n", "large\n", "async\n"};
    applyConfiguration("/run/deckusb-usb-writes.conf", names[mode]);
}
