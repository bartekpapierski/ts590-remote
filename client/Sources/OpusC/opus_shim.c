#include "opus_shim.h"

void* opus_enc_create(int sample_rate, int channels, int application, int* error) {
    int err = 0;
    OpusEncoder* enc = opus_encoder_create(sample_rate, channels, application, &err);
    if (error) *error = err;
    return (void*)enc;
}

int opus_enc_set_bitrate(void* enc, int bitrate) {
    return opus_encoder_ctl((OpusEncoder*)enc, OPUS_SET_BITRATE(bitrate));
}

int opus_enc_encode(void* enc, const short* pcm, int frame_size, unsigned char* data, int max_data_bytes) {
    return opus_encode((OpusEncoder*)enc, pcm, frame_size, data, max_data_bytes);
}

void opus_enc_destroy(void* enc) {
    opus_encoder_destroy((OpusEncoder*)enc);
}

void* opus_dec_create(int sample_rate, int channels, int* error) {
    int err = 0;
    OpusDecoder* dec = opus_decoder_create(sample_rate, channels, &err);
    if (error) *error = err;
    return (void*)dec;
}

int opus_dec_decode(void* dec, const unsigned char* data, int len, short* pcm, int frame_size, int decode_fec) {
    return opus_decode((OpusDecoder*)dec, data, len, pcm, frame_size, decode_fec);
}

int opus_dec_decode_plc(void* dec, short* pcm, int frame_size) {
    return opus_decode((OpusDecoder*)dec, NULL, 0, pcm, frame_size, 0);
}

void opus_dec_destroy(void* dec) {
    opus_decoder_destroy((OpusDecoder*)dec);
}
