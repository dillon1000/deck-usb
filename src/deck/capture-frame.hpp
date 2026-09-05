#pragma once
#include "protocol.hpp"
#include <gst/video/video.h>
#include <cstring>

namespace deckusb {
// Map metadata, not an assumed width-to-stride rule. Common contiguous frames
// return their mapped pixels directly; padded/separate planes use one reusable
// packed buffer. The caller keeps the GstVideoFrame mapped through the write.
inline const uint8_t* packedNV12(const GstVideoFrame& frame, std::vector<uint8_t>& scratch) {
    auto& info = frame.info;
    size_t size = frameBytes(info.width, info.height, nv12);
    if (GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_NV12 ||
        info.colorimetry.range != GST_VIDEO_COLOR_RANGE_16_235 ||
        info.colorimetry.matrix != GST_VIDEO_COLOR_MATRIX_BT709)
        throw std::runtime_error("Capture must provide limited-range BT.709 NV12");
    auto y = static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0));
    auto uv = static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 1));
    int yStride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0), uvStride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 1);
    if (!y || !uv || yStride < info.width || uvStride < info.width)
        throw std::runtime_error("Unsupported capture plane layout");
    if (yStride == info.width && uvStride == info.width && uv == y + size_t(info.width) * info.height) return y;
    scratch.resize(size);
    for (int row = 0; row < info.height; ++row)
        memcpy(scratch.data() + size_t(row) * info.width, y + size_t(row) * yStride, info.width);
    for (int row = 0; row < info.height / 2; ++row)
        memcpy(scratch.data() + size_t(info.width) * info.height + size_t(row) * info.width,
            uv + size_t(row) * uvStride, info.width);
    return scratch.data();
}
}
