#pragma once
#include "protocol.hpp"

namespace deckusb {
// Opt in through ping.code, which older senders ignore. Old viewers still get
// the original 32-byte Pong. This tag identifies this fixed telemetry layout.
constexpr int32_t telemetryRequest = 0x31544153;
enum StatsField : uint32_t {
    cpuLoad = 1, gpuLoad = 2, cpuTemperature = 4, gpuTemperature = 8,
    memoryUse = 16, batteryLevel = 32, fanSpeed = 64, batteryStatus = 128
};
enum BatteryState : uint32_t { batteryUnknown, charging, discharging, batteryFull, notCharging };
struct DeckStats {
    uint64_t sampledNs = 0; // Deck monotonic clock; use only to detect new samples.
    uint32_t fields = 0, cpuPermille = 0, gpuPermille = 0;
    int32_t cpuMilliC = 0, gpuMilliC = 0;
    uint32_t ramUsedMiB = 0, ramTotalMiB = 0, batteryPercent = 0;
    uint32_t batteryState = batteryUnknown, fanRpm = 0;
};
struct StatsAck { Pong pong; DeckStats stats; };
static_assert(sizeof(DeckStats) == 48 && sizeof(StatsAck) == 80);

// A single bulk read accepts either complete record. Never try to fill an
// 80-byte buffer with multiple 32-byte legacy replies or shift their framing.
inline void validate(const StatsAck& a, size_t bytes, uint64_t receivedNs) {
    if ((bytes != sizeof(Pong) && bytes != sizeof(StatsAck)) ||
        a.pong.magicValue != magic || a.pong.versionValue != version || a.pong.nonce > receivedNs)
        throw std::runtime_error("Invalid USB acknowledgment");
    if (bytes == sizeof(Pong)) return;
    const auto& s = a.stats;
    if ((s.fields & ~255u) || s.sampledNs > a.pong.sendNs ||
        ((s.fields & cpuLoad) && s.cpuPermille > 1000) ||
        ((s.fields & gpuLoad) && s.gpuPermille > 1000) ||
        ((s.fields & cpuTemperature) && (s.cpuMilliC < -50000 || s.cpuMilliC > 200000)) ||
        ((s.fields & gpuTemperature) && (s.gpuMilliC < -50000 || s.gpuMilliC > 200000)) ||
        ((s.fields & memoryUse) && (!s.ramTotalMiB || s.ramTotalMiB > 1048576 || s.ramUsedMiB > s.ramTotalMiB)) ||
        ((s.fields & batteryLevel) && s.batteryPercent > 100) ||
        ((s.fields & batteryStatus) && s.batteryState > notCharging) ||
        ((s.fields & fanSpeed) && s.fanRpm > 100000))
        throw std::runtime_error("Invalid Deck sensor readings");
}

// Cache age uses the Mac clock. Repeated heartbeats must not make a stopped
// sampler look fresh. A three-second grace allows two missed one-second polls.
struct StatsCache {
    DeckStats value;
    uint64_t receivedNs = 0;
    void accept(const DeckStats& next, uint64_t now) {
        if (next.sampledNs != value.sampledNs) { value = next; receivedNs = now; }
    }
    DeckStats current(uint64_t now) const {
        return receivedNs && now >= receivedNs && now - receivedNs < 3000000000ULL ? value : DeckStats{};
    }
};
}
