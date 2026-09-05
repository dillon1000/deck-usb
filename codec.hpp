#pragma once
#include "protocol.hpp"
#include <charconv>
#include <span>
#include <string_view>

namespace deckusb {
// FFmpeg's first tee output writes one framecrc record before the second output
// writes the corresponding Annex B access unit. Sizes avoid waiting for the next
// frame's start code. Reject malformed or oversized records before allocation.
inline uint32_t encodedPacketSize(std::string_view line) {
    if (line.empty() || line.size() >= 511 || line.back() != '\n')
        throw std::runtime_error("Truncated encoded packet record");
    if (line.front() == '#') return 0;
    std::array<int64_t, 6> fields{};
    for (unsigned i = 0; i < fields.size(); ++i) {
        size_t end = i == 5 ? line.size() : line.find(',');
        if (end == std::string_view::npos) throw std::runtime_error("Invalid packet fields");
        auto field = line.substr(0, end);
        while (!field.empty() && (field.front() == ' ' || field.front() == '\t')) field.remove_prefix(1);
        while (!field.empty() && (field.back() == ' ' || field.back() == '\n')) field.remove_suffix(1);
        if (i == 5) {
            if (!field.starts_with("0x")) throw std::runtime_error("Invalid packet checksum");
            field.remove_prefix(2);
        }
        auto result = std::from_chars(field.data(), field.data() + field.size(), fields[i], i == 5 ? 16 : 10);
        if (result.ec != std::errc{} || result.ptr != field.data() + field.size())
            throw std::runtime_error("Invalid packet number");
        line.remove_prefix(end + (i == 5 ? 0 : 1));
    }
    if (fields[0] != 0 || fields[3] < 0 || fields[4] <= 0 || fields[4] > maxEncodedBytes ||
        fields[5] < 0 || fields[5] > UINT32_MAX) throw std::runtime_error("Invalid packet bounds");
    return uint32_t(fields[4]);
}
// Views reference the caller's bounded packet. Independent IDR frames must carry
// SPS/PPS so any frame can start a new decoder after a drop or reconnect.
inline std::vector<std::span<const uint8_t>> splitH264(std::span<const uint8_t> bytes) {
    if (bytes.empty() || bytes.size() > maxEncodedBytes) throw std::runtime_error("Invalid H.264 packet size");
    auto prefix = [&](size_t p) -> size_t {
        if (p + 3 > bytes.size() || bytes[p] || bytes[p+1]) return 0;
        if (bytes[p+2] == 1) return 3;
        return p + 4 <= bytes.size() && !bytes[p+2] && bytes[p+3] == 1 ? 4 : 0;
    };
    std::vector<std::span<const uint8_t>> units;
    bool idr = false, sps = false, pps = false;
    size_t p = 0;
    while (p < bytes.size()) {
        size_t start = prefix(p);
        if (!start) throw std::runtime_error("Missing H.264 start code");
        p += start; size_t end = p;
        while (end < bytes.size() && !prefix(end)) ++end;
        size_t length = end - p;
        while (length && !bytes[p + length - 1]) --length;
        if (!length || units.size() >= 256 || (bytes[p] & 0x80)) throw std::runtime_error("Invalid H.264 NAL unit");
        unsigned type = bytes[p] & 31;
        if (type == 5) idr = true;
        else if (type == 7) sps = true;
        else if (type == 8) pps = true;
        else if (type != 6 && type != 9 && type != 12) throw std::runtime_error("Dependent H.264 frame rejected");
        units.push_back(bytes.subspan(p, length)); p = end;
    }
    if (!idr || !sps || !pps) throw std::runtime_error("H.264 frame must contain IDR, SPS, and PPS");
    return units;
}
}
