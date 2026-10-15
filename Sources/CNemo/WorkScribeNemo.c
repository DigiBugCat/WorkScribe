#include "WorkScribeNemo.h"
#include <sys/stat.h>
#include <stdlib.h>

static int materialized(const char *path) {
    struct stat info;
    return path && stat(path, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 && !(info.st_flags & SF_DATALESS);
}

nemo_speech_asr_status ws_engine_create(const char *asr_path, const char *diar_path, nemo_speech_asr_recognizer **out) {
    if (!materialized(asr_path) || !materialized(diar_path)) return NEMO_SPEECH_ASR_ERROR_INVALID_ARGUMENT;
    nemo_speech_asr_backend_config backend = {0};
    backend.size = sizeof(backend); backend.gpu = getenv("WORKSCRIBE_SPEECH_CPU") ? -1 : 0;
    nemo_speech_asr_model_config model = {0};
    model.size = sizeof(model); model.path = asr_path;
    nemo_speech_asr_endpointing_config endpoint = {0};
    // Leave time for delayed word emission before committing an utterance. Diagnostic
    // overrides let the replay measure the shipping policy against upstream defaults.
    const char *eou = getenv("WORKSCRIBE_ASR_ENDPOINT_MS");
    endpoint.size = sizeof(endpoint); endpoint.stop_history_eou_ms = eou ? atoi(eou) : 1600;
    endpoint.enable = endpoint.stop_history_eou_ms > 0;
    nemo_speech_asr_streaming_config streaming = {0};
    streaming.size = sizeof(streaming); streaming.chunk_size = .16f;
    streaming.ctc_left_padding = 1.92f; streaming.ctc_right_padding = 1.92f;
    const char *right_context = getenv("WORKSCRIBE_ASR_RIGHT_CONTEXT");
    streaming.rnnt_right_context = right_context ? atoi(right_context) : -1;
    nemo_speech_asr_diar_config diar = {0};
    diar.size = sizeof(diar); diar.model_path = diar_path;
    diar.chunk_frames = 9; diar.right_context_frames = 4; diar.left_context_frames = -1;
    diar.fifo_frames = 264; diar.spkcache_frames = 264; diar.update_period_frames = 222;
    nemo_speech_asr_batching_config batching = {0};
    batching.size = sizeof(batching); batching.enable = false;
    nemo_speech_asr_recognizer_config config = {0};
    config.size = sizeof(config); config.backend = &backend; config.model = &model;
    config.endpointing = &endpoint; config.diar = &diar; config.batching = &batching; config.streaming = &streaming;
    return nemo_speech_asr_create(&config, out);
}

nemo_speech_asr_status ws_stream_create(nemo_speech_asr_recognizer *recognizer, nemo_speech_asr_stream **out) {
    nemo_speech_asr_recognition_options options = nemo_speech_asr_recognition_options_default();
    options.language_code = "en-US"; options.interim_results = true;
    options.enable_word_time_offsets = true; options.enable_speaker_diarization = true;
    options.enable_automatic_punctuation = true;
    return nemo_speech_asr_streaming_recognize(recognizer, &options, out);
}
