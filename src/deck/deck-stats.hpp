#pragma once
#include "telemetry.hpp"
#include <filesystem>
#include <fstream>
#include <numeric>
#include <optional>
#include <sstream>
#include <string>

namespace deckusb {
// Read kernel counters directly, without subprocesses, GPU commands, or writes.
// Discover named sensors once; absent or unreadable readings remain unavailable.
// The root parameter permits a synthetic /proc and /sys tree in the check.
class DeckSampler {
    using Path = std::filesystem::path;
    Path root, cpuTemp, gpuTemp, gpuBusy, fan, battery;
    uint64_t previousTotal = 0, previousIdle = 0;
    bool haveCPU = false;
    static std::string text(const Path& path) {
        std::ifstream file(path); std::string value; std::getline(file, value); return value;
    }
    static std::optional<int64_t> number(const Path& path, int64_t low, int64_t high) {
        if (path.empty()) return {};
        std::istringstream input(text(path)); int64_t value; std::string extra;
        if (!(input >> value) || (input >> extra) || value < low || value > high) return {};
        return value;
    }
    static std::vector<Path> directories(const Path& path) {
        std::vector<Path> paths; std::error_code error;
        std::filesystem::directory_iterator entry(path, error), end;
        for (; !error && entry != end; entry.increment(error)) paths.push_back(entry->path());
        return paths;
    }
public:
    explicit DeckSampler(Path filesystemRoot = "/") : root(std::move(filesystemRoot)) {
        for (const auto& path : directories(root / "sys/class/hwmon")) {
            auto name = text(path / "name");
            if (name == "k10temp") cpuTemp = path / "temp1_input";
            if (name == "amdgpu") { gpuTemp = path / "temp1_input"; gpuBusy = path / "device/gpu_busy_percent"; }
            if (name == "jupiter" || name == "steamdeck" || name == "steamdeck_hwmon") fan = path / "fan1_input";
        }
        for (const auto& path : directories(root / "sys/class/power_supply"))
            if (text(path / "type") == "Battery" && text(path / "scope") != "Device") {
                battery = path; break;
            }
    }
    DeckStats sample() {
        DeckStats s; s.sampledNs = nowNs();
        std::ifstream cpu(root / "proc/stat"); std::string label; std::array<uint64_t, 8> ticks{};
        bool cpuOK = bool(cpu >> label) && label == "cpu";
        for (auto& tick : ticks) cpuOK = bool(cpu >> tick) && cpuOK;
        if (cpuOK) {
            // Guest time is already in user/nice. Sum only the first eight
            // fields; idle and I/O wait are not CPU execution time.
            uint64_t total = std::accumulate(ticks.begin(), ticks.end(), uint64_t(0));
            uint64_t idle = ticks[3] + ticks[4];
            if (haveCPU && total > previousTotal && idle >= previousIdle && idle - previousIdle <= total - previousTotal) {
                s.cpuPermille = uint32_t(1000.0 * (1.0 - double(idle - previousIdle) / double(total - previousTotal)));
                s.fields |= cpuLoad;
            }
            previousTotal = total; previousIdle = idle;
        }
        haveCPU = cpuOK;
        std::ifstream mem(root / "proc/meminfo"); std::string line;
        uint64_t totalKiB = 0; std::optional<uint64_t> availableKiB;
        while (std::getline(mem, line)) {
            std::istringstream input(line); std::string key, unit; uint64_t value;
            if (!(input >> key >> value >> unit) || unit != "kB") continue;
            if (key == "MemTotal:") totalKiB = value;
            if (key == "MemAvailable:") availableKiB = value;
        }
        // Available memory includes reclaimable cache. Reporting total minus
        // free memory would make useful disk cache look like application load.
        if (totalKiB >= 1024 && totalKiB <= 1073741824 && availableKiB && *availableKiB <= totalKiB) {
            s.ramTotalMiB = uint32_t(totalKiB / 1024);
            s.ramUsedMiB = uint32_t((totalKiB - *availableKiB) / 1024); s.fields |= memoryUse;
        }
        if (auto v = number(cpuTemp, -50000, 200000)) { s.cpuMilliC = int32_t(*v); s.fields |= cpuTemperature; }
        if (auto v = number(gpuTemp, -50000, 200000)) { s.gpuMilliC = int32_t(*v); s.fields |= gpuTemperature; }
        if (auto v = number(gpuBusy, 0, 100)) { s.gpuPermille = uint32_t(*v * 10); s.fields |= gpuLoad; }
        if (auto v = number(fan, 0, 100000)) { s.fanRpm = uint32_t(*v); s.fields |= fanSpeed; }
        if (!battery.empty()) {
            if (auto v = number(battery / "capacity", 0, 100)) { s.batteryPercent = uint32_t(*v); s.fields |= batteryLevel; }
            auto status = text(battery / "status");
            if (status == "Charging") s.batteryState = charging;
            else if (status == "Discharging") s.batteryState = discharging;
            else if (status == "Full") s.batteryState = batteryFull;
            else if (status == "Not charging") s.batteryState = notCharging;
            if (s.batteryState != batteryUnknown) s.fields |= batteryStatus;
        }
        return s;
    }
};
}
