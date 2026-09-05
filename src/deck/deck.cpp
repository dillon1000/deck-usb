#include "protocol.hpp"
#include "codec.hpp"
#include "deck-input.hpp"
#include "deck-config.hpp"
#include "deck-stats.hpp"
#include <array>
#include <atomic>
#include <cerrno>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <linux/input.h>
#include <linux/uinput.h>
#include <linux/usb/ch9.h>
#include <linux/usb/functionfs.h>
#include <mutex>
#include <poll.h>
#include <sys/ioctl.h>
#include <thread>
#include <unistd.h>
using namespace deckusb;

template<class T> static void append(std::vector<uint8_t>& v, const T& value) {
    auto p = reinterpret_cast<const uint8_t*>(&value);
    v.insert(v.end(), p, p + sizeof(value));
}
// FunctionFS assigns ep1=video IN, ep2=commands OUT, ep3=ack IN, ep4=audio IN.
// Full/high/super-speed descriptors allow the same app to measure slow cables.
// MaxBurst 15 allows 16 packets per SuperSpeed burst without queuing more frames.
static void descriptors(int ep0) {
    std::vector<uint8_t> d;
    usb_functionfs_descs_head_v2 head{};
    head.magic = FUNCTIONFS_DESCRIPTORS_MAGIC_V2;
    head.flags = FUNCTIONFS_HAS_FS_DESC | FUNCTIONFS_HAS_HS_DESC | FUNCTIONFS_HAS_SS_DESC;
    append(d, head);
    for (uint32_t n : {5, 5, 9}) append(d, n);
    for (uint16_t packet : {64, 512, 1024}) {
        usb_interface_descriptor iface{};
        iface.bLength = USB_DT_INTERFACE_SIZE; iface.bDescriptorType = USB_DT_INTERFACE;
        iface.bNumEndpoints = 4; iface.bInterfaceClass = USB_CLASS_VENDOR_SPEC;
        iface.iInterface = 1;
        append(d, iface);
        for (uint8_t address : {0x81, 0x02, 0x83, 0x84}) {
            usb_endpoint_descriptor_no_audio ep{};
            ep.bLength = USB_DT_ENDPOINT_SIZE; ep.bDescriptorType = USB_DT_ENDPOINT;
            ep.bEndpointAddress = address; ep.bmAttributes = USB_ENDPOINT_XFER_BULK;
            ep.wMaxPacketSize = packet;
            append(d, ep);
            if (packet == 1024) {
                usb_ss_ep_comp_descriptor ss{};
                ss.bLength = USB_DT_SS_EP_COMP_SIZE; ss.bDescriptorType = USB_DT_SS_ENDPOINT_COMP;
                ss.bMaxBurst = address == 0x81 ? 15 : 0;
                append(d, ss);
            }
        }
    }
    head.length = d.size(); memcpy(d.data(), &head, sizeof(head));
    require(write(ep0, d.data(), d.size()) == ssize_t(d.size()), "FunctionFS descriptors");
    std::vector<uint8_t> s;
    const char label[] = "DeckUSB Direct";
    usb_functionfs_strings_head sh{FUNCTIONFS_STRINGS_MAGIC,
        uint32_t(sizeof(usb_functionfs_strings_head) + 2 + sizeof(label)), 1, 1};
    append(s, sh); append(s, uint16_t(0x0409));
    s.insert(s.end(), label, label + sizeof(label));
    require(write(ep0, s.data(), s.size()) == ssize_t(s.size()), "FunctionFS strings");
}

// Thread failures terminate the connection, so no half-working input session remains.
template<class F> static void worker(F f) {
    std::thread([f] { try { f(); } catch (const std::exception& e) {
        fprintf(stderr, "DeckUSB: %s\n", e.what()); std::exit(1);
    }}).detach();
}

int main(int argc, char** argv) try {
    if (argc == 2 && std::string(argv[1]) == "--check-input") { Input input; input.selfCheck(); return 0; }
    Header base;
    unsigned fps = 60;
    int audioFd = -1;
    FILE* packetSizes = nullptr;
    bool synthetic = false, benchmark = false;
    std::string path = "/run/deckusb/ffs";
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto value = [&]() -> const char* {
            if (++i >= argc) throw std::runtime_error("Missing option value");
            return argv[i];
        };
        if (arg == "--test") synthetic = true;
        else if (arg == "--bench") synthetic = benchmark = true;
        else if (arg == "--width") base.width = std::stoul(value());
        else if (arg == "--height") base.height = std::stoul(value());
        else if (arg == "--packet-sizes") { packetSizes = fopen(value(), "r"); require(packetSizes, "Open packet sizes"); }
        else if (arg == "--audio-fd") audioFd = std::stoi(value());
        else if (arg == "--fps") fps = std::stoul(value());
        else if (arg == "--format") {
            std::string f = value();
            if (f != "nv12" && f != "bgra" && f != "h264") throw std::runtime_error("Use nv12, bgra, or h264");
            base.format = f == "h264" ? h264 : f == "nv12" ? nv12 : bgra;
        } else if (arg == "--ffs") path = value();
        else throw std::runtime_error("Usage: deck-usb [--test|--bench] [--width N --height N --fps N --format nv12|bgra --ffs PATH]; live raw frames arrive on stdin");
    }
    if (!fps || fps > 240) throw std::runtime_error("FPS must be 1..240");
    frameBytes(base.width, base.height, nv12);
    if (base.format == h264 && (!packetSizes || synthetic)) throw std::runtime_error("H.264 needs live packet framing");
    base.bytes = base.format == h264 ? 0 : frameBytes(base.width, base.height, base.format);
    // Give FFmpeg room for larger writes without adding a full-size frame queue.
    // This only changes a live raw input pipe. Kernel limits or a regular file
    // can reject the hint; capture still works with the original pipe capacity.
    if (!synthetic && base.bytes >= 1024 * 1024)
        (void)fcntl(STDIN_FILENO, F_SETPIPE_SZ, 1024 * 1024);
    int ep0 = openFd(path + "/ep0", O_RDWR);
    descriptors(ep0);
    int video = openFd(path + "/ep1", O_RDWR);
    int commands = openFd(path + "/ep2", O_RDWR);
    int acks = openFd(path + "/ep3", O_RDWR);
    int audio = openFd(path + "/ep4", O_RDWR);
    // A fresh marker, rather than old endpoint paths, gates configfs binding.
    int readyFd = open((path + "/../ready").c_str(), O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0600);
    require(readyFd >= 0, "Create ready marker");
    require(write(readyFd, "1", 1) == 1, "Write ready marker");
    close(readyFd);
    fprintf(stderr, "Descriptors ready. Waiting for USB configuration.\n");
    for (;;) {
        usb_functionfs_event event{};
        require(readAll(ep0, &event, sizeof(event)), "USB control EOF");
        if (event.type == FUNCTIONFS_ENABLE) break;
    }
    // Capture is supplied by parec as the desktop user, never from a microphone.
    // A stalled USB reader must not build a pipe of stale sound. Drain capture
    // continuously and keep at most six 5 ms packets before this endpoint.
    std::mutex audioMutex;
    std::condition_variable audioReady;
    std::deque<AudioPacket> audioPackets;
    if (audioFd >= 0) worker([&] {
        uint64_t sequence = 0;
        for (;;) {
            AudioPacket packet; packet.sequence = ++sequence;
            require(readAll(audioFd, packet.samples.data(), sizeof(packet.samples)), "Audio capture ended");
            { std::lock_guard lock(audioMutex);
              if (audioPackets.size() == 6) audioPackets.clear();
              audioPackets.push_back(packet); }
            audioReady.notify_one();
        }
    });
    worker([&] {
        uint64_t sequence = 0;
        auto deadline = std::chrono::steady_clock::now();
        for (;;) {
            AudioPacket packet;
            if (audioFd >= 0) {
                std::unique_lock lock(audioMutex);
                audioReady.wait(lock, [&] { return !audioPackets.empty(); });
                packet = audioPackets.front(); audioPackets.pop_front();
            } else {
                packet.sequence = ++sequence;
                deadline += std::chrono::milliseconds(5);
                std::this_thread::sleep_until(deadline);
                if (deadline < std::chrono::steady_clock::now()) deadline = std::chrono::steady_clock::now();
            }
            writeAll(audio, &packet, sizeof(packet));
        }
    });
    Input input;
    std::mutex sensorMutex;
    DeckStats sensorStats;
    // Poll at 1 Hz off the input/video threads. Only a small cached record is
    // copied during a heartbeat, so slow sensor reads cannot delay a key press.
    worker([&] {
        DeckSampler sampler;
        for (;;) {
            auto sample = sampler.sample();
            { std::lock_guard lock(sensorMutex); sensorStats = sample; }
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    });
    std::atomic<bool> cableTest{false};
    std::atomic<uint64_t> lastCommand{nowNs()};
    worker([&] {
        for (;;) {
            usb_functionfs_event event{};
            require(readAll(ep0, &event, sizeof(event)), "USB control EOF");
            if (event.type == FUNCTIONFS_DISABLE || event.type == FUNCTIONFS_UNBIND)
                throw std::runtime_error("USB disconnected; input device removed");
            if (event.type == FUNCTIONFS_SETUP) {
                // Stall unsupported vendor requests using the opposite data direction.
                if (event.u.setup.bRequestType & USB_DIR_IN) read(ep0, nullptr, 0);
                else write(ep0, nullptr, 0);
            }
        }
    });
    worker([&] {
        for (;;) {
            Command c;
            require(readAll(commands, &c, sizeof(c)), "Input EOF");
            uint64_t received = nowNs();
            if (valid(c) && c.type == restart) throw std::runtime_error("Viewer closed; restart USB framing");
            if (!valid(c)) throw std::runtime_error("Invalid USB command");
            if (c.type == configure) {
                applyVideoSetting({unsigned(c.x), unsigned(c.y), unsigned(c.value), unsigned(c.code)});
                input.releaseAll(); lastCommand.store(received); continue;
            }
            if (c.type == measure) { input.releaseAll(); cableTest = c.value; }
            else input.apply(c);
            lastCommand.store(received);
            if (c.type == ping) {
                StatsAck reply;
                if (c.code == telemetryRequest) { std::lock_guard lock(sensorMutex); reply.stats = sensorStats; }
                reply.pong.nonce = c.nonce; reply.pong.receiveNs = received; reply.pong.sendNs = nowNs();
                writeAll(acks, &reply, c.code == telemetryRequest ? sizeof(reply) : sizeof(Pong));
            }
        }
    });
    worker([&] {
        for (;;) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            auto silence = nowNs() - lastCommand.load();
            if (silence > 1000000000ULL) input.releaseAll();
            // Also recover after a killed viewer or a blocked acknowledgment.
            if (silence > 3000000000ULL) throw std::runtime_error("Viewer heartbeat stopped; restart USB framing");
        }
    });
    std::mutex mutex;
    std::condition_variable ready;
    std::vector<uint8_t> latest(base.bytes);
    uint64_t captured = 0, captureTime = 0;
    bool done = false;
    if (!synthetic) worker([&] {
        std::vector<uint8_t> next(base.bytes);
        try { for (;;) {
            if (packetSizes) {
                uint32_t bytes = 0;
                char line[512];
                while (!bytes) {
                    require(fgets(line, sizeof(line), packetSizes) != nullptr, "Encoded capture ended");
                    bytes = encodedPacketSize(line);
                }
                next.resize(bytes);
            }
            if (!readAll(STDIN_FILENO, next.data(), next.size())) {
                if (packetSizes) throw std::runtime_error("Truncated encoded payload");
                break;
            }
            if (packetSizes) splitH264(next); // Reject dependent frames before any drops.
            uint64_t completed = nowNs();
            { std::lock_guard lock(mutex); next.swap(latest); captureTime = completed; ++captured; }
            ready.notify_one();
        }
        } catch (...) {
            // A bad encoder record must not create a reconnect loop that also
            // removes USB management. Restore the same dimensions/rate in raw.
            if (packetSizes) applyVideoSetting({base.width, base.height, fps, nv12});
            throw;
        }
        { std::lock_guard lock(mutex); done = true; } ready.notify_one();
    });
    std::vector<uint8_t> pixels(base.bytes, 128);
    uint64_t sent = 0, sequence = 0;
    auto deadline = std::chrono::steady_clock::now();
    for (;;) {
        Header h = base;
        bool testing = cableTest.load();
        h.sequence = ++sequence;
        // Header status confirms benchmark state and applied FPS to the viewer.
        h.reserved[0] = testing || benchmark; h.reserved[1] = !synthetic; h.reserved[2] = fps;
        if (synthetic || testing) {
            if (h.format == h264) { h.format = nv12; h.bytes = frameBytes(h.width, h.height, nv12); }
            pixels.resize(h.bytes, 128);
            // Moving grayscale stripes exercise frame ordering and both render formats.
            if ((!benchmark && !testing) || sequence == 1) for (unsigned y = 0; y < h.height; ++y)
                for (unsigned x = 0; x < h.width; ++x) {
                    uint8_t shade = 16 + ((x + sequence * 8) / 64 % 8) * 30;
                    if (h.format == nv12) pixels[y * h.width + x] = shade;
                    else { size_t p = (y * h.width + x) * 4; pixels[p] = pixels[p+1] = pixels[p+2] = shade; pixels[p+3] = 255; }
                }
            h.captureDoneNs = nowNs();
        } else {
            std::unique_lock lock(mutex);
            ready.wait(lock, [&] { return captured != sent || done; });
            if (captured == sent && done) throw std::runtime_error("Capture ended; check FFmpeg output");
            h.dropped = captured - sent - 1;
            h.captureDoneNs = captureTime; sent = captured; pixels.swap(latest); h.bytes = pixels.size();
        }
        h.sendNs = nowNs();
        writeAll(video, &h, sizeof(h));
        writeAll(video, pixels.data(), pixels.size());
        if (synthetic && !benchmark && !testing) {
            deadline += std::chrono::nanoseconds(1000000000ULL / fps);
            if (deadline < std::chrono::steady_clock::now()) deadline = std::chrono::steady_clock::now();
            std::this_thread::sleep_until(deadline);
        }
    }
} catch (const std::exception& e) { fprintf(stderr, "DeckUSB: %s\n", e.what()); return 1; }
