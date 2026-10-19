#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/// Called with each decoded piece (complete UTF-8 only). Returning nonzero stops generation (cancelled).
typedef int (*ws_piece_callback)(const char *piece, void *context);
/// Polled before prefill, between prefill batches and before every generated token. Nonzero stops now.
typedef int (*ws_cancel_callback)(void *context);

/// A resident model + context. Loaded once by `ws_session_open`, reused by every call, freed only by
/// `ws_session_close`. Calls on one session are serialized by its own lock. No sockets.
typedef struct ws_text_session ws_text_session;
/// CPU-only vocabulary loader: no weights, inference context, or GPU allocation.
typedef struct ws_vocabulary ws_vocabulary;
ws_vocabulary *ws_vocabulary_open(const char *path, char *error, size_t error_size);
void ws_vocabulary_close(ws_vocabulary *vocabulary);
/// Input includes its explicit BOS/chat template. Returns -1 on error.
int ws_vocabulary_count(ws_vocabulary *vocabulary, const char *text);

typedef struct {
    int prompt_tokens;      // tokens in the whole prompt
    int reused_tokens;      // restored from a cached prefix state instead of decoded
    int prefix_built;       // 1 when this call decoded and saved a new prefix state
    int generated_tokens;
    double prefill_ms;      // state restore + decoding the remaining prompt tokens
    double ttft_ms;         // call start (tokenizing included) to the first sampled token
    double total_ms;
    size_t prefix_cache_bytes;  // all saved prefix states after this call
} ws_generation_stats;

/// `batch_size` sets n_batch = n_ubatch (2048 in the app: cheap insurance under GPU contention).
/// Flash attention is left at llama.cpp's auto. Returns NULL and fills `error` on failure.
ws_text_session *ws_session_open(const char *model_path, int context_size, int batch_size, char *error, size_t error_size);
void ws_session_close(ws_text_session *session);
/// Drops every saved prefix state (memory pressure). The model stays loaded.
void ws_session_clear_prefixes(ws_text_session *session);

/// Score fixed single-token alternatives after one prefill per row. Full-vocabulary log
/// probabilities are row-major. No generation. Serialized rows reuse the fixed prefix cache.
int ws_session_score_options(ws_text_session *session, const char *const *prompts,
                             const size_t *prefix_bytes, int rows,
                             const char *const *options, int option_count,
                             double *log_probabilities, ws_generation_stats *stats,
                             ws_cancel_callback should_cancel, void *callback_context,
                             char *error, size_t error_size);

/// One greedy generation. The prompt is complete (chat template applied). The first
/// `cacheable_prefix_bytes` bytes of it are identical across calls (fixed instructions): their
/// sequence state is saved after the first decode (llama_state_seq_get_data) and restored by later
/// calls (llama_state_seq_set_data), so only the rest is decoded. 0 disables the cache for this call.
/// Restoring is exact, so outputs are byte-identical to decoding the whole prompt.
/// Stops at end-of-generation, after `stop` appears (may be NULL), at the first line break once the
/// text is non-blank when `stop_at_line` (titles), or after `max_tokens`.
/// Returns 0 when done, 2 when cancelled (by either callback; `output` keeps the text so far), 1 on error.
int ws_session_generate(ws_text_session *session, const char *prompt, size_t cacheable_prefix_bytes,
                        int max_tokens, const char *stop, int stop_at_line,
                        ws_piece_callback on_piece, ws_cancel_callback should_cancel, void *callback_context,
                        char *output, size_t output_size, ws_generation_stats *stats,
                        char *error, size_t error_size);

// One-shot calls: open a session, generate without a cached prefix, close. Kept for tools and as the
// uncached reference in tests; the app keeps a resident session instead (LlamaTextModel).
int ws_generate_title(const char *model_path, const char *prompt,
                      char *output, size_t output_size, char *error, size_t error_size);
int ws_generate_text(const char *model_path, const char *prompt, int context_size, int max_tokens, const char *stop,
                     char *output, size_t output_size, char *error, size_t error_size);
int ws_generate_text_stream(const char *model_path, const char *prompt, int context_size, int max_tokens, const char *stop,
                            ws_piece_callback on_piece, void *context, char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
