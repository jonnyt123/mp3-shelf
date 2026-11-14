#ifndef SHELF_MATCHING_H
#define SHELF_MATCHING_H
#include <stdint.h>
#include <stddef.h>
typedef enum { ShelfMatchRejected, ShelfMatchReview, ShelfMatchAutomatic } ShelfMatchDecision;
typedef enum {
    ShelfMatchExact, ShelfMatchMissingIdentity, ShelfMatchWrongArtist,
    ShelfMatchWrongTitle, ShelfMatchWrongVersion, ShelfMatchWrongDuration,
    ShelfMatchUnknownDuration, ShelfMatchSimilarTitle, ShelfMatchLiveStream
} ShelfMatchReason;
typedef struct {
    const char *requested_title;
    const char *requested_artist;
    const char *candidate_title;
    const char *candidate_artist;
    double requested_duration;
    double candidate_duration;
    uint32_t requested_versions;
    uint32_t candidate_versions;
    int verified_channel;
    int live_stream;
} ShelfMatchInput;
typedef struct {
    ShelfMatchDecision decision;
    ShelfMatchReason reason;
    int score;
} ShelfMatchResult;
ShelfMatchResult ShelfMatchEvaluate(const ShelfMatchInput *input);
/* A bounded prefix check, not a substitute for full decoding after transfer.
   MIME is normalized to lowercase without parameters by the caller. */
int ShelfAudioResponseIsMP4(int status, const char *mime,
                           const uint8_t *prefix, size_t prefix_count);
#endif
