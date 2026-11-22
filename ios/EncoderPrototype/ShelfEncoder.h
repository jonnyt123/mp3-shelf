#ifndef SHELF_ENCODER_H
#define SHELF_ENCODER_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
/* Reader returns frames, 0 for EOF, -1 for failure; at most capacity frames.
   PCM must be interleaved signed 16-bit with the declared channel count.
   Cancellation callback must be safe for the caller's threading model. */
typedef long (*ShelfRead)(void *, int16_t *, size_t);
typedef int (*ShelfCancelled)(void *);
typedef long (*ShelfWrite)(void *, const unsigned char *, size_t);
enum { SHELF_OK, SHELF_INVALID, SHELF_IO, SHELF_ENCODER, SHELF_CANCELLED };
int shelf_write_all(ShelfWrite write, void *context, const unsigned char *bytes, size_t count);
int shelf_encode(const char *destination, int rate, int channels,
                 ShelfRead read, ShelfCancelled cancelled, void *context);
#endif
