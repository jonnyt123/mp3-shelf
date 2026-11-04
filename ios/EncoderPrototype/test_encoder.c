#include "ShelfEncoder.h"
#include <assert.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
typedef struct { int position, cancel, fail; } Input;
static long read_pcm(void *ctx, int16_t *out, size_t capacity) {
    Input *in = ctx;
    if (in->fail) return -1;
    int frames = 44100 - in->position;
    if (frames > (int)capacity) frames = (int)capacity;
    for (int i=0; i<frames; i++) {
        int16_t sample = (int16_t)(sin((in->position+i)*440.0*6.283185307/44100)*10000);
        out[i*2] = sample; out[i*2+1] = sample;
    }
    in->position += frames;
    return frames;
}
static int cancelled(void *ctx) {
    Input *in = ctx;
    return in->cancel && in->position > 0;
}
static long short_write(void *ctx, const unsigned char *b, size_t n) {
    (void)b; size_t *total = ctx; size_t written = n > 3 ? 3 : n;
    *total += written; return (long)written;
}
static long failed_write(void *ctx, const unsigned char *b, size_t n) {
    (void)ctx; (void)b; (void)n; return -1;
}
static long zero_write(void *ctx, const unsigned char *b, size_t n) {
    (void)ctx; (void)b; (void)n; return 0;
}
int main(void) {
    unsigned char bytes[19] = {0}; size_t total=0;
    assert(shelf_write_all(short_write,&total,bytes,19)==SHELF_OK && total==19);
    assert(shelf_write_all(failed_write,NULL,bytes,19)==SHELF_IO);
    assert(shelf_write_all(zero_write,NULL,bytes,19)==SHELF_IO);
    Input input={0};
    assert(shelf_encode("valid.mp3",44100,2,read_pcm,cancelled,&input)==SHELF_OK);
    input=(Input){0};
    assert(shelf_encode("valid.mp3",44100,2,read_pcm,cancelled,&input)==SHELF_IO);
    input=(Input){.cancel=1};
    assert(shelf_encode("cancelled.mp3",44100,2,read_pcm,cancelled,&input)==SHELF_CANCELLED);
    assert(access("cancelled.mp3",F_OK)!=0);
    input=(Input){.fail=1};
    assert(shelf_encode("failed.mp3",44100,2,read_pcm,cancelled,&input)==SHELF_IO);
    assert(access("failed.mp3",F_OK)!=0);
    assert(shelf_encode("invalid.mp3",44100,3,read_pcm,cancelled,&input)==SHELF_INVALID);
    puts("PASS: encode, partial/failed/zero writes, cancellation cleanup, read failure cleanup, existing file protection, channel validation");
}
