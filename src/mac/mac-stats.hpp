#pragma once
#import <Cocoa/Cocoa.h>
#include "telemetry.hpp"

namespace deckusb {
// Compact units keep all sensors in the footer; the tooltip names each metric
// and its unit. Unavailable readings use a dash, including a stale whole sample.
inline NSString* statsPercent(const DeckStats& s, uint32_t field, uint32_t permille) {
    return s.fields & field ? [NSString stringWithFormat:@"%.0f%%", permille / 10.0] : @"—";
}
inline NSString* statsTemperature(const DeckStats& s, uint32_t field, int32_t milliC) {
    return s.fields & field ? [NSString stringWithFormat:@"%.0f°", milliC / 1000.0] : @"—°";
}
inline NSString* deckStatsSummary(const DeckStats& s) {
    if (!s.sampledNs) return @"Deck stats unavailable";
    NSString* ram = s.fields & memoryUse ? [NSString stringWithFormat:@"%.1fG", s.ramUsedMiB / 1024.0] : @"—";
    NSString* battery = statsPercent(s, batteryLevel, s.batteryPercent * 10);
    NSString* state = !(s.fields & batteryStatus) ? @"" : s.batteryState == charging ? @"↑" : s.batteryState == discharging ? @"↓" : @"";
    NSString* fan = !(s.fields & fanSpeed) ? @"—" : s.fanRpm ? [NSString stringWithFormat:@"%.1fk", s.fanRpm / 1000.0] : @"stopped";
    return [NSString stringWithFormat:@"CPU %@ %@ · GPU %@ %@ · RAM %@ · Bat %@%@ · Fan %@",
        statsPercent(s, cpuLoad, s.cpuPermille), statsTemperature(s, cpuTemperature, s.cpuMilliC),
        statsPercent(s, gpuLoad, s.gpuPermille), statsTemperature(s, gpuTemperature, s.gpuMilliC), ram, battery, state, fan];
}
inline NSString* deckStatsDetails(const DeckStats& s) {
    if (!s.sampledNs) return @"Deck sensor data is unavailable. Connect the Deck and update its DeckUSB sender to enable readings.";
    NSArray<NSString*>* states = @[@"Unknown", @"Charging", @"Discharging", @"Full", @"Not charging"];
    NSString* ram = s.fields & memoryUse ? [NSString stringWithFormat:@"%.1f / %.1f GiB used (available memory excluded)", s.ramUsedMiB / 1024.0, s.ramTotalMiB / 1024.0] : @"Unavailable";
    NSString* fan = s.fields & fanSpeed ? [NSString stringWithFormat:@"%u rpm (%@)", s.fanRpm, s.fanRpm ? @"running" : @"stopped"] : @"Unavailable";
    return [NSString stringWithFormat:@"Steam Deck · sampled once per second over USB\nCPU: %@ of total capacity · %@C\nGPU: %@ busy · %@C\nRAM: %@\nBattery: %@ · %@\nFan: %@\nA dash means the sensor is unavailable.",
        statsPercent(s, cpuLoad, s.cpuPermille), statsTemperature(s, cpuTemperature, s.cpuMilliC),
        statsPercent(s, gpuLoad, s.gpuPermille), statsTemperature(s, gpuTemperature, s.gpuMilliC), ram,
        statsPercent(s, batteryLevel, s.batteryPercent * 10), states[(s.fields & batteryStatus) ? s.batteryState : 0], fan];
}
}
