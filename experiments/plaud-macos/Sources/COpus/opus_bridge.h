#include <stdint.h>
typedef struct OpusDecoder OpusDecoder;
typedef struct OpusMSDecoder OpusMSDecoder;
OpusDecoder *opus_decoder_create(int32_t Fs, int channels, int *error);
int opus_decode(OpusDecoder *st, const unsigned char *data, int32_t len,
                int16_t *pcm, int frame_size, int decode_fec);
void opus_decoder_destroy(OpusDecoder *st);
OpusMSDecoder *opus_multistream_decoder_create(int32_t Fs, int channels,
    int streams, int coupled_streams, const unsigned char *mapping, int *error);
int opus_multistream_decode(OpusMSDecoder *st, const unsigned char *data,
    int32_t len, int16_t *pcm, int frame_size, int decode_fec);
void opus_multistream_decoder_destroy(OpusMSDecoder *st);
