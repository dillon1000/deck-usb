#pragma once
#include "protocol.hpp"
#include <cmath>

namespace deckusb {
// Caller supplies synchronization. Keep 60 ms only as an emergency ceiling;
// normally steer toward 20 ms with continuous stereo resampling. A gap adds
// 5 ms of safety (up to 40 ms); each 30 stable seconds removes 1 ms of margin.
class PcmBuffer {
    static constexpr size_t capacity = audioRate * 60 / 1000;
    std::array<int16_t, capacity * audioChannels> data{};
    size_t head = 0, count = 0;
    bool primed = false;
    double phase = 0, speed = 1, filteredError = 0, stableSeconds = 0;
    double minimumMs, targetMs;
public:
    uint64_t underruns = 0, trims = 0;
    // The minimum is a calibration input, not a lower hard-coded queue limit.
    explicit PcmBuffer(double minimum = 20) : minimumMs(minimum), targetMs(minimum) {
        if (!std::isfinite(minimum) || minimum < 10 || minimum > 40)
            throw std::runtime_error("Audio target must be between 10 and 40 ms");
    }
    size_t size() const { return count * audioChannels; }
    double targetMilliseconds() const { return targetMs; }
    double correctionPPM() const { return (speed - 1) * 1e6; }
    void push(const AudioPacket& a) {
        if (count + audioFrames > capacity) {
            size_t keep = size_t(targetMs * audioRate / 1000) - audioFrames;
            head = (head + count - keep) % capacity; count = keep;
            phase = filteredError = 0; speed = 1; ++trims;
        }
        for (size_t i = 0; i < audioFrames; ++i) {
            for (size_t ch = 0; ch < audioChannels; ++ch)
                data[((head + count) % capacity) * audioChannels + ch] = a.samples[i * audioChannels + ch];
            ++count;
        }
    }
    void pop(int16_t* out, size_t samples) {
        std::fill_n(out, samples, 0);
        if (samples % audioChannels) return;
        size_t frames = samples / audioChannels;
        if (!frames) return;
        if (!primed && count >= size_t(targetMs * audioRate / 1000)) primed = true;
        if (!primed) return;
        double seconds = double(frames) / audioRate;
        // Estimate midpoint occupancy and smooth packet/callback jitter over
        // half a second. Limit speed changes to 0.5%; never drop individual
        // samples for normal clock drift. Both channels use the same phase.
        // ponytail: linear interpolation limits CPU cost; use a band-limited
        // resampler if high-frequency attenuation becomes audible.
        double error = (double(count) - double(frames) / 2) * 1000 / audioRate - targetMs;
        filteredError += (1 - std::exp(-seconds / 0.5)) * (error - filteredError);
        double desired = 1 + std::clamp(filteredError * 0.001, -0.005, 0.005);
        speed += (1 - std::exp(-seconds / 0.05)) * (desired - speed);
        size_t written = 0;
        for (; written < frames && count >= 2; ++written) {
            for (size_t ch = 0; ch < audioChannels; ++ch) {
                double a = data[head * audioChannels + ch];
                double b = data[((head + 1) % capacity) * audioChannels + ch];
                out[written * audioChannels + ch] = int16_t(std::lround(a + (b - a) * phase));
            }
            phase += speed;
            size_t consumed = size_t(phase);
            head = (head + consumed) % capacity; count -= consumed; phase -= consumed;
        }
        if (written < frames) {
            primed = false; count = 0; phase = filteredError = stableSeconds = 0; speed = 1;
            targetMs = std::min(40.0, targetMs + 5); ++underruns;
        } else {
            stableSeconds += seconds;
            if (stableSeconds >= 30) { targetMs = std::max(minimumMs, targetMs - 1); stableSeconds = 0; }
        }
    }
};
}
