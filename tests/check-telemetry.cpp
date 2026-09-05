#include "deck-stats.hpp"
#include <cassert>
#include <iostream>
using namespace deckusb;
int main() {
    auto root = std::filesystem::temp_directory_path() / ("deckusb-stats-" + std::to_string(nowNs()));
    assert(std::filesystem::create_directory(root));
    auto put = [&](const char* name, const char* value) {
        auto path = root / name; std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << value;
    };
    // Different hwmon indices and an unrelated fan must not change selection.
    put("sys/class/hwmon/hwmon8/name", "k10temp"); put("sys/class/hwmon/hwmon8/temp1_input", "52000");
    put("sys/class/hwmon/hwmon3/name", "amdgpu"); put("sys/class/hwmon/hwmon3/temp1_input", "50000");
    put("sys/class/hwmon/hwmon3/device/gpu_busy_percent", "27");
    put("sys/class/hwmon/hwmon7/name", "steamdeck"); put("sys/class/hwmon/hwmon7/fan1_input", "2100");
    put("sys/class/hwmon/hwmon0/name", "unrelated"); put("sys/class/hwmon/hwmon0/fan1_input", "9000");
    put("sys/class/power_supply/BAT1/type", "Battery"); put("sys/class/power_supply/BAT1/capacity", "83");
    put("sys/class/power_supply/BAT1/status", "Charging");
    put("proc/stat", "cpu 100 0 100 800 0 0 0 0 50 0\n");
    put("proc/meminfo", "MemTotal: 16384000 kB\nMemFree: 100 kB\nMemAvailable: 4096000 kB\n");
    DeckSampler sampler(root);
    assert(!(sampler.sample().fields & cpuLoad)); // A percentage needs two samples.
    put("proc/stat", "cpu 150 0 100 850 0 0 0 0 999 0\n");
    auto s = sampler.sample();
    assert(s.fields == 255 && s.cpuPermille == 500 && s.gpuPermille == 270);
    assert(s.ramTotalMiB == 16000 && s.ramUsedMiB == 12000);
    assert(s.cpuMilliC == 52000 && s.gpuMilliC == 50000 && s.fanRpm == 2100);
    assert(s.batteryPercent == 83 && s.batteryState == charging);
    StatsAck ack; ack.pong.nonce = 10; ack.stats = s; ack.pong.sendNs = nowNs();
    validate(ack, sizeof(ack), 20); validate(ack, sizeof(Pong), 20);
    auto rejected = [&](StatsAck value, size_t bytes) {
        try { validate(value, bytes, 20); } catch (const std::exception&) { return true; }
        return false;
    };
    assert(rejected(ack, 0) && rejected(ack, sizeof(ack)-1) && rejected(ack, sizeof(Pong)+1));
    auto bad = ack; bad.stats.cpuPermille = 1001; assert(rejected(bad, sizeof(bad)));
    bad = ack; bad.stats.ramUsedMiB = 20000; assert(rejected(bad, sizeof(bad)));
    bad = ack; bad.stats.batteryState = 90; assert(rejected(bad, sizeof(bad)));
    bad = ack; bad.stats.fields |= 256; assert(rejected(bad, sizeof(bad)));
    bad = ack; bad.pong.nonce = 21; assert(rejected(bad, sizeof(Pong)));
    StatsCache cache; cache.accept(s, 100); cache.accept(s, 2000000000ULL);
    assert(cache.current(2999999999ULL).fields == 255 && !cache.current(3000000100ULL).fields);
    assert(!cache.current(99).fields);
    Command pingRequest; pingRequest.code = telemetryRequest; assert(valid(pingRequest));
    // Missing, out-of-range, and malformed sensors clear validity; zero fan RPM
    // is a real stopped fan, and a reset CPU counter cannot produce a spike.
    put("proc/stat", "cpu 1 0 0 1 0 0 0 0\n");
    put("sys/class/hwmon/hwmon3/device/gpu_busy_percent", "101");
    put("sys/class/hwmon/hwmon7/fan1_input", "0");
    put("sys/class/power_supply/BAT1/capacity", "83garbage");
    std::filesystem::remove(root / "sys/class/hwmon/hwmon8/temp1_input");
    s = sampler.sample();
    assert(!(s.fields & (cpuLoad | gpuLoad | cpuTemperature | batteryLevel)));
    assert((s.fields & fanSpeed) && s.fanRpm == 0);
    DeckSampler absent(root / "absent"); assert(!absent.sample().fields);
    std::filesystem::remove_all(root);
    std::cout << "Deck telemetry: CPU deltas, sensors, missing values, wire bounds, legacy replies, and stale samples: PASS\n";
}
