#include "protocol.hpp"
#include <unistd.h>
#include <linux/aio_abi.h>
#include <sys/syscall.h>
#include <cassert>
#include <cstdarg>
#include <cstring>
#include <iostream>
#include <utility>

// Replace only this header's kernel boundary. Complete requests out of order
// and fail after successful submissions to verify draining before unwinding.
static long fakeSyscall(long operation, ...);
static ssize_t fakeWrite(int, const void*, size_t);
#define syscall fakeSyscall
#define write fakeWrite
#include "deck-video.hpp"
#undef syscall
#undef write

struct Pending { iocb* request; size_t offset; unsigned index; };
static std::vector<Pending> pending;
static std::vector<uint8_t> wire;
static std::vector<size_t> lengths;
static unsigned submits, peak, failAt, shortAt, badAt, contexts;
static bool interruptSubmit, interruptWait, interruptWrite;
static ssize_t fakeWrite(int, const void* bytes, size_t size) {
    if (std::exchange(interruptWrite, false)) { errno = EINTR; return -1; }
    auto data = static_cast<const uint8_t*>(bytes);
    wire.insert(wire.end(), data, data + size); lengths.push_back(size); return size;
}
static long fakeSyscall(long operation, ...) {
    va_list args; va_start(args, operation);
    if (operation == SYS_io_setup) {
        assert(va_arg(args, size_t) == 3);
        *va_arg(args, aio_context_t*) = 1; ++contexts; va_end(args); return 0;
    }
    assert(va_arg(args, aio_context_t) == 1);
    if (operation == SYS_io_destroy) {
        // Storage must remain valid until the cancellation/drain is complete.
        for (auto item : pending) assert(!memcmp(reinterpret_cast<void*>(item.request->aio_buf),
            wire.data() + item.offset, item.request->aio_nbytes));
        pending.clear(); --contexts; va_end(args); return 0;
    }
    if (operation == SYS_io_submit) {
        assert(va_arg(args, long) == 1);
        auto request = *va_arg(args, iocb**); va_end(args);
        if (std::exchange(interruptSubmit, false)) { errno = EINTR; return -1; }
        if (++submits == failAt) { errno = EIO; return -1; }
        assert(request->aio_lio_opcode == IOCB_CMD_PWRITE);
        pending.push_back({request, wire.size(), submits}); peak = std::max(peak, unsigned(pending.size()));
        fakeWrite(0, reinterpret_cast<void*>(request->aio_buf), request->aio_nbytes); return 1;
    }
    assert(operation == SYS_io_getevents);
    assert(va_arg(args, long) == 1); assert(va_arg(args, long) == 3);
    auto output = va_arg(args, io_event*); va_end(args);
    if (std::exchange(interruptWait, false)) { errno = EINTR; return -1; }
    assert(!pending.empty());
    auto item = pending.back(); pending.pop_back(); auto request = item.request;
    assert(!memcmp(reinterpret_cast<void*>(request->aio_buf), wire.data() + item.offset, request->aio_nbytes));
    *output = {}; output->data = request->aio_data; output->obj = reinterpret_cast<uintptr_t>(request);
    output->res = item.index == badAt ? -EIO : int64_t(request->aio_nbytes) - (item.index == shortAt);
    return 1;
}
static void reset() {
    assert(pending.empty() && contexts == 0);
    wire.clear(); lengths.clear(); submits = peak = failAt = shortAt = badAt = 0;
    interruptSubmit = interruptWait = interruptWrite = false;
}
int main() {
    using namespace deckusb;
    for (auto mode : {"serial", "large", "async"}) for (unsigned width : {2u, 802u, 1280u, 1920u}) {
        reset(); Header header; header.width = width; header.height = width == 1920 ? 1200 : 800;
        header.bytes = frameBytes(header.width, header.height, nv12);
        std::vector<uint8_t> pixels(header.bytes);
        for (size_t i = 0; i < pixels.size(); ++i) pixels[i] = i % 251;
        if (std::string_view(mode) == "async") interruptSubmit = interruptWait = true;
        else interruptWrite = true;
        {
            VideoWriter writer(7, mode); writer.writeFrame(header, pixels.data(), pixels.size());
            assert(pending.empty() && peak <= 3);
            assert(wire.size() == sizeof(header) + pixels.size());
            assert(!memcmp(wire.data(), &header, sizeof(header)));
            assert(!memcmp(wire.data() + sizeof(header), pixels.data(), pixels.size()));
            assert(lengths.front() == sizeof(header));
            auto bound = std::string_view(mode) == "large" ? 1024 * 1024 : chunk;
            for (auto length : lengths) assert(length <= bound);
            if (std::string_view(mode) == "large" && width == 1920) assert(lengths.size() == 5);
        }
    }
    for (unsigned failure = 0; failure < 4; ++failure) {
        reset(); Header header; header.bytes = frameBytes(header.width, header.height, nv12);
        std::vector<uint8_t> pixels(header.bytes, 91);
        if (failure < 2) failAt = failure ? 4 : 2;
        else if (failure == 2) shortAt = 3; else badAt = 3;
        VideoWriter writer(7, "async"); bool rejected = false;
        try { writer.writeFrame(header, pixels.data(), pixels.size()); } catch (const std::exception&) { rejected = true; }
        assert(rejected && pending.empty() && contexts == 0);
    }
    reset();
    bool rejected = false;
    try { VideoWriter writer(7, "unknown"); } catch (const std::exception&) { rejected = true; }
    assert(rejected && contexts == 0);
    std::cout << "Deck USB writes: framing, request bounds, interruption, completion, and failure drain: PASS\n";
}
