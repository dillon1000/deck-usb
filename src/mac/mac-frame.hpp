#pragma once
#include "frame.hpp"
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <memory>

namespace deckusb {
template<class T> using CFHandle = std::unique_ptr<std::remove_pointer_t<T>, decltype(&CFRelease)>;
// Raw frames retain their CPU pixels. Decoded frames instead retain the native
// image and its Metal plane wrappers until the GPU completion handler releases
// this object. Retaining only the MTLTexture does not retain its Core Video owner.
struct DisplayFrame : Frame {
    CFHandle<CVImageBufferRef> surface{nullptr, CFRelease};
    CFHandle<CVMetalTextureRef> luma{nullptr, CFRelease}, chroma{nullptr, CFRelease};
    explicit DisplayFrame(Frame&& frame) : Frame(std::move(frame)) {}
};
}
