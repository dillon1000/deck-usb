#include "audio-buffer.hpp"
#include "protocol.hpp"
#include "frame.hpp"
#include "codec.hpp"
#include <cassert>
#include <iostream>
#include <limits>
using namespace deckusb;
int main() {
    {
        auto buffers = std::make_shared<FrameBuffers>();
        auto held = std::make_unique<Frame>(buffers);
        held->pixels = buffers->acquire(64); held->pixels[0] = 73;
        auto address = held->pixels.data();
        auto moved = std::make_unique<Frame>(std::move(*held)); held.reset();
        { Frame other(buffers); other.pixels = buffers->acquire(64);
          assert(other.pixels.data() != address); }
        assert(moved->pixels[0] == 73);
        moved.reset();
        auto first = buffers->acquire(64), second = buffers->acquire(64);
        assert(first.data() == address || second.data() == address);
        assert((first.data() == address ? first[0] : second[0]) == 73);
        // Releasing after the caller drops the session pool remains safe.
        Frame late(buffers); late.pixels = buffers->acquire(4096);
        buffers.reset();
    }
    {
        FrameBuffers buffers;
        for (size_t size : {8u, 16u, 32u}) buffers.recycle(std::vector<uint8_t>(size));
        std::vector<uint8_t> larger(64, 91); auto address = larger.data();
        buffers.recycle(std::move(larger)); // Replace the smallest of three spares.
        auto result = buffers.acquire(64);
        assert(result.data() == address && result[63] == 91);
    }
    assert(encodedPacketSize("#software: Lavf61\n") == 0);
    assert(encodedPacketSize("0, 1, 1, 1, 23600, 0xe594d211\n") == 23600);
    for (auto line : {"0,0,0,1,0,0x0\n", "0,0,0,1,9999999999,0x0\n", "0,0,0,1,4,0x0", "0,0,0,1,x,0x0\n"}) {
        bool rejected = false; try { encodedPacketSize(line); } catch (...) { rejected = true; } assert(rejected);
    }
    std::vector<uint8_t> intra{0,0,0,1,0x67,1,0,0,1,0x68,1,0,0,0,1,0x65,1};
    assert(splitH264(intra).size() == 3);
    for (unsigned bad : {0u, 15u}) {
        auto bytes = intra; bytes[bad] = 1;
        bool rejected = false; try { splitH264(bytes); } catch (...) { rejected = true; } assert(rejected);
    }
    assert(encodedPacketSize("0, 1, 1, 0, 100, 0x0\n") == 100); // Encoders may omit duration.
    Header encoded; encoded.format = h264; encoded.bytes = 23600; validate(encoded);
    encoded.bytes = maxEncodedBytes + 1;
    bool rejectedEncoded = false; try { validate(encoded); } catch (...) { rejectedEncoded = true; } assert(rejectedEncoded);
    Header h;
    h.bytes = frameBytes(h.width, h.height, h.format);
    assert(h.bytes == 1536000);
    validate(h);
    for (auto bad : {0u, 1u, 1922u, std::numeric_limits<unsigned>::max()}) {
        bool rejected = false;
        try { frameBytes(bad, 800, nv12); } catch (...) { rejected = true; }
        assert(rejected);
    }
    for (unsigned field = 0; field < 4; ++field) {
        Header bad = h;
        if (field == 0) bad.magicValue = 0;
        if (field == 1) bad.versionValue++;
        if (field == 2) bad.bytes--;
        if (field == 3) bad.format = 0;
        bool rejected = false;
        try { validate(bad); } catch (...) { rejected = true; }
        assert(rejected);
    }
    Command c;
    assert(valid(c));
    c.type = key; c.code = linuxKey(0); c.value = 1;
    assert(c.code == 30 && valid(c));
    c.value = 2; assert(!valid(c));
    c.type = absolute; c.x = -1; assert(!valid(c));
    c.x = 65535; c.y = 65535; assert(valid(c));
    c.type = relative; c.x = std::numeric_limits<int>::min(); assert(!valid(c));
    assert(linuxKey(123) == 105 && linuxKey(127) == 0 && linuxKey(999) == 0);
    c = Command{}; c.type = configure; c.x = 800; c.y = 500; c.value = 60; c.code = nv12;
    for (auto qp : {0u, 20u, 24u, 28u}) { c.nonce = qp; assert(valid(c)); }
    for (auto qp : {1u, 19u, 29u, UINT32_MAX}) { c.nonce = qp; assert(!valid(c)); }
    c.nonce = 0;
    assert(valid(c)); c.x = 801; assert(!valid(c)); c.x = 800; c.value = 0; assert(!valid(c));
    // Both 16:9 and 16:10 high-resolution selections must survive the same
    // command and frame validation used on either end of the USB connection.
    for (unsigned height : {1080u, 1200u}) {
        c.x = 1920; c.y = height; c.value = 60; c.code = h264; assert(valid(c));
        Header large; large.width = 1920; large.height = height;
        large.bytes = frameBytes(large.width, large.height, nv12); validate(large);
        large.format = h264; large.bytes = 100; validate(large);
    }
    c.type = measure; c.value = 1; assert(valid(c)); c.value = 2; assert(!valid(c));
    assert(recommend(41.4).width == 800 && recommend(41.4).fps == 60);
    assert(recommend(38.9).width == 800 && recommend(38.9).fps == 60);
    assert(recommend(120).width == 1280 && recommend(120).fps == 60);
    assert(recommend(20).width == 800 && recommend(20).fps == 30);
    assert(recommend(0).width == 640 && recommend(0).fps == 30);
    assert(recommend(39, true).width == 640 && recommend(39, true).fps == 90);
    assert(recommend(30, true).fps == 60 && recommend(20, true).fps == 30);
    Command a, b;
    a.type = b.type = absolute; a.x = 100; b.x = 200;
    assert(combineMotion(a, b) && a.x == 200);
    b.type = key; b.code = 272; b.value = 1;
    assert(!combineMotion(a, b)); // A click must follow the position it used.
    a.type = b.type = relative; a.x = 30000; b.x = 3000; a.y = 1; b.y = -2;
    assert(!combineMotion(a, b) && a.x == 30000); // Preserve overflow as two moves.
    b.x = -100; assert(combineMotion(a, b) && a.x == 29900 && a.y == -1);
    b.type = release; assert(!combineMotion(a, b));
    TransferMeter meter;
    assert(!meter.update(1000000000, 1000000, 10));
    assert(meter.update(1250000000, 2000000, 25));
    assert(meter.megabytesPerSecond == 4 && meter.framesPerSecond == 60);
    assert(!meter.update(1500000000, 1, 1));
    assert(meter.megabytesPerSecond == 0 && meter.framesPerSecond == 0);
    AudioPacket packet; validate(packet);
    packet.magicValue = 0;
    bool rejectedAudio = false;
    try { validate(packet); } catch (...) { rejectedAudio = true; }
    assert(rejectedAudio);
    packet = AudioPacket{}; packet.samples.fill(123);
    PcmBuffer audio;
    std::array<int16_t, audioFrames * audioChannels> out;
    audio.push(packet); audio.pop(out.data(), out.size());
    assert(out[0] == 0 && audio.size() == out.size()); // Prime before playback.
    for (int i = 0; i < 3; ++i) audio.push(packet);
    audio.pop(out.data(), out.size());
    assert(out.front() == 123 && out.back() == 123);
    for (int i = 0; i < 4; ++i) audio.pop(out.data(), out.size());
    assert(out[0] == 0 && audio.underruns == 1);
    for (int i = 0; i < 13; ++i) audio.push(packet);
    assert(audio.trims == 1 && audio.size() == 5 * out.size()); // Gap raised target to 25 ms.
    audio.pop(out.data(), out.size()); assert(out.back() == 123);
    // Simulate two independent clocks for one minute in each direction.
    // The waveform checks stereo alignment and discontinuities, not just counts.
    for (double drift : {-0.001, 0.001}) {
        PcmBuffer clocked;
        AudioPacket tone;
        uint64_t sample = 0;
        auto pushTone = [&] {
            for (unsigned i = 0; i < audioFrames; ++i, ++sample) {
                int16_t value = int16_t(16000 * std::sin(sample * 2 * 3.141592653589793 * 440 / audioRate));
                tone.samples[i * 2] = value; tone.samples[i * 2 + 1] = -value;
            }
            clocked.push(tone);
        };
        for (int i = 0; i < 4; ++i) pushTone();
        double available = 0, meanCorrection = 0;
        int previous = 0;
        for (unsigned tick = 0; tick < 12000; ++tick) {
            available += audioFrames * (1 + drift);
            while (available >= audioFrames) { pushTone(); available -= audioFrames; }
            clocked.pop(out.data(), out.size());
            for (unsigned i = 0; i < audioFrames; ++i) {
                assert(out[i * 2] == -out[i * 2 + 1]);
                assert(std::abs(int(out[i * 2]) - previous) < 2000);
                previous = out[i * 2];
            }
            if (tick >= 6000) meanCorrection += clocked.correctionPPM() / 6000;
        }
        assert(clocked.underruns == 0 && clocked.trims == 0);
        assert(clocked.size() > 10 * 48 * 2 && clocked.size() < 35 * 48 * 2);
        assert(meanCorrection * drift > 0 && std::abs(meanCorrection) < 2000);
    }
    std::cout << "Protocol bounds, malformed frames, input validation, key map, and audio buffering: PASS\n";
}
