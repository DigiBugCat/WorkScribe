#include "WorkScribeTextGeneration.h"
#include "vendor/llama.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/stat.h>

static ggml_backend_dev_t cpu_only_devices[] = {nullptr};

static void require_materialized(const char *path) {
    struct stat info;
    if (!path || stat(path, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 || (info.st_flags & SF_DATALESS))
        throw std::runtime_error("Model missing or evicted. Run WorkScribe --doctor.");
}

int ws_generate_title(const char *model_path, const char *prompt,
                      char *output, size_t output_size, char *error, size_t error_size) {
    try {
        require_materialized(model_path);
        static std::once_flag initialized;
        std::call_once(initialized, [] { llama_backend_init(); });
        auto mp = llama_model_default_params();
        mp.n_gpu_layers = std::getenv("WORKSCRIBE_TEXT_CPU") ? 0 : 99;
        if (std::getenv("WORKSCRIBE_TEXT_CPU")) mp.devices = cpu_only_devices;
        std::unique_ptr<llama_model, decltype(&llama_model_free)> model(llama_model_load_from_file(model_path, mp), llama_model_free);
        if (!model) throw std::runtime_error("Could not load the embedded title model");
        auto cp = llama_context_default_params();
        if (std::getenv("WORKSCRIBE_TEXT_CPU")) { cp.offload_kqv = false; cp.op_offload = false; }
        cp.n_ctx = 2048; cp.n_batch = 512; cp.n_ubatch = 512;
        cp.n_threads = 4; cp.n_threads_batch = 4;
        std::unique_ptr<llama_context, decltype(&llama_free)> context(llama_init_from_model(model.get(), cp), llama_free);
        if (!context) throw std::runtime_error("Could not create the title-generation context");
        const llama_vocab *vocab = llama_model_get_vocab(model.get());
        const int count = -llama_tokenize(vocab, prompt, (int)strlen(prompt), nullptr, 0, true, true);
        if (count <= 0 || count > 1950) throw std::runtime_error("Title prompt exceeds the context limit");
        std::vector<llama_token> tokens(count);
        if (llama_tokenize(vocab, prompt, (int)strlen(prompt), tokens.data(), count, true, true) < 0)
            throw std::runtime_error("Title tokenization failed");
        for (int i = 0; i < count; i += 512) {
            auto batch = llama_batch_get_one(tokens.data() + i, std::min(512, count - i));
            if (llama_decode(context.get(), batch) != 0) throw std::runtime_error("Title prompt processing failed");
        }
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_init_greedy(), llama_sampler_free);
        std::string text;
        for (int i = 0; i < 40; ++i) {
            llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
            if (llama_vocab_is_eog(vocab, token)) break;
            char piece[256];
            int length = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
            if (length < 0) throw std::runtime_error("Invalid title token");
            text.append(piece, length);
            if (text.find('\n') != std::string::npos && text.find_first_not_of(" \n\r\t") != std::string::npos) break;
            if (llama_decode(context.get(), llama_batch_get_one(&token, 1)) != 0)
                throw std::runtime_error("Title generation failed");
        }
        if (text.size() + 1 > output_size) throw std::runtime_error("Generated title was too long");
        std::snprintf(output, output_size, "%s", text.c_str());
        return 0;
    } catch (const std::exception &e) {
        std::snprintf(error, error_size, "%s", e.what());
        return 1;
    } catch (...) {
        std::snprintf(error, error_size, "Unexpected title-generation error");
        return 1;
    }
}

int ws_generate_text(const char *model_path, const char *prompt, int context_size, int max_tokens, const char *stop,
                     char *output, size_t output_size, char *error, size_t error_size) {
    try {
        require_materialized(model_path);
        static std::once_flag initialized;
        std::call_once(initialized, [] { llama_backend_init(); });
        auto mp = llama_model_default_params();
        mp.n_gpu_layers = std::getenv("WORKSCRIBE_TEXT_CPU") ? 0 : 99;
        if (std::getenv("WORKSCRIBE_TEXT_CPU")) mp.devices = cpu_only_devices;
        std::unique_ptr<llama_model, decltype(&llama_model_free)> model(llama_model_load_from_file(model_path, mp), llama_model_free);
        if (!model) throw std::runtime_error("Could not load the embedded text model");
        auto cp = llama_context_default_params();
        if (std::getenv("WORKSCRIBE_TEXT_CPU")) { cp.offload_kqv = false; cp.op_offload = false; }
        cp.n_ctx = context_size; cp.n_batch = 512; cp.n_ubatch = 512;
        cp.n_threads = 4; cp.n_threads_batch = 4;
        std::unique_ptr<llama_context, decltype(&llama_free)> context(llama_init_from_model(model.get(), cp), llama_free);
        if (!context) throw std::runtime_error("Could not create the text-generation context");
        const llama_vocab *vocab = llama_model_get_vocab(model.get());
        const int count = -llama_tokenize(vocab, prompt, (int)strlen(prompt), nullptr, 0, true, true);
        if (count <= 0 || count + max_tokens > context_size) throw std::runtime_error("Prompt exceeds the context limit");
        std::vector<llama_token> tokens(count);
        if (llama_tokenize(vocab, prompt, (int)strlen(prompt), tokens.data(), count, true, true) < 0)
            throw std::runtime_error("Tokenization failed");
        for (int i = 0; i < count; i += 512) {
            auto batch = llama_batch_get_one(tokens.data() + i, std::min(512, count - i));
            if (llama_decode(context.get(), batch) != 0) throw std::runtime_error("Prompt processing failed");
        }
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_init_greedy(), llama_sampler_free);
        const std::string marker = stop ? stop : "";
        std::string text;
        for (int i = 0; i < max_tokens; ++i) {
            llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
            if (llama_vocab_is_eog(vocab, token)) break;
            char piece[256];
            int length = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
            if (length < 0) throw std::runtime_error("Invalid token");
            text.append(piece, length);
            if (!marker.empty() && text.find(marker) != std::string::npos) break;
            if (llama_decode(context.get(), llama_batch_get_one(&token, 1)) != 0)
                throw std::runtime_error("Text generation failed");
        }
        if (text.size() + 1 > output_size) text.resize(output_size - 1);
        std::snprintf(output, output_size, "%s", text.c_str());
        return 0;
    } catch (const std::exception &e) {
        std::snprintf(error, error_size, "%s", e.what());
        return 1;
    } catch (...) {
        std::snprintf(error, error_size, "Unexpected text-generation error");
        return 1;
    }
}

int ws_generate_text_stream(const char *model_path, const char *prompt, int context_size, int max_tokens, const char *stop,
                            ws_piece_callback on_piece, void *callback_context, char *error, size_t error_size) {
    try {
        require_materialized(model_path);
        static std::once_flag initialized;
        std::call_once(initialized, [] { llama_backend_init(); });
        auto mp = llama_model_default_params();
        mp.n_gpu_layers = std::getenv("WORKSCRIBE_TEXT_CPU") ? 0 : 99;
        if (std::getenv("WORKSCRIBE_TEXT_CPU")) mp.devices = cpu_only_devices;
        std::unique_ptr<llama_model, decltype(&llama_model_free)> model(llama_model_load_from_file(model_path, mp), llama_model_free);
        if (!model) throw std::runtime_error("Could not load the embedded text model");
        auto cp = llama_context_default_params();
        if (std::getenv("WORKSCRIBE_TEXT_CPU")) { cp.offload_kqv = false; cp.op_offload = false; }
        cp.n_ctx = context_size; cp.n_batch = 512; cp.n_ubatch = 512;
        cp.n_threads = 4; cp.n_threads_batch = 4;
        std::unique_ptr<llama_context, decltype(&llama_free)> context(llama_init_from_model(model.get(), cp), llama_free);
        if (!context) throw std::runtime_error("Could not create the text-generation context");
        const llama_vocab *vocab = llama_model_get_vocab(model.get());
        const int count = -llama_tokenize(vocab, prompt, (int)strlen(prompt), nullptr, 0, true, true);
        if (count <= 0 || count + max_tokens > context_size) throw std::runtime_error("Prompt exceeds the context limit");
        std::vector<llama_token> tokens(count);
        if (llama_tokenize(vocab, prompt, (int)strlen(prompt), tokens.data(), count, true, true) < 0)
            throw std::runtime_error("Tokenization failed");
        for (int i = 0; i < count; i += 512) {
            auto batch = llama_batch_get_one(tokens.data() + i, std::min(512, count - i));
            if (llama_decode(context.get(), batch) != 0) throw std::runtime_error("Prompt processing failed");
        }
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_init_greedy(), llama_sampler_free);
        const std::string marker = stop ? stop : "";
        std::string text;
        std::string pending;  // bytes of a UTF-8 character split across tokens
        for (int i = 0; i < max_tokens; ++i) {
            llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
            if (llama_vocab_is_eog(vocab, token)) break;
            char piece[256];
            int length = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
            if (length < 0) throw std::runtime_error("Invalid token");
            text.append(piece, length);
            pending.append(piece, length);
            if (!marker.empty() && text.find(marker) != std::string::npos) break;
            // Hand over only complete UTF-8 sequences.
            size_t complete = pending.size();
            for (size_t back = 1; back <= 3 && back <= pending.size(); ++back) {
                unsigned char byte = (unsigned char)pending[pending.size() - back];
                if ((byte & 0xC0) == 0x80) continue;          // continuation byte
                size_t need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1;
                if (need > back) complete = pending.size() - back;
                break;
            }
            if (complete > 0 && on_piece) {
                std::string out = pending.substr(0, complete);
                pending.erase(0, complete);
                if (on_piece(out.c_str(), callback_context) != 0) return 0;
            }
            if (llama_decode(context.get(), llama_batch_get_one(&token, 1)) != 0)
                throw std::runtime_error("Text generation failed");
        }
        if (!pending.empty() && on_piece) on_piece(pending.c_str(), callback_context);
        return 0;
    } catch (const std::exception &e) {
        std::snprintf(error, error_size, "%s", e.what());
        return 1;
    } catch (...) {
        std::snprintf(error, error_size, "Unexpected text-generation error");
        return 1;
    }
}
