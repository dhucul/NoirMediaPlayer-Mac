#pragma once
#include <stdint.h>
typedef struct NVLC NVLC;
typedef struct { int state; int64_t time, length; unsigned width, height; int audio, subtitle, chapter, chapters, failed; } NVLCState;
// VLC_PLUGIN_PATH must be set once, on the main thread, before the first call.
NVLC *nvlc_create(const char *library, void *view);
const char *nvlc_error(void);
void nvlc_failure(NVLC *v, char *message, int capacity);
void nvlc_destroy(NVLC *v);
int nvlc_open(NVLC *v, const char *source, int hardware, int rotation, int64_t start);
void nvlc_stop(NVLC *v);
void nvlc_pause(NVLC *v, int pause);
void nvlc_seek(NVLC *v, int64_t time);
void nvlc_volume(NVLC *v, int volume, int muted);
void nvlc_rate(NVLC *v, float rate);
void nvlc_aspect(NVLC *v, const char *ratio);
void nvlc_chapter(NVLC *v, int chapter);
void nvlc_navigate(NVLC *v, unsigned direction);
void nvlc_track(NVLC *v, int subtitle, int identifier);
int nvlc_subtitle(NVLC *v, const char *url);
int nvlc_snapshot(NVLC *v, const char *path);
NVLCState nvlc_state(NVLC *v);
int nvlc_tracks(NVLC *v, int subtitle, int *ids, char *names, int capacity, int stride);
int noir_inflate(const void *input, unsigned input_size, void *output, unsigned output_size, uint32_t checksum);
uint32_t noir_crc32(const void *input, unsigned size);
