#include "ShelfEncoder.h"
#include <lame.h>
#include <stdlib.h>

int shelf_write_all(ShelfWrite write, void *context, const unsigned char *bytes, size_t count) {
    if (!write || (!bytes && count)) return SHELF_INVALID;
    while (count) {
        long n = write(context, bytes, count);
        if (n <= 0 || (size_t)n > count) return SHELF_IO;
        bytes += n;
        count -= (size_t)n;
    }
    return SHELF_OK;
}
static long file_write(void *context, const unsigned char *bytes, size_t count) {
    FILE *file = context;
    size_t n = fwrite(bytes, 1, count, file);
    return ferror(file) ? -1 : (long)n;
}
int shelf_encode(const char *destination, int rate, int channels,
                 ShelfRead read, ShelfCancelled cancelled, void *context) {
    if (!destination || !read || (channels != 1 && channels != 2) ||
        (rate != 32000 && rate != 44100 && rate != 48000)) return SHELF_INVALID;
    if (cancelled && cancelled(context)) return SHELF_CANCELLED;
    lame_t encoder = lame_init();
    if (!encoder) return SHELF_ENCODER;
    int result = SHELF_ENCODER;
    FILE *file = NULL;
    if (lame_set_in_samplerate(encoder, rate) < 0 ||
        lame_set_out_samplerate(encoder, rate) < 0 ||
        lame_set_num_channels(encoder, channels) < 0 ||
        lame_set_brate(encoder, 192) < 0 || lame_set_quality(encoder, 2) < 0 ||
        lame_init_params(encoder) < 0) goto done;
    /* Exclusive creation: never truncate or append to an existing user file. */
    file = fopen(destination, "wbx");
    if (!file) { result = SHELF_IO; goto done; }
    int16_t pcm[4096 * 2];
    /* LAME requires at least 1.25 * frames + 7200 bytes. */
    unsigned char output[16384];
    size_t total = 0;
    for (;;) {
        if (cancelled && cancelled(context)) { result = SHELF_CANCELLED; break; }
        long frames = read(context, pcm, 4096);
        if (frames < 0 || frames > 4096) { result = SHELF_IO; break; }
        if (cancelled && cancelled(context)) { result = SHELF_CANCELLED; break; }
        if (!frames) {
            if (!total) { result = SHELF_INVALID; break; }
            int n = lame_encode_flush(encoder, output, sizeof(output));
            result = n < 0 ? SHELF_ENCODER : shelf_write_all(file_write, file, output, (size_t)n);
            break;
        }
        /* One hour maximum; bound storage/work even for a bad reader. */
        total += (size_t)frames;
        if (total > (size_t)rate * 3600) { result = SHELF_INVALID; break; }
        int n = channels == 2
            ? lame_encode_buffer_interleaved(encoder, pcm, (int)frames, output, sizeof(output))
            : lame_encode_buffer(encoder, pcm, pcm, (int)frames, output, sizeof(output));
        if (n < 0) { result = SHELF_ENCODER; break; }
        result = shelf_write_all(file_write, file, output, (size_t)n);
        if (result != SHELF_OK) break;
    }
    if (cancelled && cancelled(context)) result = SHELF_CANCELLED;
    if (fflush(file) != 0 && result == SHELF_OK) result = SHELF_IO;
    if (fclose(file) != 0 && result == SHELF_OK) result = SHELF_IO;
    file = NULL;
    if (result != SHELF_OK) remove(destination);
done:
    lame_close(encoder);
    return result;
}
