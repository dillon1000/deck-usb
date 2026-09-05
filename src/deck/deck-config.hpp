#pragma once
#include "deck-io.hpp"
#include <cstdio>

// Root owns /run. Replace bounded data atomically and request a live restart.
// Both user-selected settings and codec-failure recovery use this same path.
static void applyVideoSetting(VideoSetting setting) {
    Command validateSetting; validateSetting.type = configure;
    validateSetting.x = setting.width; validateSetting.y = setting.height;
    validateSetting.value = setting.fps; validateSetting.code = setting.format;
    validateSetting.nonce = setting.quality;
    if (!valid(validateSetting) || !validQuality(setting.quality)) throw std::runtime_error("Invalid video setting");
    std::string path = "/run/deckusb-video.next." + std::to_string(getpid());
    const char* temporary = path.c_str();
    int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
    require(fd >= 0, "Create video settings");
    std::string text = std::to_string(setting.width) + " " + std::to_string(setting.height) + " " +
        std::to_string(setting.fps) + (setting.format == h264 ? " h264 " : setting.format == nv12 ? " nv12 " : " bgra ") +
        std::to_string(setting.quality) + "\n";
    try {
        require(write(fd, text.data(), text.size()) == ssize_t(text.size()), "Write video settings");
        require(rename(temporary, "/run/deckusb-video.conf") == 0, "Apply video settings");
    } catch (...) { close(fd); unlink(temporary); throw; }
    close(fd);
    int control = openFd("/run/deckusb/control", O_WRONLY | O_NONBLOCK);
    require(write(control, "live\n", 5) == 5, "Restart live capture"); close(control);
}
