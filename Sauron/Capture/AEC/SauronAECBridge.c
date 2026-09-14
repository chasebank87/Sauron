#include "SauronAECBridge.h"

#include "speex/speex_echo.h"

#include <stdlib.h>

struct SauronAECEngine {
    SpeexEchoState *echo;
    int sample_rate;
    int frame_size;
    int tail_size;
};

SauronAECEngine *SauronAECEngineCreate(int sample_rate, int frame_size, int tail_size) {
    if (sample_rate < 8000 || frame_size < 40 || tail_size < frame_size) {
        return NULL;
    }
    SauronAECEngine *engine = calloc(1, sizeof(*engine));
    if (!engine) {
        return NULL;
    }
    engine->sample_rate = sample_rate;
    engine->frame_size = frame_size;
    engine->tail_size = tail_size;
    engine->echo = speex_echo_state_init(frame_size, tail_size);
    if (!engine->echo) {
        SauronAECEngineDestroy(engine);
        return NULL;
    }
    speex_echo_ctl(engine->echo, SPEEX_ECHO_SET_SAMPLING_RATE, &sample_rate);
    return engine;
}

void SauronAECEngineDestroy(SauronAECEngine *engine) {
    if (!engine) {
        return;
    }
    if (engine->echo) {
        speex_echo_state_destroy(engine->echo);
    }
    free(engine);
}

void SauronAECEngineReset(SauronAECEngine *engine) {
    if (!engine || !engine->echo) {
        return;
    }
    speex_echo_state_reset(engine->echo);
}

void SauronAECEngineCancel(
    SauronAECEngine *engine,
    const int16_t *near_end,
    const int16_t *far_end,
    int16_t *out
) {
    if (!engine || !engine->echo || !near_end || !far_end || !out) {
        return;
    }
    // MDF only. Speex's residual-echo preprocessor injects comfort noise that
    // showed up as loud static on the encoded mic track.
    speex_echo_cancellation(engine->echo, near_end, far_end, out);
}
