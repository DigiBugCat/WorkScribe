#include "WorkScribeTextGeneration.h"
#include "vendor/llama.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/stat.h>

static ggml_backend_dev_t cpu_only_devices[] = {nullptr};
using steady = std::chrono::steady_clock;
static double ms_since(steady::time_point start) {
    return std::chrono::duration<double, std::milli>(steady::now() - start).count();
}

static void require_materialized(const char *path) {
    struct stat info;
    if (!path || stat(path, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 || (info.st_flags & SF_DATALESS))
        throw std::runtime_error("Model missing or evicted. Run WorkScribe --doctor.");
}

struct ws_vocabulary {
    llama_model *model = nullptr;
    ~ws_vocabulary() { if (model) llama_model_free(model); }
};
ws_vocabulary *ws_vocabulary_open(const char *path, char *error, size_t error_size) {
    try {
        require_materialized(path);
        auto params = llama_model_default_params();
        params.vocab_only = true; params.n_gpu_layers = 0; params.devices = cpu_only_devices;
        std::unique_ptr<ws_vocabulary> value(new ws_vocabulary());
        value->model = llama_model_load_from_file(path, params);
        if (!value->model) throw std::runtime_error("Could not load E4B vocabulary");
        return value.release();
    } catch (const std::exception &e) { std::snprintf(error, error_size, "%s", e.what()); return nullptr; }
}
void ws_vocabulary_close(ws_vocabulary *value) { delete value; }
int ws_vocabulary_count(ws_vocabulary *value, const char *text) {
    if (!value || !value->model || !text) return -1;
    const int result = llama_tokenize(llama_model_get_vocab(value->model), text, (int)std::strlen(text), nullptr, 0, false, true);
    return result <= 0 ? -result : -1;
}

namespace {
// A saved sequence state for a token prefix (the fixed instructions of a prompt family).
struct Prefix {
    std::vector<llama_token> tokens;
    std::vector<uint8_t> state;
    uint64_t used = 0;
};
// Enough for every prompt family the app sends (note line, topics, brief, title, actions, Ask) with
// room to spare. Saved sequence states are bounded below.
constexpr size_t max_prefixes = 8;
constexpr size_t max_prefix_bytes = 256u << 20;
// A shorter shared head is not worth a state copy.
constexpr size_t min_prefix_tokens = 32;

struct Cancelled {};
}

struct ws_text_session {
    llama_model *model = nullptr;
    llama_context *context = nullptr;
    const llama_vocab *vocab = nullptr;
    int context_size = 0;
    int batch_size = 0;
    std::vector<Prefix> prefixes;
    size_t prefix_bytes = 0;
    uint64_t clock = 0;
    std::mutex lock;

    ~ws_text_session() {
        if (context) llama_free(context);
        if (model) llama_model_free(model);
    }

    std::vector<llama_token> tokenize(const char *text, size_t length) const {
        const int count = -llama_tokenize(vocab, text, (int)length, nullptr, 0, true, true);
        if (count < 0) throw std::runtime_error("Tokenization failed");
        std::vector<llama_token> tokens(count);
        if (count > 0 && llama_tokenize(vocab, text, (int)length, tokens.data(), count, true, true) < 0)
            throw std::runtime_error("Tokenization failed");
        return tokens;
    }

    void decode(const llama_token *tokens, int count, ws_cancel_callback should_cancel, void *callback_context) {
        for (int i = 0; i < count; i += batch_size) {
            if (should_cancel && should_cancel(callback_context)) throw Cancelled();
            auto batch = llama_batch_get_one(const_cast<llama_token *>(tokens) + i, std::min(batch_size, count - i));
            if (llama_decode(context, batch) != 0) throw std::runtime_error("Prompt processing failed");
        }
    }

    // The longest saved prefix that is a proper prefix of `tokens` (at least one token must remain
    // to decode, since its logits pick the first output token).
    Prefix *find(const std::vector<llama_token> &tokens) {
        Prefix *best = nullptr;
        for (auto &entry : prefixes) {
            if (entry.tokens.size() >= tokens.size()) continue;
            if (best && entry.tokens.size() <= best->tokens.size()) continue;
            if (std::equal(entry.tokens.begin(), entry.tokens.end(), tokens.begin())) best = &entry;
        }
        return best;
    }

    void prefill(const char *prompt, size_t cacheable_prefix_bytes, int reserve,
                 ws_cancel_callback should_cancel, void *callback_context, ws_generation_stats &stats) {
        const size_t length = strlen(prompt);
        const std::vector<llama_token> tokens = tokenize(prompt, length);
        const int count = (int)tokens.size();
        stats.prompt_tokens = count;
        if (count <= 0 || count + reserve > context_size) throw std::runtime_error("Prompt exceeds the context limit");
        llama_memory_t memory = llama_get_memory(context);
        llama_memory_clear(memory, true);

        // The cacheable head, as tokens of the whole prompt (tokenizing the head alone can merge
        // differently at its last bytes, so only the shared token prefix counts).
        size_t head = 0;
        if (cacheable_prefix_bytes > 0 && cacheable_prefix_bytes < length) {
            const std::vector<llama_token> alone = tokenize(prompt, cacheable_prefix_bytes);
            while (head < alone.size() && head + 1 < tokens.size() && alone[head] == tokens[head]) ++head;
            if (head < min_prefix_tokens) head = 0;
        }
        const auto prefill_started = steady::now();
        int position = 0;
        if (head > 0) {
            if (Prefix *saved = find(tokens)) {
                if (llama_state_seq_set_data(context, saved->state.data(), saved->state.size(), 0) == saved->state.size()) {
                    saved->used = ++clock;
                    position = (int)saved->tokens.size();
                    stats.reused_tokens = position;
                } else {
                    // Unusable state: forget it and decode from the start.
                    llama_memory_clear(memory, true);
                    prefix_bytes -= saved->state.size();
                    prefixes.erase(prefixes.begin() + (saved - prefixes.data()));
                }
            }
            if (position < (int)head) {
                // No saved state covers this head yet: decode the rest of it, then save it.
                decode(tokens.data() + position, (int)head - position, should_cancel, callback_context);
                save(std::vector<llama_token>(tokens.begin(), tokens.begin() + head));
                stats.prefix_built = 1;
                position = (int)head;
            }
        }
        decode(tokens.data() + position, count - position, should_cancel, callback_context);
        llama_synchronize(context);  // Metal decodes asynchronously; time the work, not its submission
        stats.prefill_ms = ms_since(prefill_started);

    }

    void save(std::vector<llama_token> tokens) {
        Prefix entry;
        entry.tokens = std::move(tokens);
        entry.state.resize(llama_state_seq_get_size(context, 0));
        if (entry.state.empty() || llama_state_seq_get_data(context, entry.state.data(), entry.state.size(), 0) != entry.state.size())
            return;  // not fatal: the next call decodes the prefix again
        entry.used = ++clock;
        prefix_bytes += entry.state.size();
        prefixes.push_back(std::move(entry));
        while (prefixes.size() > max_prefixes || (prefix_bytes > max_prefix_bytes && prefixes.size() > 1)) {
            auto oldest = std::min_element(prefixes.begin(), prefixes.end(), [](const Prefix &a, const Prefix &b) { return a.used < b.used; });
            prefix_bytes -= oldest->state.size();
            prefixes.erase(oldest);
        }
    }
};

namespace {
// Sessions still open when the process exits. ggml's Metal device is a static whose destructor
// asserts that no model or context still holds GPU residency sets, so every resident session is
// freed by an exit handler, which runs before that destructor (it is registered after the device
// exists: after the first model load).
std::mutex open_lock;
std::set<ws_text_session *> *open_sessions = new std::set<ws_text_session *>();

void free_session_models(ws_text_session *session) {
    std::lock_guard<std::mutex> guard(session->lock);  // waits for a generation in flight
    if (session->context) { llama_free(session->context); session->context = nullptr; }
    if (session->model) { llama_model_free(session->model); session->model = nullptr; }
}

void close_open_sessions_at_exit() {
    std::lock_guard<std::mutex> guard(open_lock);
    for (auto *session : *open_sessions) free_session_models(session);
    open_sessions->clear();
}
}

ws_text_session *ws_session_open(const char *model_path, int context_size, int batch_size, char *error, size_t error_size) {
    try {
        require_materialized(model_path);
        static std::once_flag initialized;
        std::call_once(initialized, [] { llama_backend_init(); });
        const bool cpu = std::getenv("WORKSCRIBE_TEXT_CPU") != nullptr;
        auto mp = llama_model_default_params();
        mp.n_gpu_layers = cpu ? 0 : 99;
        if (cpu) mp.devices = cpu_only_devices;
        std::unique_ptr<ws_text_session> session(new ws_text_session());
        session->model = llama_model_load_from_file(model_path, mp);
        if (!session->model) throw std::runtime_error("Could not load the embedded text model");
        auto cp = llama_context_default_params();
        if (cpu) { cp.offload_kqv = false; cp.op_offload = false; }
        session->context_size = context_size;
        session->batch_size = std::max(1, std::min(batch_size, context_size));
        cp.n_ctx = context_size; cp.n_batch = session->batch_size; cp.n_ubatch = session->batch_size;
        cp.n_threads = 4; cp.n_threads_batch = 4;
        // cp.flash_attn_type stays LLAMA_FLASH_ATTN_TYPE_AUTO (on for Metal; off costs 0–12%).
        session->context = llama_init_from_model(session->model, cp);
        if (!session->context) throw std::runtime_error("Could not create the text-generation context");
        session->vocab = llama_model_get_vocab(session->model);
        static std::once_flag exit_handler;
        std::call_once(exit_handler, [] { std::atexit(close_open_sessions_at_exit); });
        std::lock_guard<std::mutex> guard(open_lock);
        open_sessions->insert(session.get());
        return session.release();
    } catch (const std::exception &e) {
        std::snprintf(error, error_size, "%s", e.what());
    } catch (...) {
        std::snprintf(error, error_size, "Unexpected text-model load error");
    }
    return nullptr;
}

void ws_session_close(ws_text_session *session) {
    if (!session) return;
    {
        std::lock_guard<std::mutex> guard(open_lock);
        open_sessions->erase(session);
    }
    free_session_models(session);
    delete session;
}

void ws_session_clear_prefixes(ws_text_session *session) {
    if (!session) return;
    std::lock_guard<std::mutex> guard(session->lock);
    session->prefixes.clear();
    session->prefixes.shrink_to_fit();
    session->prefix_bytes = 0;
}

int ws_session_generate(ws_text_session *session, const char *prompt, size_t cacheable_prefix_bytes,
                        int max_tokens, const char *stop, int stop_at_line,
                        ws_piece_callback on_piece, ws_cancel_callback should_cancel, void *callback_context,
                        char *output, size_t output_size, ws_generation_stats *stats,
                        char *error, size_t error_size) {
    if (output && output_size) output[0] = 0;
    if (!session) { std::snprintf(error, error_size, "The text model is not loaded"); return 1; }
    std::lock_guard<std::mutex> guard(session->lock);
    if (!session->context) { std::snprintf(error, error_size, "The text model was released"); return 1; }
    const auto started = steady::now();
    ws_generation_stats local{};
    std::string text;
    auto finish = [&](int status) {
        if (output && output_size) {
            if (text.size() + 1 > output_size) text.resize(output_size - 1);
            std::snprintf(output, output_size, "%s", text.c_str());
        }
        local.total_ms = ms_since(started);
        local.prefix_cache_bytes = session->prefix_bytes;
        if (stats) *stats = local;
        return status;
    };
    try {
        session->prefill(prompt, cacheable_prefix_bytes, max_tokens, should_cancel, callback_context, local);

        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_init_greedy(), llama_sampler_free);
        const std::string marker = stop ? stop : "";
        std::string pending;  // bytes of a UTF-8 character split across tokens
        for (int i = 0; i < max_tokens; ++i) {
            if (should_cancel && should_cancel(callback_context)) throw Cancelled();
            llama_token token = llama_sampler_sample(sampler.get(), session->context, -1);
            if (i == 0) local.ttft_ms = ms_since(started);
            if (llama_vocab_is_eog(session->vocab, token)) break;
            char piece[256];
            int piece_length = llama_token_to_piece(session->vocab, token, piece, sizeof(piece), 0, false);
            if (piece_length < 0) throw std::runtime_error("Invalid token");
            text.append(piece, piece_length);
            ++local.generated_tokens;
            if (on_piece) {
                pending.append(piece, piece_length);
                // Hand over only complete UTF-8 sequences.
                size_t complete = pending.size();
                for (size_t back = 1; back <= 3 && back <= pending.size(); ++back) {
                    unsigned char byte = (unsigned char)pending[pending.size() - back];
                    if ((byte & 0xC0) == 0x80) continue;  // continuation byte
                    size_t need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1;
                    if (need > back) complete = pending.size() - back;
                    break;
                }
                if (complete > 0) {
                    std::string out = pending.substr(0, complete);
                    pending.erase(0, complete);
                    if (on_piece(out.c_str(), callback_context) != 0) throw Cancelled();
                }
            }
            if (!marker.empty() && text.find(marker) != std::string::npos) break;
            if (stop_at_line && text.find('\n') != std::string::npos && text.find_first_not_of(" \n\r\t") != std::string::npos) break;
            if (llama_decode(session->context, llama_batch_get_one(&token, 1)) != 0)
                throw std::runtime_error("Text generation failed");
        }
        if (!pending.empty() && on_piece) on_piece(pending.c_str(), callback_context);
        return finish(0);
    } catch (const Cancelled &) {
        return finish(2);
    } catch (const std::exception &e) {
        std::snprintf(error, error_size, "%s", e.what());
        return finish(1);
    } catch (...) {
        std::snprintf(error, error_size, "Unexpected text-generation error");
        return finish(1);
    }
}

// A batched caller amortizes model/prefix setup. Rows are evaluated serially in the resident
// context; this API does not claim parallel sequence decoding. No sampler or output token decode.
int ws_session_score_options(ws_text_session *session, const char *const *prompts,
                             const size_t *prefix_bytes, int rows,
                             const char *const *options, int option_count,
                             double *log_probabilities, ws_generation_stats *stats,
                             ws_cancel_callback should_cancel, void *callback_context,
                             char *error, size_t error_size) {
    if (!session || !prompts || !options || !log_probabilities || rows < 1 || option_count < 2) {
        std::snprintf(error, error_size, "Invalid decision request"); return 1;
    }
    std::lock_guard<std::mutex> guard(session->lock);
    try {
        if (!session->context) throw std::runtime_error("The text model was released");
        std::vector<llama_token> ids(option_count);
        for (int i = 0; i < option_count; ++i) {
            // Fixed alternatives must each be one ordinary token, with no BOS/chat tokens.
            if (!options[i] || llama_tokenize(session->vocab, options[i], (int)strlen(options[i]),
                                              &ids[i], 1, false, false) != 1)
                throw std::runtime_error("Each decision option must tokenize to exactly one token");
            for (int j = 0; j < i; ++j) if (ids[i] == ids[j])
                throw std::runtime_error("Decision options must be distinct tokens");
        }
        for (int row = 0; row < rows; ++row) {
            if (!prompts[row]) throw std::runtime_error("Missing decision prompt");
            const auto started = steady::now();
            ws_generation_stats local{};
            session->prefill(prompts[row], prefix_bytes ? prefix_bytes[row] : 0, 0,
                             should_cancel, callback_context, local);
            if (should_cancel && should_cancel(callback_context)) throw Cancelled();
            const float *logits = llama_get_logits_ith(session->context, -1);
            if (!logits) throw std::runtime_error("Missing decision logits");
            const int vocabulary = llama_vocab_n_tokens(session->vocab);
            double maximum = -INFINITY;
            for (int i = 0; i < vocabulary; ++i) maximum = std::max(maximum, (double)logits[i]);
            double sum = 0;
            for (int i = 0; i < vocabulary; ++i) sum += std::exp((double)logits[i] - maximum);
            const double normalizer = maximum + std::log(sum);
            if (!std::isfinite(normalizer)) throw std::runtime_error("Nonfinite decision logits");
            for (int i = 0; i < option_count; ++i)
                log_probabilities[row * option_count + i] = logits[ids[i]] - normalizer;
            local.total_ms = ms_since(started);
            local.prefix_cache_bytes = session->prefix_bytes;
            if (stats) stats[row] = local;
        }
        return 0;
    } catch (const Cancelled &) { return 2; }
    catch (const std::exception &e) { std::snprintf(error, error_size, "%s", e.what()); return 1; }
}

namespace {
int one_shot(const char *model_path, const char *prompt, int context_size, int max_tokens, const char *stop, int stop_at_line,
             ws_piece_callback on_piece, void *callback_context, char *output, size_t output_size, char *error, size_t error_size) {
    std::unique_ptr<ws_text_session, decltype(&ws_session_close)> session(
        ws_session_open(model_path, context_size, 2048, error, error_size), ws_session_close);
    if (!session) return 1;
    const int status = ws_session_generate(session.get(), prompt, 0, max_tokens, stop, stop_at_line, on_piece, nullptr,
                                           callback_context, output, output_size, nullptr, error, error_size);
    return status == 2 ? 0 : status;  // a callback that stops early is not an error
}
}

int ws_generate_title(const char *model_path, const char *prompt,
                      char *output, size_t output_size, char *error, size_t error_size) {
    return one_shot(model_path, prompt, 2048, 40, nullptr, 1, nullptr, nullptr, output, output_size, error, error_size);
}

int ws_generate_text(const char *model_path, const char *prompt, int context_size, int max_tokens, const char *stop,
                     char *output, size_t output_size, char *error, size_t error_size) {
    return one_shot(model_path, prompt, context_size, max_tokens, stop, 0, nullptr, nullptr, output, output_size, error, error_size);
}

int ws_generate_text_stream(const char *model_path, const char *prompt, int context_size, int max_tokens, const char *stop,
                            ws_piece_callback on_piece, void *context, char *error, size_t error_size) {
    return one_shot(model_path, prompt, context_size, max_tokens, stop, 0, on_piece, context, nullptr, 0, error, error_size);
}
