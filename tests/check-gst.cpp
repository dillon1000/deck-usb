#include "capture-frame.hpp"
#include <cassert>
#include <iostream>

// Exercise actual GstVideoMeta mapping, including non-four-aligned widths,
// padding between rows/planes, and a nonzero first-plane offset.
int main() {
    gst_init(nullptr, nullptr);
    for (unsigned width : {2u, 18u, 802u, 1280u, 1920u}) for (bool padded : {false, true}) {
        unsigned height = 6;
        size_t bytes = deckusb::frameBytes(width, height, deckusb::nv12);
        gint strides[GST_VIDEO_MAX_PLANES] = {int(width + (padded ? 18 : 0)), int(width + (padded ? 26 : 0))};
        gsize offsets[GST_VIDEO_MAX_PLANES] = {padded ? 17u : 0u, 0};
        offsets[1] = offsets[0] + size_t(strides[0]) * height + (padded ? 11 : 0);
        size_t allocation = offsets[1] + size_t(strides[1]) * height / 2 + 16;
        auto buffer = gst_buffer_new_allocate(nullptr, allocation, nullptr);
        assert(buffer && gst_buffer_add_video_meta_full(buffer, GST_VIDEO_FRAME_FLAG_NONE,
            GST_VIDEO_FORMAT_NV12, width, height, 2, offsets, strides));
        GstMapInfo map{}; assert(gst_buffer_map(buffer, &map, GST_MAP_WRITE));
        memset(map.data, 0xa5, map.size);
        size_t index = 0;
        for (unsigned plane = 0; plane < 2; ++plane) for (unsigned row = 0; row < height / (plane ? 2 : 1); ++row)
            for (unsigned x = 0; x < width; ++x) map.data[offsets[plane] + row * strides[plane] + x] = index++ % 251;
        gst_buffer_unmap(buffer, &map);
        GstVideoInfo info{}; assert(gst_video_info_set_format(&info, GST_VIDEO_FORMAT_NV12, width, height));
        assert(gst_video_colorimetry_from_string(&info.colorimetry, "bt709"));
        GstVideoFrame frame{}; assert(gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ));
        std::vector<uint8_t> scratch;
        auto packed = deckusb::packedNV12(frame, scratch);
        for (size_t i = 0; i < bytes; ++i) assert(packed[i] == i % 251);
        assert(scratch.empty() == !padded);
        frame.info.colorimetry.range = GST_VIDEO_COLOR_RANGE_0_255;
        bool rejected = false;
        try { deckusb::packedNV12(frame, scratch); } catch (const std::exception&) { rejected = true; }
        assert(rejected);
        gst_video_frame_unmap(&frame); gst_buffer_unref(buffer);
    }
    std::cout << "GStreamer NV12: mapped strides, plane offsets, packed bytes, and color range: PASS\n";
}
