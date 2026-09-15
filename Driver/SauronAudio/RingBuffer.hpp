#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <vector>

/// Lock-free-ish SPSC float ring for AudioServerPlugIn loopback.
/// Writers (meeting-app output) and readers (Sauron input) may run concurrently.
/// Underruns fill with silence; overruns drop oldest samples.
class LoopbackRingBuffer {
public:
    explicit LoopbackRingBuffer(size_t capacityFloats)
        : capacity_(std::max<size_t>(capacityFloats, 1024))
        , data_(capacity_, 0.0f)
    {
    }

    void reset()
    {
        writeIndex_.store(0, std::memory_order_relaxed);
        readIndex_.store(0, std::memory_order_relaxed);
        std::fill(data_.begin(), data_.end(), 0.0f);
    }

    void write(const float* samples, size_t count)
    {
        if (samples == nullptr || count == 0) {
            return;
        }
        size_t writeIndex = writeIndex_.load(std::memory_order_relaxed);
        size_t readIndex = readIndex_.load(std::memory_order_acquire);
        size_t available = capacity_ - (writeIndex - readIndex);
        if (count > available) {
            // Drop oldest so newest meeting audio wins.
            readIndex += (count - available);
            readIndex_.store(readIndex, std::memory_order_release);
        }
        for (size_t i = 0; i < count; ++i) {
            data_[(writeIndex + i) % capacity_] = samples[i];
        }
        writeIndex_.store(writeIndex + count, std::memory_order_release);
    }

    void read(float* samples, size_t count)
    {
        if (samples == nullptr || count == 0) {
            return;
        }
        size_t readIndex = readIndex_.load(std::memory_order_relaxed);
        size_t writeIndex = writeIndex_.load(std::memory_order_acquire);
        size_t available = writeIndex - readIndex;
        size_t fromBuffer = std::min(available, count);
        for (size_t i = 0; i < fromBuffer; ++i) {
            samples[i] = data_[(readIndex + i) % capacity_];
        }
        if (fromBuffer < count) {
            std::memset(samples + fromBuffer, 0, (count - fromBuffer) * sizeof(float));
        }
        readIndex_.store(readIndex + fromBuffer, std::memory_order_release);
    }

private:
    const size_t capacity_;
    std::vector<float> data_;
    std::atomic<size_t> writeIndex_{0};
    std::atomic<size_t> readIndex_{0};
};
