#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// SpeexDSP MDF echo canceller + residual-echo preprocessor, 16-bit frames.
typedef struct SauronAECEngine SauronAECEngine;

SauronAECEngine *SauronAECEngineCreate(int sample_rate, int frame_size, int tail_size);
void SauronAECEngineDestroy(SauronAECEngine *engine);
void SauronAECEngineReset(SauronAECEngine *engine);

/// Cancels `frame_size` samples. `near_end` / `far_end` / `out` must not be NULL.
void SauronAECEngineCancel(
    SauronAECEngine *engine,
    const int16_t *near_end,
    const int16_t *far_end,
    int16_t *out
);

#ifdef __cplusplus
}
#endif
