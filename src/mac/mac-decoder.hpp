#pragma once
#import <VideoToolbox/VideoToolbox.h>
#include "codec.hpp"
#include "mac-frame.hpp"

namespace deckusb {
// One decoder per USB session, used only by its video reader. Decode synchronously
// with no temporal processing, then release the sample before reading another.
// Hardware is required: a silent software fallback would change the latency cost.
class H264Decoder {
    CFHandle<CMVideoFormatDescriptionRef> description{nullptr, CFRelease};
    CFHandle<VTDecompressionSessionRef> session{nullptr, CFRelease};
    CFHandle<CVMetalTextureCacheRef> textureCache{nullptr, CFRelease};
    id<MTLDevice> device;
    std::vector<uint8_t> sps, pps;
    static void check(OSStatus status, const char* operation) {
        if (status) throw std::runtime_error(std::string(operation) + ": " + std::to_string(status));
    }
public:
    explicit H264Decoder(id<MTLDevice> gpu = MTLCreateSystemDefaultDevice()) : device(gpu) {}
    ~H264Decoder() { if (session) VTDecompressionSessionInvalidate(session.get()); }
    std::shared_ptr<DisplayFrame> decode(std::shared_ptr<Frame> frame) {
        if (frame->header.format != h264) return std::make_shared<DisplayFrame>(std::move(*frame));
        uint64_t started = nowNs();
        if (!textureCache) {
            CVMetalTextureCacheRef cache = nullptr;
            check(CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &cache), "Metal image cache");
            textureCache.reset(cache);
        }
        auto units = splitH264(frame->pixels);
        std::vector<uint8_t> nextSPS, nextPPS, avcc;
        for (auto unit : units) {
            unsigned type = unit[0] & 31;
            if (type == 7) nextSPS.assign(unit.begin(), unit.end());
            else if (type == 8) nextPPS.assign(unit.begin(), unit.end());
            // AVCC stores each NAL with a big-endian length instead of a start code.
            uint32_t length = uint32_t(unit.size());
            for (int shift : {24, 16, 8, 0}) avcc.push_back(uint8_t(length >> shift));
            avcc.insert(avcc.end(), unit.begin(), unit.end());
        }
        if (!session || nextSPS != sps || nextPPS != pps) {
            if (session) VTDecompressionSessionInvalidate(session.get());
            session.reset(); description.reset();
            const uint8_t* parameters[]{nextSPS.data(), nextPPS.data()};
            size_t lengths[]{nextSPS.size(), nextPPS.size()};
            CMVideoFormatDescriptionRef format = nullptr;
            check(CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2,
                parameters, lengths, 4, &format), "H.264 format");
            description.reset(format);
            auto dimensions = CMVideoFormatDescriptionGetDimensions(format);
            if (dimensions.width != int(frame->header.width) || dimensions.height != int(frame->header.height))
                throw std::runtime_error("H.264 dimensions disagree with USB header");
            NSDictionary* hardware = @{(__bridge NSString*)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES};
            NSDictionary* attributes = @{
                (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
                (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}};
            VTDecompressionSessionRef decoder = nullptr;
            check(VTDecompressionSessionCreate(kCFAllocatorDefault, format, (__bridge CFDictionaryRef)hardware,
                (__bridge CFDictionaryRef)attributes, nullptr, &decoder), "Hardware H.264 decoder");
            session.reset(decoder);
            check(VTSessionSetProperty(decoder, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue), "Real-time decoding");
            sps.swap(nextSPS); pps.swap(nextPPS);
        }
        CMBlockBufferRef rawBlock = nullptr;
        check(CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, avcc.data(), avcc.size(),
            kCFAllocatorNull, nullptr, 0, avcc.size(), 0, &rawBlock), "H.264 block");
        CFHandle<CMBlockBufferRef> block(rawBlock, CFRelease);
        size_t length = avcc.size();
        CMSampleBufferRef rawSample = nullptr;
        check(CMSampleBufferCreateReady(kCFAllocatorDefault, block.get(), description.get(), 1,
            0, nullptr, 1, &length, &rawSample), "H.264 sample");
        CFHandle<CMSampleBufferRef> sample(rawSample, CFRelease);
        __block CVImageBufferRef image = nullptr;
        __block OSStatus decoded = noErr;
        // With both asynchronous and temporal flags clear, Apple guarantees this
        // callback finishes before DecodeFrame returns. avcc therefore stays alive.
        OSStatus result = VTDecompressionSessionDecodeFrameWithOutputHandler(session.get(), sample.get(), 0, nullptr,
            ^(OSStatus status, VTDecodeInfoFlags, CVImageBufferRef output, CMTime, CMTime) {
                decoded = status; if (output) image = CVPixelBufferRetain(output);
            });
        CFHandle<CVImageBufferRef> surface(image, CFRelease);
        check(result, "H.264 decode"); check(decoded, "H.264 output");
        if (!image || CVPixelBufferGetWidth(image) != frame->header.width || CVPixelBufferGetHeight(image) != frame->header.height ||
            CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || CVPixelBufferGetPlaneCount(image) != 2)
            throw std::runtime_error("Invalid decoded H.264 image");
        auto output = std::make_shared<DisplayFrame>(std::move(*frame));
        output->surface = std::move(surface);
        output->header.format = nv12;
        output->header.bytes = frameBytes(output->header.width, output->header.height, nv12);
        output->pixels.clear(); // The GPU reads the retained IOSurface, not this packet.
        for (unsigned plane = 0; plane < 2; ++plane) {
            CVMetalTextureRef texture = nullptr;
            CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                textureCache.get(), image, nullptr, plane ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm,
                output->header.width / (plane ? 2 : 1), output->header.height / (plane ? 2 : 1), plane, &texture);
            (plane ? output->chroma : output->luma).reset(texture);
            check(status, "Map decoded Metal plane");
            if (!texture || !CVMetalTextureGetTexture(texture)) throw std::runtime_error("Missing decoded Metal plane");
        }
        output->decodeMs = (nowNs() - started) / 1e6;
        return output;
    }
};
}
