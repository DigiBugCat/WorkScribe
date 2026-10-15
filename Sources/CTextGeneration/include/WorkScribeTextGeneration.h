#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Loads on demand and releases model/context before returning. No sockets.
int ws_generate_title(const char *model_path, const char *prompt,
                      char *output, size_t output_size, char *error, size_t error_size);
// Multi-line generation for note enhancement: stops at end-of-generation, `stop`
// (may be NULL), or `max_tokens`. Same on-demand load and release as titles.
int ws_generate_text(const char *model_path, const char *prompt, int context_size, int max_tokens, const char *stop,
                     char *output, size_t output_size, char *error, size_t error_size);
// Streaming variant for Ask: calls `on_piece` with each decoded piece as it is generated. Returning nonzero from the
// callback stops generation early (cancelled). Same on-demand load and release.
typedef int (*ws_piece_callback)(const char *piece, void *context);
int ws_generate_text_stream(const char *model_path, const char *prompt, int context_size, int max_tokens, const char *stop,
                            ws_piece_callback on_piece, void *context, char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
