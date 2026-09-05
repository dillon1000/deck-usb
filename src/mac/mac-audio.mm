#include "mac.hpp"

void AudioOutput::check(OSStatus result) {
    if (result) throw std::runtime_error("Core Audio error " + std::to_string(result));
}
// Device-rate conversion is native. This callback copies bounded PCM under a
// short lock; USB and display work never runs inside the audio callback.
OSStatus AudioOutput::render(void* context, AudioUnitRenderActionFlags*, const AudioTimeStamp*,
                       UInt32, UInt32 frames, AudioBufferList* output) {
    if (!output || output->mNumberBuffers != 1 || !output->mBuffers[0].mData ||
        output->mBuffers[0].mDataByteSize / 4 < frames) return kAudio_ParamError;
    auto& self = *static_cast<AudioOutput*>(context);
    std::lock_guard lock(self.mutex);
    self.buffer.pop(static_cast<int16_t*>(output->mBuffers[0].mData), size_t(frames) * audioChannels);
    if (mutingAudio) memset(output->mBuffers[0].mData, 0, frames * 4);
    output->mBuffers[0].mDataByteSize = frames * 4; ++self.callbacks;
    return noErr;
}
AudioOutput::AudioOutput(double minimum) : buffer(minimum) {
    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_DefaultOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    auto component = AudioComponentFindNext(nullptr, &description);
    if (!component) throw std::runtime_error("Core Audio output is unavailable");
    check(AudioComponentInstanceNew(component, &unit));
    try {
        AudioStreamBasicDescription format{};
        format.mSampleRate = audioRate; format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        format.mBytesPerPacket = format.mBytesPerFrame = 4; format.mFramesPerPacket = 1;
        format.mChannelsPerFrame = audioChannels; format.mBitsPerChannel = 16;
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)));
        AURenderCallbackStruct callback{render, this};
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)));
        check(AudioUnitInitialize(unit)); check(AudioOutputUnitStart(unit));
    } catch (...) { AudioComponentInstanceDispose(unit); throw; }
}
AudioOutput::~AudioOutput() { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); }
void AudioOutput::receive(const AudioPacket& packet) {
    std::lock_guard lock(mutex); buffer.push(packet); ++packets;
    if (std::any_of(packet.samples.begin(), packet.samples.end(), [](int16_t s) { return s != 0; })) ++nonzero;
}
std::string AudioOutput::stats() {
    std::lock_guard lock(mutex);
    return "audio " + std::to_string(buffer.size() / (audioChannels * 48)) + " ms, " +
        std::to_string(nonzero) + " signal packets, " + std::to_string(buffer.underruns) + " gaps, " + std::to_string(buffer.trims) + " trims, target " + std::to_string(int(buffer.targetMilliseconds())) +
        " ms, correction " + std::to_string(int(buffer.correctionPPM())) + " ppm";
}
double AudioOutput::bufferedMilliseconds() {
    std::lock_guard lock(mutex); return buffer.size() / double(audioChannels * 48);
}
double AudioOutput::targetMilliseconds() { std::lock_guard lock(mutex); return buffer.targetMilliseconds(); }
void AudioOutput::setMinimumMilliseconds(double minimum) { std::lock_guard lock(mutex); buffer.setMinimumMilliseconds(minimum); }
uint64_t AudioOutput::underruns() { std::lock_guard lock(mutex); return buffer.underruns; }
void AudioOutput::report() {
    std::lock_guard lock(mutex);
    fprintf(stderr, "Audio: %llu packets, %llu nonzero, %llu output callbacks, %llu underruns, %llu trims, target %.0f ms, correction %.0f ppm\n",
        (unsigned long long)packets, (unsigned long long)nonzero, (unsigned long long)callbacks,
        (unsigned long long)buffer.underruns, (unsigned long long)buffer.trims, buffer.targetMilliseconds(), buffer.correctionPPM());
}
