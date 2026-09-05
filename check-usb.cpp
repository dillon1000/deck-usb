#include "usb-video.hpp"
#include <cassert>
#include <cstdlib>
#include <iostream>

// Fake only the libusb entry points used by VideoReads. Deliver callbacks in
// reverse order to verify placement, cancellation, and frame-storage lifetime.
struct Request { libusb_transfer* transfer; size_t offset; unsigned index; bool cancelled = false; };
static std::vector<Request> pending;
static size_t nextOffset;
static unsigned submitted, allocated, peak, failSubmit, shortRead, badRead, errorEvent;
static std::atomic<bool>* stopOnEvent;
static bool raceCompletion;
static unsigned unnecessaryWaits;
extern "C" {
libusb_transfer* LIBUSB_CALL libusb_alloc_transfer(int) {
    ++allocated; return static_cast<libusb_transfer*>(std::calloc(1, sizeof(libusb_transfer)));
}
void LIBUSB_CALL libusb_free_transfer(libusb_transfer* transfer) {
    for (auto& request : pending) assert(request.transfer != transfer);
    --allocated; std::free(transfer);
}
int LIBUSB_CALL libusb_submit_transfer(libusb_transfer* transfer) {
    if (++submitted == failSubmit) return LIBUSB_ERROR_IO;
    pending.push_back({transfer, nextOffset, submitted}); nextOffset += transfer->length;
    peak = std::max(peak, unsigned(pending.size())); return 0;
}
int LIBUSB_CALL libusb_cancel_transfer(libusb_transfer* transfer) {
    for (auto& request : pending) if (request.transfer == transfer) { request.cancelled = true; return 0; }
    return LIBUSB_ERROR_NOT_FOUND;
}
static void finishRequest() {
    assert(!pending.empty());
    auto request = pending.back(); pending.pop_back();
    auto t = request.transfer;
    t->status = request.cancelled ? LIBUSB_TRANSFER_CANCELLED : request.index == badRead ? LIBUSB_TRANSFER_ERROR : LIBUSB_TRANSFER_COMPLETED;
    t->actual_length = t->length - (request.index == shortRead ? 1 : 0);
    if (!request.cancelled) for (int i = 0; i < t->actual_length; ++i) t->buffer[i] = uint8_t((request.offset + i) % 251);
    t->callback(t);
    if (stopOnEvent) stopOnEvent->store(true);
}
int LIBUSB_CALL libusb_handle_events_timeout_completed(libusb_context*, timeval*, int* completed) {
    if (errorEvent) { errorEvent = 0; return LIBUSB_ERROR_IO; }
    // Simulate another event thread completing between the outer atomic check
    // and libusb acquiring its lock. A missing completion pointer would poll.
    if (raceCompletion) {
        while (!pending.empty()) finishRequest();
        if (!completed || !*completed) ++unnecessaryWaits;
        return 0;
    }
    if (completed && *completed) return 0;
    finishRequest(); return 0;
}
const char* LIBUSB_CALL libusb_error_name(int) { return "injected error"; }
}
static void reset() {
    assert(pending.empty() && allocated == 0);
    nextOffset = submitted = peak = failSubmit = shortRead = badRead = errorEvent = 0;
    stopOnEvent = nullptr; raceCompletion = false; unnecessaryWaits = 0;
}
int main() {
    for (size_t size : {size_t(1), size_t(deckusb::chunk - 1), size_t(deckusb::chunk), size_t(deckusb::chunk + 17), size_t(deckusb::chunk * 3 + 77)}) {
        reset(); std::atomic<bool> stopping{false};
        {
            deckusb::VideoReads reads(nullptr, nullptr, 0x81, stopping);
            for (int frame = 0; frame < 2; ++frame) {
                nextOffset = 0;
                std::vector<uint8_t> bytes(size + 16, 0xff);
                reads.read(bytes.data(), size);
                for (size_t i = 0; i < size; ++i) assert(bytes[i] == i % 251);
                for (size_t i = size; i < bytes.size(); ++i) assert(bytes[i] == 0xff);
                assert(pending.empty() && peak <= 2);
            }
        }
        assert(allocated == 0);
    }
    reset(); raceCompletion = true;
    {
        std::atomic<bool> stopping{false};
        deckusb::VideoReads reads(nullptr, nullptr, 0x81, stopping);
        std::vector<uint8_t> bytes(deckusb::chunk * 3);
        reads.read(bytes.data(), bytes.size());
        assert(unnecessaryWaits == 0 && pending.empty());
    }
    for (unsigned failure = 0; failure < 5; ++failure) {
        reset(); std::atomic<bool> stopping{false};
        if (failure == 0) failSubmit = 2;
        if (failure == 1) shortRead = 1;
        if (failure == 2) badRead = 2;
        if (failure == 3) errorEvent = 1;
        if (failure == 4) stopOnEvent = &stopping;
        {
            deckusb::VideoReads reads(nullptr, nullptr, 0x81, stopping);
            bool rejected = false;
            std::vector<uint8_t> bytes(deckusb::chunk * 3);
            try { reads.read(bytes.data(), bytes.size()); } catch (const std::exception&) { rejected = true; }
            assert(rejected && pending.empty()); // No callback can touch freed pixels.
        }
        assert(allocated == 0);
    }
    std::cout << "USB overlap: ordering, frame bounds, short reads, submit failure, cancellation: PASS\n";
}
