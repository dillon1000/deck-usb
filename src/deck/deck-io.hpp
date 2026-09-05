#pragma once
#include "protocol.hpp"
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
using namespace deckusb;

inline void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(std::string(message) + ": " + strerror(errno));
}
inline int openFd(const std::string& path, int flags) {
    int fd = open(path.c_str(), flags | O_CLOEXEC);
    require(fd >= 0, path.c_str());
    return fd;
}
// Endpoints carry exact protocol records. Any error ends the session; never try
// to resynchronize inside raw pixel data after a partial transfer.
inline void writeAll(int fd, const void* data, size_t size, size_t requestBytes = chunk) {
    auto p = static_cast<const uint8_t*>(data);
    while (size) {
        ssize_t n = write(fd, p, std::min(size, requestBytes));
        if (n < 0 && errno == EINTR) continue;
        require(n > 0, "USB write"); p += n; size -= n;
    }
}
inline bool readAll(int fd, void* data, size_t size) {
    auto p = static_cast<uint8_t*>(data);
    while (size) {
        ssize_t n = read(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        require(n >= 0, "Read");
        if (!n) return false;
        p += n; size -= n;
    }
    return true;
}
