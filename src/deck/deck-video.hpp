#pragma once
#include "deck-io.hpp"
#include <linux/aio_abi.h>
#include <sys/syscall.h>
#include <string_view>

// FunctionFS preserves endpoint request order. Keep the short header request
// separate for existing viewers, but queue payload behind it before waiting.
// Only chunks of ONE frame may overlap; return after every request completes.
class VideoWriter {
    int fd;
    std::string_view mode;
    aio_context_t context = 0;
    std::array<iocb, 3> requests{};
    std::array<bool, 3> active{};
    void destroy() noexcept {
        if (!context) return;
        // io_destroy cancels and drains requests before their source buffers
        // can be released, including after a partial batch submission failure.
        long result;
        do { result = syscall(SYS_io_destroy, context); } while (result < 0 && errno == EINTR);
        if (result < 0) std::terminate(); // Never release possibly active storage.
        context = 0;
    }
public:
    // "large" uses 1 MiB writes without changing host reads or wire records.
    // "serial" retains 256 KiB writes for A/B checks; "async" overlaps three
    // 256 KiB requests, including the header. Select before a session starts.
    explicit VideoWriter(int endpoint, std::string_view strategy = "large") : fd(endpoint), mode(strategy) {
        if (mode != "serial" && mode != "large" && mode != "async")
            throw std::runtime_error("USB writes must be serial, large, or async");
        if (mode == "async") require(syscall(SYS_io_setup, requests.size(), &context) == 0, "USB AIO setup");
    }
    VideoWriter(const VideoWriter&) = delete;
    VideoWriter& operator=(const VideoWriter&) = delete;
    ~VideoWriter() { destroy(); }
    void writeFrame(const deckusb::Header& header, const uint8_t* pixels, size_t size) {
        deckusb::validate(header);
        if (size != header.bytes) throw std::runtime_error("USB payload size disagrees with header");
        if (mode != "async") {
            writeAll(fd, &header, sizeof(header));
            writeAll(fd, pixels, size, mode == "large" ? 1024 * 1024 : deckusb::chunk);
            return;
        }
        size_t offset = 0, outstanding = 0;
        bool headerQueued = false;
        auto submit = [&](size_t slot) {
            if (headerQueued && offset == size) return;
            auto& request = requests[slot]; request = {};
            request.aio_data = slot; request.aio_fildes = fd;
            request.aio_lio_opcode = IOCB_CMD_PWRITE;
            request.aio_buf = reinterpret_cast<uintptr_t>(headerQueued ? pixels + offset : reinterpret_cast<const uint8_t*>(&header));
            request.aio_nbytes = headerQueued ? std::min(size - offset, size_t(deckusb::chunk)) : sizeof(header);
            iocb* batch = &request;
            long result;
            do { result = syscall(SYS_io_submit, context, 1L, &batch); } while (result < 0 && errno == EINTR);
            require(result == 1, "USB AIO submit");
            if (headerQueued) offset += request.aio_nbytes;
            headerQueued = true; active[slot] = true; ++outstanding;
        };
        try {
            for (size_t i = 0; i < requests.size(); ++i) submit(i);
            while (outstanding) {
                std::array<io_event, 3> events{};
                long count;
                do { count = syscall(SYS_io_getevents, context, 1L, 3L, events.data(), nullptr); }
                while (count < 0 && errno == EINTR);
                require(count > 0, "USB AIO completion");
                for (long i = 0; i < count; ++i) {
                    const auto& event = events[i];
                    if (event.data >= requests.size() || !active[event.data])
                        throw std::runtime_error("Invalid USB AIO completion");
                    auto& request = requests[event.data];
                    if (event.obj != reinterpret_cast<uintptr_t>(&request) || event.res2 ||
                        event.res != int64_t(request.aio_nbytes))
                        throw std::runtime_error("USB AIO write failed or was short");
                    active[event.data] = false; --outstanding;
                    submit(event.data);
                }
            }
        } catch (...) { destroy(); throw; }
    }
};
