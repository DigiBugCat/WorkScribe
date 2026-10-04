#include "WorkScribeTextGeneration.h"
#include "vendor/llama.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

int ws_generate_title(const char *model_path, const char *prompt,
                      char *output, size_t output_size, char *error, size_t error_size) {
    try {
        static std::once_flag initialized;
        std::call_once(initialized, [] { llama_backend_init(); });
        auto mp = llama_model_default_params();
        mp.n_gpu_layers = 99;
        std::unique_ptr<llama_model, decltype(&llama_model_free)> model(llama_model_load_from_file(model_path, mp), llama_model_free);
        if (!model) throw std::runtime_error("Could not load the embedded title model");
        auto cp = llama_context_default_params();
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
