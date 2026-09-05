#pragma once
#include "protocol.hpp"
#include <memory>
#include <mutex>

namespace deckusb {
// Cache at most three released payloads: a reader, a pending frame, and GPU use
// normally overlap. This is storage reuse, not a queue. Held frames are never
// reused; a slow consumer can allocate extra storage, which is freed on release.
class FrameBuffers {
    std::mutex mutex;
    std::array<std::vector<uint8_t>, 3> spare;
public:
    std::vector<uint8_t> acquire(size_t size) {
        std::vector<uint8_t> bytes;
        {
            std::lock_guard lock(mutex);
            for (auto& buffer : spare) if (buffer.capacity() >= size) {
                bytes.swap(buffer); break;
            }
        }
        bytes.resize(size); // Same-size frames keep their storage and skip clearing.
        return bytes;
    }
    void recycle(std::vector<uint8_t> bytes) {
        if (!bytes.capacity()) return;
        std::lock_guard lock(mutex);
        for (auto& buffer : spare) if (!buffer.capacity()) {
            buffer.swap(bytes); return;
        }
        // Retire undersized cached buffers after a resolution increase.
        auto smallest = std::min_element(spare.begin(), spare.end(), [](auto& a, auto& b) {
            return a.capacity() < b.capacity();
        });
        if (smallest->capacity() < bytes.capacity()) smallest->swap(bytes);
    }
};

// Moving into DisplayFrame transfers both payload and pool ownership. The last
// GPU reference returns the buffer, even after its USB session has been closed.
struct Frame {
    Header header;
    std::vector<uint8_t> pixels;
    uint64_t receivedNs = 0;
    double decodeMs = 0;
    std::shared_ptr<FrameBuffers> buffers;
    explicit Frame(std::shared_ptr<FrameBuffers> owner = {}) : buffers(std::move(owner)) {}
    Frame(Frame&&) = default;
    Frame(const Frame&) = delete;
    Frame& operator=(const Frame&) = delete;
    ~Frame() { if (buffers) buffers->recycle(std::move(pixels)); }
};
}
