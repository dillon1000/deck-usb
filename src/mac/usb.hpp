#pragma once
#include "protocol.hpp"
#include "usb-video.hpp"
#include <libusb.h>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

namespace deckusb {
// libusb handles host USB access only. There are no sockets or network fallbacks.
// One video reader, one input writer, and one ack reader keep controls independent.
class USB {
    libusb_context* context = nullptr;
    libusb_device_handle* handle = nullptr;
    int interfaceNumber = -1;
    uint8_t videoEndpoint = 0, commandEndpoint = 0, ackEndpoint = 0, audioEndpoint = 0;
    std::atomic<bool> stopping{false};
    std::thread videoThread, commandThread, ackThread, audioThread;
    std::mutex commandMutex, statsMutex;
    std::condition_variable commandsReady;
    std::deque<Command> commands;
    std::vector<double> roundTrips;
    std::atomic<uint64_t> byteCount{0}, frameCount{0}, dropCount{0};
    uint64_t started = 0;
    bool pipelined;
    std::atomic<uint64_t> payloadReadNs{0};
    std::atomic<double> lastPayloadMs{0}, lastDeckQueueMs{0};
    std::atomic<unsigned> width{0}, height{0}, fps{0}, format{nv12}, benchState{0}, liveState{0};
    std::function<void(std::string)> onError;
    void fail(const std::string& message) {
        if (!stopping.exchange(true)) {
            fprintf(stderr, "%s\n", message.c_str());
            if (onError) onError(message);
        }
        commandsReady.notify_all();
    }
    void read(void* destination, size_t size, uint8_t endpoint) {
        auto p = static_cast<uint8_t*>(destination);
        while (size && !stopping) {
            int transferred = 0;
            int result = libusb_bulk_transfer(handle, endpoint, p,
                int(std::min(size, size_t(chunk))), &transferred, 1000);
            if (result) throw std::runtime_error(std::string("USB read endpoint ") + std::to_string(endpoint) + ": " + libusb_error_name(result));
            if (!transferred) throw std::runtime_error("Empty USB transfer");
            p += transferred; size -= transferred;
        }
        if (size) throw std::runtime_error("USB stopped");
    }
    void send(Command command) {
        int transferred = 0;
        if (command.type == ping) command.nonce = nowNs();
        int result = libusb_bulk_transfer(handle, commandEndpoint, reinterpret_cast<uint8_t*>(&command),
            sizeof(command), &transferred, 250);
        if (result || transferred != sizeof(command))
            throw std::runtime_error(std::string("USB input: ") + libusb_error_name(result));
    }
    template<class F> std::thread thread(F f) {
        return std::thread([this, f] {
            try { f(); } catch (const std::exception& e) { fail(e.what()); }
        });
    }
public:
    explicit USB(bool overlap = true) : pipelined(overlap) {
        int result = libusb_init(&context);
        if (result) throw std::runtime_error(libusb_error_name(result));
    }
    USB(const USB&) = delete;
    USB& operator=(const USB&) = delete;
    ~USB() {
        stop();
        if (handle) { if (interfaceNumber >= 0) libusb_release_interface(handle, interfaceNumber); libusb_close(handle); }
        libusb_exit(context);
    }
    void list() {
        libusb_device** devices = nullptr;
        ssize_t count = libusb_get_device_list(context, &devices);
        if (count < 0) throw std::runtime_error("Cannot list USB devices");
        for (ssize_t i = 0; i < count; ++i) {
            libusb_device_descriptor d{};
            if (!libusb_get_device_descriptor(devices[i], &d))
                printf("USB %04x:%04x bus=%u address=%u speed=%s\n", d.idVendor, d.idProduct,
                    libusb_get_bus_number(devices[i]), libusb_get_device_address(devices[i]),
                    speedName(libusb_get_device_speed(devices[i])));
        }
        if (!count) puts("No USB devices are enumerated. Enable the Deck gadget first.");
        libusb_free_device_list(devices, 1);
    }
    static const char* speedName(int speed) {
        switch (speed) {
            case LIBUSB_SPEED_SUPER_PLUS: return "USB 3, 10 Gbit/s or faster";
            case LIBUSB_SPEED_SUPER: return "USB 3, 5 Gbit/s";
            case LIBUSB_SPEED_HIGH: return "USB 2, 480 Mbit/s";
            case LIBUSB_SPEED_FULL: return "USB 1, 12 Mbit/s";
            default: return "unknown";
        }
    }
    // Require both the prototype IDs and its product string. Never detach another
    // device's kernel driver or silently select the first of multiple matching Decks.
    void connect() {
        libusb_device** devices = nullptr;
        ssize_t count = libusb_get_device_list(context, &devices);
        if (count < 0) throw std::runtime_error("Cannot list USB devices");
        unsigned matches = 0;
        for (ssize_t i = 0; i < count; ++i) {
            libusb_device_descriptor d{};
            if (libusb_get_device_descriptor(devices[i], &d) || d.idVendor != vendor || d.idProduct != product) continue;
            libusb_device_handle* candidate = nullptr;
            if (libusb_open(devices[i], &candidate)) continue;
            unsigned char name[128]{};
            int n = libusb_get_string_descriptor_ascii(candidate, d.iProduct, name, sizeof(name));
            if (n > 0 && std::string(reinterpret_cast<char*>(name), n) == "DeckUSB Direct") {
                ++matches;
                if (!handle) handle = candidate; else libusb_close(candidate);
            } else libusb_close(candidate);
        }
        libusb_free_device_list(devices, 1);
        if (matches != 1) throw std::runtime_error(matches ? "Connect one DeckUSB device at a time" :
            "DeckUSB is not connected. Start deck.sh on the Deck, then reconnect here.");
        int configuration = 0;
        int result = libusb_get_configuration(handle, &configuration);
        if (!result && configuration != 1) result = libusb_set_configuration(handle, 1);
        if (result) throw std::runtime_error(libusb_error_name(result));
        // The gadget controller may renumber endpoints while binding functions.
        // Use the active descriptor, not the numbers requested by FunctionFS.
        libusb_config_descriptor* config = nullptr;
        result = libusb_get_active_config_descriptor(libusb_get_device(handle), &config);
        if (result) throw std::runtime_error(libusb_error_name(result));
        for (unsigned i = 0; i < config->bNumInterfaces; ++i) {
            const auto& iface = config->interface[i].altsetting[0];
            if (iface.bInterfaceClass != LIBUSB_CLASS_VENDOR_SPEC || iface.bNumEndpoints != 4) continue;
            interfaceNumber = iface.bInterfaceNumber;
            for (unsigned j = 0; j < iface.bNumEndpoints; ++j) {
                const auto& ep = iface.endpoint[j];
                if ((ep.bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK) continue;
                if (!(ep.bEndpointAddress & LIBUSB_ENDPOINT_IN)) commandEndpoint = ep.bEndpointAddress;
                else if (!videoEndpoint) videoEndpoint = ep.bEndpointAddress;
                else if (!ackEndpoint) ackEndpoint = ep.bEndpointAddress;
                else audioEndpoint = ep.bEndpointAddress;
            }
            break;
        }
        libusb_free_config_descriptor(config);
        if (interfaceNumber < 0 || !videoEndpoint || !commandEndpoint || !ackEndpoint || !audioEndpoint)
            throw std::runtime_error("The USB video/input interface is incomplete");
        result = libusb_claim_interface(handle, interfaceNumber);
        if (result) throw std::runtime_error(std::string("Cannot claim USB interface: ") + libusb_error_name(result));
        fprintf(stderr, "Interface %d: video=%02x input=%02x ack=%02x\n", interfaceNumber, videoEndpoint, commandEndpoint, ackEndpoint);
        fprintf(stderr, "Connected: %s\n", speedName(libusb_get_device_speed(libusb_get_device(handle))));
    }
    void start(std::function<void(std::shared_ptr<Frame>)> onFrame,
               std::function<void(std::string)> error,
               std::function<void(const AudioPacket&)> onAudio = [](const AudioPacket&) {}) {
        onError = std::move(error); started = nowNs();
        commandThread = thread([this] {
            uint64_t nextPing = 0;
            while (!stopping) {
                if (nowNs() >= nextPing) { send(Command{}); nextPing = nowNs() + 100000000; }
                std::unique_lock lock(commandMutex);
                commandsReady.wait_for(lock, std::chrono::milliseconds(2), [&] { return !commands.empty() || stopping; });
                if (!commands.empty()) { auto c = commands.front(); commands.pop_front(); lock.unlock(); send(c); }
            }
        });
        ackThread = thread([this] {
            while (!stopping) {
                Pong pong; read(&pong, sizeof(pong), ackEndpoint);
                uint64_t received = nowNs();
                if (pong.magicValue != magic || pong.versionValue != version || pong.nonce > received)
                    throw std::runtime_error("Invalid USB acknowledgment");
                double rtt = (received - pong.nonce) / 1e6;
                std::lock_guard lock(statsMutex);
                // retain the latest 600 samples (one minute); use a ring
                // only if this small, once-per-100-ms erase becomes measurable.
                if (roundTrips.size() == 600) roundTrips.erase(roundTrips.begin());
                roundTrips.push_back(rtt);
            }
        });
        audioThread = thread([this, onAudio] {
            uint64_t previous = 0;
            while (!stopping) {
                AudioPacket packet; read(&packet, sizeof(packet), audioEndpoint); validate(packet);
                if (packet.sequence <= previous) throw std::runtime_error("Audio sequence moved backward");
                previous = packet.sequence; onAudio(packet);
            }
        });
        videoThread = thread([this, onFrame] {
            VideoReads reads(context, handle, videoEndpoint, stopping);
            uint64_t previous = 0;
            while (!stopping) {
                auto frame = std::make_shared<Frame>();
                read(&frame->header, sizeof(Header), videoEndpoint); validate(frame->header);
                if (frame->header.sequence <= previous) throw std::runtime_error("Frame sequence moved backward");
                previous = frame->header.sequence;
                frame->pixels.resize(frame->header.bytes);
                uint64_t payloadStart = nowNs();
                if (pipelined) reads.read(frame->pixels.data(), frame->pixels.size());
                else read(frame->pixels.data(), frame->pixels.size(), videoEndpoint);
                uint64_t duration = nowNs() - payloadStart;
                payloadReadNs += duration; lastPayloadMs = duration / 1e6;
                lastDeckQueueMs = frame->header.sendNs >= frame->header.captureDoneNs ? (frame->header.sendNs - frame->header.captureDoneNs) / 1e6 : 0;
                width = frame->header.width; height = frame->header.height; format = frame->header.format;
                fps = frame->header.reserved[2]; benchState = frame->header.reserved[0]; liveState = frame->header.reserved[1];
                frame->receivedNs = nowNs(); byteCount += frame->pixels.size(); ++frameCount;
                dropCount += frame->header.dropped;
                onFrame(std::move(frame));
            }
        });
    }
    void enqueue(Command c) {
        if (stopping || !valid(c)) return;
        std::lock_guard lock(commandMutex);
        if (!commands.empty() && combineMotion(commands.back(), c)) return;
        // Do not let a stalled USB link leave minutes of stale input queued.
        // Release everything after overflow; the next physical press starts fresh.
        if (commands.size() >= 256) { commands.clear(); Command r; r.type = release; commands.push_back(r); }
        commands.push_back(c); commandsReady.notify_one();
    }
    void stop() {
        stopping = true; commandsReady.notify_all();
        for (auto t : {&videoThread, &commandThread, &ackThread, &audioThread}) if (t->joinable()) t->join();
        // The Deck also has a one-second heartbeat watchdog if this cannot arrive.
        if (handle && started) {
            // A new reader cannot resume mid-frame. Restart the sender so the
            // supervisor flushes every endpoint before the next connection.
            try { Command c; c.type = restart; send(c); } catch (...) {}
            started = 0;
        }
    }
    uint64_t bytes() const { return byteCount.load(); }
    uint64_t frames() const { return frameCount.load(); }
    double payloadMilliseconds() const { return lastPayloadMs.load(); }
    double deckQueueMilliseconds() const { return lastDeckQueueMs.load(); }
    VideoSetting setting() const { return {width.load(), height.load(), fps.load(), format.load()}; }
    bool measuring() const { return benchState != 0; }
    bool live() const { return liveState != 0; }
    int speed() const { return handle ? libusb_get_device_speed(libusb_get_device(handle)) : 0; }
    bool running() const { return handle && started && !stopping; }
    double medianRTT() {
        std::lock_guard lock(statsMutex);
        auto sorted = roundTrips; std::sort(sorted.begin(), sorted.end());
        return sorted.empty() ? 0 : sorted[sorted.size()/2];
    }
    std::string stats() {
        double seconds = started ? (nowNs() - started) / 1e9 : 1;
        std::vector<double> rtts;
        { std::lock_guard lock(statsMutex); rtts = roundTrips; }
        std::sort(rtts.begin(), rtts.end());
        char out[256];
        snprintf(out, sizeof(out), "%.1f fps | %.1f MB/s | USB RTT p50 %.2f ms, p95 %.2f ms | %llu capture drops | USB payload %.2f ms (%s)",
            frameCount.load() / seconds, byteCount.load() / seconds / 1e6,
            rtts.empty() ? 0 : rtts[rtts.size()/2], rtts.empty() ? 0 : rtts[(rtts.size()-1)*95/100],
            static_cast<unsigned long long>(dropCount.load()),
            frameCount ? payloadReadNs.load() / double(frameCount.load()) / 1e6 : 0, pipelined ? "overlap" : "serial");
        return out;
    }
};
}
