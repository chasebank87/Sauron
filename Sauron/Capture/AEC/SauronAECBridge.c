#include "SauronAECBridge.h"

#include "speex/speex_echo.h"
#include "speex/speex_preprocess.h"

#include <stdlib.h>
#include <string.h>

struct SauronAECEngine {
    SpeexEchoState *echo;
    SpeexPreprocessState *preprocess;
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
    engine->preprocess = speex_preprocess_state_init(frame_size, sample_rate);
    if (!engine->echo || !engine->preprocess) {
        SauronAECEngineDestroy(engine);
        return NULL;
    }
    speex_echo_ctl(engine->echo, SPEEX_ECHO_SET_SAMPLING_RATE, &sample_rate);
    speex_preprocess_ctl(engine->preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE, engine->echo);

    int off = 0;
    speex_preprocess_ctl(engine->preprocess, SPEEX_PREPROCESS_SET_DENOISE, &off);
    speex_preprocess_ctl(engine->preprocess, SPEEX_PREPROCESS_SET_AGC, &off);
    speex_preprocess_ctl(engine->preprocess, SPEEX_PREPROCESS_SET_DEREVERB, &off);

    int echo_suppress = -40;
    int echo_suppress_active = -15;
    speex_preprocess_ctl(engine->preprocess, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &echo_suppress);
    speex_preprocess_ctl(
        engine->preprocess,
        SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE,
        &echo_suppress_active
    );
    return engine;
}

void SauronAECEngineDestroy(SauronAECEngine *engine) {
    if (!engine) {
        return;
    }
    if (engine->preprocess) {
        speex_preprocess_state_destroy(engine->preprocess);
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
    speex_echo_cancellation(engine->echo, near_end, far_end, out);
    if (engine->preprocess) {
        speex_preprocess_run(engine->preprocess, out);
    }
}
