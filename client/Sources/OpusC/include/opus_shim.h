#ifndef OPUS_SHIM_H
#define OPUS_SHIM_H

#include <opus/opus.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle wrappers around libopus encoder/decoder so Swift
// can call them through a stable void*-based C API.
void* opus_enc_create(int sample_rate, int channels, int application, int* error);
int   opus_enc_set_bitrate(void* enc, int bitrate);
int   opus_enc_encode(void* enc, const short* pcm, int frame_size, unsigned char* data, int max_data_bytes);
void  opus_enc_destroy(void* enc);

void* opus_dec_create(int sample_rate, int channels, int* error);
int   opus_dec_decode(void* dec, const unsigned char* data, int len, short* pcm, int frame_size, int decode_fec);
int   opus_dec_decode_plc(void* dec, short* pcm, int frame_size);
void  opus_dec_destroy(void* dec);

#ifdef __cplusplus
}
#endif

#endif /* OPUS_SHIM_H */
