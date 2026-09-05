#include "convert.hpp"
#include "protocol.hpp"
#include <cassert>
#include <cmath>
#include <iostream>

int main() {
    // Compare against independent floating-point BT.709 equations. Non-vector
    // widths and guard bytes catch SIMD-tail, row-order, and chroma bounds bugs.
    uint32_t random = 7;
    for (auto size : {std::array<unsigned, 2>{2, 2}, {18, 6}, {802, 500}, {1280, 800}, {1920, 1200}}) {
        size_t width = size[0], height = size[1], count = width * height * 3 / 2;
        std::vector<uint8_t> input(width * height * 4), output(count + 32, 0xa5);
        for (auto& byte : input) { random = random * 1664525 + 1013904223; byte = random >> 24; }
        deckusb::bgr0ToNV12(input.data(), output.data() + 16, width, height);
        for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
            auto p = input.data() + (y * width + x) * 4;
            double luma = .2126 * p[2] + .7152 * p[1] + .0722 * p[0];
            int expected = std::lround(16 + 219 * luma / 255);
            assert(std::abs(int(output[16 + y * width + x]) - expected) <= 1);
            if ((x | y) & 1) continue;
            double r = 0, g = 0, b = 0;
            for (size_t dy : {0u, 1u}) for (size_t dx : {0u, 1u}) {
                auto q = input.data() + ((y+dy)*width + x+dx)*4;
                r += q[2] / 4.0; g += q[1] / 4.0; b += q[0] / 4.0;
            }
            luma = .2126*r + .7152*g + .0722*b;
            int u = std::lround(128 + (b-luma) * 112 / (.9278*255));
            int v = std::lround(128 + (r-luma) * 112 / (.7874*255));
            size_t offset = 16 + width*height + y/2*width + x;
            assert(std::abs(int(output[offset])-u) <= 1);
            assert(std::abs(int(output[offset+1])-v) <= 1);
        }
        for (size_t i = 0; i < 16; ++i) assert(output[i] == 0xa5 && output[16+count+i] == 0xa5);
    }
    std::cout << "CPU conversion: BT.709 range, chroma, row bounds, and odd SIMD tails: PASS\n";
}
