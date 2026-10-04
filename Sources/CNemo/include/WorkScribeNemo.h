#pragma once
#include "asr.h"

nemo_speech_asr_status ws_engine_create(const char *asr_path, const char *diar_path, nemo_speech_asr_recognizer **out);
nemo_speech_asr_status ws_stream_create(nemo_speech_asr_recognizer *recognizer, nemo_speech_asr_stream **out);
