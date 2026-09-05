#include "capture-frame.hpp"
#include "deck-io.hpp"
#include <gst/app/gstappsink.h>
#include <charconv>
#include <csignal>
#include <cstdio>
#include <memory>
#include <string_view>

static volatile std::sig_atomic_t stopping = 0;
struct Pipeline {
    GstElement* root = nullptr;
    GstAppSink* sink = nullptr;
    GstBus* bus = nullptr;
    ~Pipeline() {
        if (root) gst_element_set_state(root, GST_STATE_NULL);
        if (sink) gst_object_unref(sink);
        if (bus) gst_object_unref(bus);
        if (root) gst_object_unref(root);
    }
};
struct MappedFrame {
    GstVideoFrame frame{};
    bool mapped = false;
    ~MappedFrame() { if (mapped) gst_video_frame_unmap(&frame); }
};

// Capture as the desktop user in one GStreamer process. Return 75 only before
// emitting any pixels so the launcher can safely fall back. Once output begins,
// an error ends the stream and lets the existing supervisor restore framing.
int main(int argc, char** argv) {
    bool emitted = false;
    try {
        if (argc != 5 && argc != 6) throw std::runtime_error("Usage: deck-pipewire NODE|--test WIDTH HEIGHT FPS [FRAMES]");
        auto number = [](std::string_view text) {
            unsigned value = 0;
            auto result = std::from_chars(text.data(), text.data() + text.size(), value);
            if (result.ec != std::errc{} || result.ptr != text.data() + text.size() || !value)
                throw std::runtime_error("Invalid capture number");
            return value;
        };
        bool testing = std::string_view(argv[1]) == "--test";
        unsigned node = testing ? 0 : number(argv[1]);
        unsigned width = number(argv[2]), height = number(argv[3]), fps = number(argv[4]);
        unsigned limit = argc == 6 ? number(argv[5]) : 0;
        size_t bytes = deckusb::frameBytes(width, height, deckusb::nv12);
        if (fps > 240) throw std::runtime_error("Capture rate exceeds 240 fps");
        gst_init(nullptr, nullptr);
        Pipeline pipeline;
        // Drop before scaling/conversion; a slow USB writer keeps only one
        // pending appsink sample instead of accumulating old game frames.
        std::string source = testing ? "videotestsrc is-live=true pattern=black" :
            "pipewiresrc target-object=" + std::to_string(node) + " do-timestamp=true min-buffers=2 max-buffers=3";
        std::string graph = source + " ! video/x-raw,format=BGRx"
            " ! queue leaky=downstream max-size-buffers=1 max-size-bytes=0 max-size-time=0"
            " ! videorate drop-only=true ! video/x-raw,framerate=" + std::to_string(fps) + "/1"
            " ! videoscale add-borders=false ! video/x-raw,width=" + std::to_string(width) + ",height=" + std::to_string(height) +
            " ! videoconvert ! video/x-raw,format=NV12,colorimetry=bt709,chroma-site=mpeg2"
            " ! appsink name=frames sync=false max-buffers=1 drop=true enable-last-sample=false wait-on-eos=false";
        GError* error = nullptr;
        pipeline.root = gst_parse_launch(graph.c_str(), &error);
        if (error) {
            std::string message = error->message; g_error_free(error); throw std::runtime_error(message);
        }
        if (!pipeline.root) throw std::runtime_error("Could not create capture pipeline");
        pipeline.sink = GST_APP_SINK(gst_bin_get_by_name(GST_BIN(pipeline.root), "frames"));
        pipeline.bus = gst_element_get_bus(pipeline.root);
        if (!pipeline.sink || gst_element_set_state(pipeline.root, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE)
            throw std::runtime_error("Could not start capture pipeline");
        for (int signal : {SIGINT, SIGTERM, SIGHUP}) std::signal(signal, [](int) { stopping = 1; });
        std::vector<uint8_t> packed;
        auto lastFrame = deckusb::nowNs();
        for (unsigned count = 0; !stopping && (!limit || count < limit);) {
            std::unique_ptr<GstSample, decltype(&gst_sample_unref)> sample(
                gst_app_sink_try_pull_sample(pipeline.sink, 100 * GST_MSECOND), gst_sample_unref);
            if (!sample) {
                GstMessage* message = gst_bus_pop_filtered(pipeline.bus, GstMessageType(GST_MESSAGE_ERROR | GST_MESSAGE_EOS));
                if (message) {
                    std::string text = "Capture ended";
                    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
                        GError* failure = nullptr; gst_message_parse_error(message, &failure, nullptr);
                        if (failure) { text = failure->message; g_error_free(failure); }
                    }
                    gst_message_unref(message); throw std::runtime_error(text);
                }
                if (deckusb::nowNs() - lastFrame > 5000000000ULL) throw std::runtime_error("Capture produced no frame for five seconds");
                continue;
            }
            GstVideoInfo info{};
            if (!gst_video_info_from_caps(&info, gst_sample_get_caps(sample.get())) ||
                info.width != int(width) || info.height != int(height))
                throw std::runtime_error("Capture dimensions changed");
            MappedFrame mapped;
            mapped.mapped = gst_video_frame_map(&mapped.frame, &info, gst_sample_get_buffer(sample.get()), GST_MAP_READ);
            if (!mapped.mapped) throw std::runtime_error("Could not map capture frame");
            auto pixels = deckusb::packedNV12(mapped.frame, packed);
            emitted = true; // Even a partial pipe write prohibits fallback.
            writeAll(STDOUT_FILENO, pixels, bytes, 1024 * 1024);
            lastFrame = deckusb::nowNs(); ++count;
        }
        return 0;
    } catch (const std::exception& error) {
        fprintf(stderr, "DeckUSB PipeWire capture: %s\n", error.what());
        return emitted ? 1 : 75;
    }
}
