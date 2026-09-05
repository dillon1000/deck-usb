#include "mac-decoder.hpp"
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
using namespace deckusb;
// Compare GPU reads of both mapped planes with the decoder's pixels. Keeping
// frames until after decoder destruction checks their independent ownership.
static void verifyPlanes(const DisplayFrame& frame, id<MTLCommandQueue> queue) {
    for (unsigned plane = 0; plane < 2; ++plane) {
        auto texture = CVMetalTextureGetTexture((plane ? frame.chroma : frame.luma).get());
        assert(texture.width == frame.header.width / (plane ? 2 : 1));
        assert(texture.height == frame.header.height / (plane ? 2 : 1));
        size_t stride = (frame.header.width + 255) & ~size_t(255);
        auto buffer = [queue.device newBufferWithLength:stride * texture.height options:MTLResourceStorageModeShared];
        auto command = [queue commandBuffer]; auto blit = [command blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(texture.width,texture.height,1) toBuffer:buffer destinationOffset:0
            destinationBytesPerRow:stride destinationBytesPerImage:stride * texture.height];
        [blit endEncoding]; [command commit]; [command waitUntilCompleted];
        assert(command.status == MTLCommandBufferStatusCompleted);
        auto image = frame.surface.get();
        assert(CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
        auto expected = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(image, plane));
        auto actual = static_cast<const uint8_t*>(buffer.contents);
        for (size_t y = 0; y < texture.height; ++y)
            assert(!memcmp(actual + y * stride, expected + y * CVPixelBufferGetBytesPerRowOfPlane(image, plane), frame.header.width));
        assert(CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
    }
}
// Pass an Annex B file, dimensions, and the sizes printed by FFmpeg framecrc.
int main(int argc, char** argv) { @autoreleasepool { try {
    if (argc < 5) throw std::runtime_error("Usage: check-decoder FILE WIDTH HEIGHT SIZE...");
    std::ifstream input(argv[1], std::ios::binary);
    std::vector<std::shared_ptr<DisplayFrame>> retained;
    {
        H264Decoder decoder;
        auto raw = std::make_shared<Frame>(); raw->pixels = {16, 128};
        auto unchanged = decoder.decode(raw);
        assert(!unchanged->surface && unchanged->pixels == std::vector<uint8_t>({16,128}));
        for (int i = 4; i < argc; ++i) {
            auto frame = std::make_shared<Frame>();
            frame->header.width = std::stoul(argv[2]); frame->header.height = std::stoul(argv[3]);
            frame->header.format = h264; frame->header.bytes = std::stoul(argv[i]); validate(frame->header);
            frame->pixels.resize(frame->header.bytes);
            if (!input.read(reinterpret_cast<char*>(frame->pixels.data()), frame->pixels.size())) throw std::runtime_error("Truncated fixture");
            auto output = decoder.decode(frame);
            assert(output->header.format == nv12 && output->pixels.empty() && output->surface);
            std::cout << "Hardware decode and texture mapping: " << output->decodeMs << " ms\n";
            retained.push_back(std::move(output));
        }
    }
    auto queue = [MTLCreateSystemDefaultDevice() newCommandQueue];
    for (const auto& frame : retained) verifyPlanes(*frame, queue);
    std::cout << "GPU plane contents and retained lifetime: PASS\n";
    return 0;
} catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; } } }
