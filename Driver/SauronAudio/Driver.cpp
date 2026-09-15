// Sauron Audio — virtual loopback AudioServerPlugIn (libASPL).
// Meeting apps write to the output stream; Sauron reads the input stream.

#include <aspl/Driver.hpp>

#include "RingBuffer.hpp"

#include <CoreAudio/AudioServerPlugIn.h>

#include <memory>

namespace {

constexpr UInt32 kSampleRate = 48000;
constexpr UInt32 kChannelCount = 2;
// ~2 seconds of stereo float at 48 kHz.
constexpr size_t kRingCapacityFloats = static_cast<size_t>(kSampleRate) * kChannelCount * 2;

constexpr const char* kDeviceName = "Sauron Audio";
constexpr const char* kManufacturer = "Sauron";
constexpr const char* kDeviceUID = "app.sauron.audio.SauronAudio";
constexpr const char* kModelUID = "app.sauron.audio.model";

class LoopbackHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    OSStatus OnStartIO() override
    {
        ring_.reset();
        return kAudioHardwareNoError;
    }

    void OnStopIO() override { ring_.reset(); }

    void OnWriteMixedOutput(
        const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64,
        const void* bytes,
        UInt32 bytesCount
    ) override
    {
        if (bytes == nullptr || bytesCount == 0) {
            return;
        }
        const auto* samples = static_cast<const float*>(bytes);
        ring_.write(samples, bytesCount / sizeof(float));
    }

    void OnReadClientInput(
        const std::shared_ptr<aspl::Client>&,
        const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64,
        void* bytes,
        UInt32 bytesCount
    ) override
    {
        if (bytes == nullptr || bytesCount == 0) {
            return;
        }
        auto* samples = static_cast<float*>(bytes);
        ring_.read(samples, bytesCount / sizeof(float));
    }

private:
    LoopbackRingBuffer ring_{kRingCapacityFloats};
};

std::shared_ptr<aspl::Driver> CreateSauronAudioDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = kDeviceName;
    deviceParams.Manufacturer = kManufacturer;
    deviceParams.DeviceUID = kDeviceUID;
    deviceParams.ModelUID = kModelUID;
    deviceParams.SampleRate = kSampleRate;
    deviceParams.ChannelCount = kChannelCount;
    deviceParams.EnableMixing = true;
    deviceParams.CanBeDefault = true;
    deviceParams.CanBeDefaultForSystemSounds = false;
    deviceParams.ConfigurationApplicationBundleID = "app.sauron.Sauron";

    auto device = std::make_shared<aspl::Device>(context, deviceParams);
    device->AddStreamWithControlsAsync(aspl::Direction::Output);
    device->AddStreamWithControlsAsync(aspl::Direction::Input);

    auto handler = std::make_shared<LoopbackHandler>();
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* SauronAudioEntryPoint(CFAllocatorRef, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static std::shared_ptr<aspl::Driver> driver = CreateSauronAudioDriver();
    return driver->GetReference();
}
