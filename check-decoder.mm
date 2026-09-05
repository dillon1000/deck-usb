#include "mac-decoder.hpp"
#include <cassert>
#include <fstream>
#include <iostream>
using namespace deckusb;
// Hardware integration check: pass an Annex B file, dimensions, and the sizes
// printed by FFmpeg's framecrc tee. No app window or USB session is needed.
int main(int argc, char** argv) { @autoreleasepool { try {
    if (argc < 5) throw std::runtime_error("Usage: check-decoder FILE WIDTH HEIGHT SIZE...");
    std::ifstream input(argv[1], std::ios::binary); H264Decoder decoder;
    for (int i = 4; i < argc; ++i) {
        auto frame = std::make_shared<Frame>();
        frame->header.width = std::stoul(argv[2]); frame->header.height = std::stoul(argv[3]);
        frame->header.format = h264; frame->header.bytes = std::stoul(argv[i]); validate(frame->header);
        frame->pixels.resize(frame->header.bytes);
        if (!input.read(reinterpret_cast<char*>(frame->pixels.data()), frame->pixels.size())) throw std::runtime_error("Truncated fixture");
        frame = decoder.decode(frame);
        assert(frame->header.format == nv12 && frame->pixels.size() == frameBytes(frame->header.width, frame->header.height, nv12));
        std::cout << "Hardware decode: " << frame->decodeMs << " ms\n";
    }
    return 0;
} catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; } } }
