#pragma once
#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace deckusb {
// Private prototype identity; these test IDs are not a production allocation.
constexpr uint16_t vendor = 0x1209, product = 0x0001;
constexpr uint32_t magic = 0x314b4344, version = 4;
constexpr unsigned chunk = 256 * 1024; // One bounded USB request, not a frame queue.
constexpr uint32_t nv12 = 1, bgra = 2, h264 = 3;
// Independent H.264 access units may vary in size; bound them before allocation.
constexpr uint32_t maxEncodedBytes = 4 * 1024 * 1024;
static_assert(std::endian::native == std::endian::little);

// All fields are little endian. Header precedes one raw frame or H.264 access unit.
// Times are monotonic Deck times; never subtract them from a Mac clock directly.
struct Header {
    uint32_t magicValue = magic, versionValue = version, format = nv12;
    uint32_t width = 1280, height = 800, bytes = 0;
    uint64_t sequence = 0, captureDoneNs = 0, sendNs = 0;
    uint32_t dropped = 0, reserved[3] = {};
};
// Fixed 5 ms stereo packets keep audio independent of video frame size. PCM is
// signed 16-bit little endian at 48 kHz: 192 kB/s before packet headers.
constexpr unsigned audioRate = 48000, audioFrames = 240, audioChannels = 2;
struct AudioPacket {
    uint32_t magicValue = magic, versionValue = version;
    uint64_t sequence = 0;
    std::array<int16_t, audioFrames * audioChannels> samples{};
};
static_assert(sizeof(AudioPacket) == 976);
inline void validate(const AudioPacket& a) {
    if (a.magicValue != magic || a.versionValue != version)
        throw std::runtime_error("Invalid audio packet");
}
enum Type : uint32_t { ping = 0, key = 1, relative = 2, absolute = 3, wheel = 4, release = 5, restart = 6, configure = 7, measure = 8 };
// Key codes are Linux evdev codes. Absolute coordinates are in [0, 65535].
// Ping is also a heartbeat. Silence for one second releases all held inputs.
struct Command {
    uint32_t magicValue = magic, type = ping;
    int32_t code = 0, value = 0, x = 0, y = 0;
    uint64_t nonce = 0;
};
struct Pong {
    uint32_t magicValue = magic, versionValue = version;
    uint64_t nonce = 0, receiveNs = 0, sendNs = 0;
};
static_assert(sizeof(Header) == 64 && sizeof(Command) == 32 && sizeof(Pong) == 32);

inline uint64_t nowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
// Bound dimensions before multiplication or allocation at the USB trust boundary.
inline uint32_t frameBytes(uint32_t width, uint32_t height, uint32_t format) {
    if (!width || !height || width > 1920 || height > 1200 || width % 2 || height % 2)
        throw std::runtime_error("Frame dimensions must be even and at most 1920 x 1200");
    if (format != nv12 && format != bgra) throw std::runtime_error("Unknown pixel format");
    return width * height * (format == nv12 ? 3 : 8) / 2;
}
inline void validate(const Header& h) {
    frameBytes(h.width, h.height, nv12); // Validate dimensions for every format.
    bool sizeOK = h.format == h264 ? h.bytes > 0 && h.bytes <= maxEncodedBytes :
        h.bytes == frameBytes(h.width, h.height, h.format);
    if (h.magicValue != magic || h.versionValue != version || !sizeOK)
        throw std::runtime_error("Invalid frame header; disconnecting");
}
inline bool valid(const Command& c) {
    if (c.magicValue != magic || c.type > measure) return false;
    if (c.type == measure) return c.value == 0 || c.value == 1;
    if (c.type == configure) return c.x >= 2 && c.x <= 1920 && c.x % 2 == 0 &&
        c.y >= 2 && c.y <= 1200 && c.y % 2 == 0 && c.value >= 1 && c.value <= 240 &&
        (c.code == nv12 || c.code == bgra || c.code == h264);
    if (c.type == key) return ((c.code >= 1 && c.code <= 248) || (c.code >= 272 && c.code <= 279))
        && (c.value == 0 || c.value == 1);
    if (c.type == absolute) return c.x >= 0 && c.x <= 65535 && c.y >= 0 && c.y <= 65535;
    if (c.type == relative || c.type == wheel)
        return c.x >= -32767 && c.x <= 32767 && c.y >= -32767 && c.y <= 32767;
    return true;
}
// Merge only adjacent motion commands, never across a button/key transition.
// If a sum exceeds the wire range, retain both commands rather than lose motion.
inline bool combineMotion(Command& previous, const Command& next) {
    if (previous.type != next.type) return false;
    if (next.type == absolute) { previous = next; return true; }
    if (next.type != relative) return false;
    int64_t x = int64_t(previous.x) + next.x, y = int64_t(previous.y) + next.y;
    if (x < -32767 || x > 32767 || y < -32767 || y > 32767) return false;
    previous.x = int32_t(x); previous.y = int32_t(y); return true;
}
// Physical macOS key positions to Linux evdev; zero means unsupported, never key 0.
inline int linuxKey(unsigned mac) {
    constexpr uint16_t keys[] = {
        30,31,32,33,35,34,44,45,46,47,86,48,16,17,18,19,
        21,20,2,3,4,5,7,6,13,10,8,12,9,11,27,24,
        22,26,23,25,28,38,36,40,37,39,43,51,53,49,50,52,
        15,57,41,14,0,1,126,125,42,58,56,29,54,100,97,0,
        0,83,0,55,0,78,0,69,0,0,0,98,96,0,74,0,
        0,117,82,79,80,81,75,76,77,71,0,72,73,0,0,0,
        63,64,65,61,66,67,0,87,0,99,0,70,0,68,0,88,
        0,119,110,102,104,111,62,107,60,109,59,105,106,108,103
    };
    return mac < sizeof(keys) / sizeof(*keys) ? keys[mac] : 0;
}
// UI rates use actual elapsed time. Counter resets start a new interval instead
// of turning unsigned subtraction into a huge spike after reconnecting.
struct TransferMeter {
    uint64_t time = 0, bytes = 0, frames = 0;
    double megabytesPerSecond = 0, framesPerSecond = 0;
    bool update(uint64_t nextTime, uint64_t nextBytes, uint64_t nextFrames) {
        if (!time || nextTime <= time || nextBytes < bytes || nextFrames < frames) {
            time = nextTime; bytes = nextBytes; frames = nextFrames;
            megabytesPerSecond = framesPerSecond = 0; return false;
        }
        double seconds = (nextTime - time) / 1e9;
        megabytesPerSecond = (nextBytes - bytes) / seconds / 1e6;
        framesPerSecond = (nextFrames - frames) / seconds;
        time = nextTime; bytes = nextBytes; frames = nextFrames; return true;
    }
};
struct VideoSetting { unsigned width, height, fps, format = nv12; };
// Reserve 5% of measured payload capacity for timing variation and audio.
// Favor 60 fps before resolution, then fall back to 30 fps on slower links.
inline VideoSetting recommend(double megabytes, bool lowLatency = false) {
    // The optional latency preset trades detail for smaller frames and tries
    // 90 fps first. Keep the same measured 5% margin and audio allowance.
    if (lowLatency) {
        for (unsigned fps : {90u, 60u, 30u})
            if ((frameBytes(640, 400, nv12) * double(fps) / 1e6 + 0.2) <= megabytes * 0.95)
                return {640, 400, fps};
        return {640, 400, 30};
    }
    for (unsigned fps : {60u, 30u}) for (unsigned width : {1280u, 960u, 800u, 640u})
        if ((frameBytes(width, width * 5 / 8, nv12) * double(fps) / 1e6 + 0.2) <= megabytes * 0.95)
            return {width, width * 5 / 8, fps};
    return {640, 400, 30};
}
}
