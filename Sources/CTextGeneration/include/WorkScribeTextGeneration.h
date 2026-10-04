#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Loads on demand and releases model/context before returning. No sockets.
int ws_generate_title(const char *model_path, const char *prompt,
                      char *output, size_t output_size, char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
