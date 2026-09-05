#pragma once
#include "protocol.hpp"
#include <libusb.h>
#include <atomic>
#include <string>

namespace deckusb {
// At most two payload reads are in flight, all inside one validated frame.
// Header reads remain separate. Short/error transfers end the session; never
// shift subsequent payload bytes into the wrong part of a frame.
class VideoReads {
    struct Slot {
        libusb_transfer* transfer = nullptr;
        std::atomic<bool> done{true};
        // libusb reads this under its event lock. Only the callback sets it;
        // the atomic flag publishes transfer fields to our reader thread.
        int eventCompleted = 1;
    };
    std::array<Slot, 2> slots;
    libusb_context* context;
    libusb_device_handle* handle;
    uint8_t endpoint;
    std::atomic<bool>& stopping;
    static void LIBUSB_CALL completed(libusb_transfer* transfer) {
        auto& slot = *static_cast<Slot*>(transfer->user_data);
        slot.eventCompleted = 1;
        slot.done.store(true, std::memory_order_release);
    }
    void events(Slot& slot) {
        timeval timeout{0, 10000}; // Recheck completion under the lock before any wait.
        int result = libusb_handle_events_timeout_completed(context, &timeout, &slot.eventCompleted);
        if (result && result != LIBUSB_ERROR_INTERRUPTED)
            throw std::runtime_error(std::string("USB events: ") + libusb_error_name(result));
    }
    void submit(Slot& slot, uint8_t* bytes, size_t length) {
        libusb_fill_bulk_transfer(slot.transfer, handle, endpoint, bytes, int(length), completed, &slot, 1000);
        slot.eventCompleted = 0; slot.done = false;
        int result = libusb_submit_transfer(slot.transfer);
        if (result) { slot.done = true; throw std::runtime_error(std::string("USB submit: ") + libusb_error_name(result)); }
    }
    void wait(Slot& slot) {
        while (!slot.done.load(std::memory_order_acquire)) {
            if (stopping) throw std::runtime_error("USB stopped");
            events(slot);
        }
        if (slot.transfer->status != LIBUSB_TRANSFER_COMPLETED || slot.transfer->actual_length != slot.transfer->length)
            throw std::runtime_error("USB payload failed or was short (status " + std::to_string(slot.transfer->status) + ")");
    }
    // Completion can run on another libusb reader thread. Drain every callback
    // before releasing transfers or their frame storage, including failed submits.
    void cancel() noexcept {
        for (auto& slot : slots) if (!slot.done.load()) libusb_cancel_transfer(slot.transfer);
        for (auto& slot : slots) while (!slot.done.load(std::memory_order_acquire)) {
            timeval timeout{0, 10000};
            libusb_handle_events_timeout_completed(context, &timeout, &slot.eventCompleted);
        }
    }
public:
    VideoReads(libusb_context* context, libusb_device_handle* handle, uint8_t endpoint, std::atomic<bool>& stopping)
        : context(context), handle(handle), endpoint(endpoint), stopping(stopping) {
        for (auto& slot : slots) {
            slot.transfer = libusb_alloc_transfer(0);
            if (!slot.transfer) {
                for (auto& allocated : slots) if (allocated.transfer) libusb_free_transfer(allocated.transfer);
                throw std::runtime_error("USB transfer allocation failed");
            }
        }
    }
    VideoReads(const VideoReads&) = delete;
    VideoReads& operator=(const VideoReads&) = delete;
    ~VideoReads() { cancel(); for (auto& slot : slots) libusb_free_transfer(slot.transfer); }
    void read(uint8_t* destination, size_t size) {
        size_t submitted = 0, count = 0, finished = 0;
        auto next = [&](Slot& slot) {
            size_t length = std::min(size - submitted, size_t(chunk));
            submit(slot, destination + submitted, length); submitted += length; ++count;
        };
        try {
            for (auto& slot : slots) if (submitted < size) next(slot);
            while (finished < count) {
                auto& slot = slots[finished++ % slots.size()];
                wait(slot);
                if (submitted < size) next(slot);
            }
        } catch (...) { cancel(); throw; }
    }
};
}
