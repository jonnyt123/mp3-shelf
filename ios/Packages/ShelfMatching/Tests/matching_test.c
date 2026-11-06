#include "ShelfMatching.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    ShelfMatchInput input = {"thesong", "theartist", "thesong", "theartist", 212, 213, 0, 0, 0, 0};
    ShelfMatchResult result = ShelfMatchEvaluate(&input);
    assert(result.decision == ShelfMatchAutomatic && result.score == 95);
    input.verified_channel = 1;
    assert(ShelfMatchEvaluate(&input).score == 100);
    input.candidate_artist = "reuploadchannel";
    input.candidate_title = "theartistthesong";
    result = ShelfMatchEvaluate(&input);
    assert(result.decision == ShelfMatchReview && result.score <= 90);
    input.candidate_title = "theartistsomeothersong";
    assert(ShelfMatchEvaluate(&input).decision == ShelfMatchRejected);
    input.candidate_title = "thesong";
    assert(ShelfMatchEvaluate(&input).reason == ShelfMatchWrongArtist);
    input.candidate_artist = "theartist";
    input.candidate_duration = 30;
    assert(ShelfMatchEvaluate(&input).reason == ShelfMatchWrongDuration);
    input.candidate_duration = 216;
    assert(ShelfMatchEvaluate(&input).decision == ShelfMatchAutomatic);
    input.candidate_duration = 216.01;
    assert(ShelfMatchEvaluate(&input).reason == ShelfMatchWrongDuration);
    input.candidate_duration = NAN;
    assert(ShelfMatchEvaluate(&input).decision != ShelfMatchAutomatic);
    input.candidate_duration = 212;
    input.requested_duration = 0;
    assert(ShelfMatchEvaluate(&input).reason == ShelfMatchUnknownDuration);
    input.requested_duration = 212;
    input.candidate_versions = 1;
    assert(ShelfMatchEvaluate(&input).reason == ShelfMatchWrongVersion);
    input.requested_versions = 1;
    assert(ShelfMatchEvaluate(&input).decision == ShelfMatchAutomatic);
    input.live_stream = 1;
    assert(ShelfMatchEvaluate(&input).reason == ShelfMatchLiveStream);
    input.live_stream = 0;
    input.requested_title = "";
    assert(ShelfMatchEvaluate(&input).reason == ShelfMatchMissingIdentity);
    assert(ShelfMatchEvaluate(NULL).reason == ShelfMatchMissingIdentity);
    input.requested_title = "thelongsongtitle";
    input.candidate_title = "thelongsongtitlf";
    input.requested_versions = input.candidate_versions = 0;
    result = ShelfMatchEvaluate(&input);
    assert(result.decision == ShelfMatchReview && result.reason == ShelfMatchSimilarTitle);
    input.candidate_duration = INFINITY;
    assert(ShelfMatchEvaluate(&input).decision != ShelfMatchAutomatic);
    char oversized[1026];
    memset(oversized, 'a', sizeof oversized - 1);
    oversized[sizeof oversized - 1] = '\0';
    input.candidate_title = oversized;
    assert(ShelfMatchEvaluate(&input).reason == ShelfMatchMissingIdentity);
    const uint8_t mp4[] = {0,0,0,24,'f','t','y','p','M','4','A',' '};
    const uint8_t html[] = "<html><head><title>Site Unavailable</title></head></html>";
    assert(ShelfAudioResponseIsMP4(200, "audio/mp4", mp4, sizeof mp4));
    assert(ShelfAudioResponseIsMP4(206, "application/octet-stream", mp4, sizeof mp4));
    assert(!ShelfAudioResponseIsMP4(200, "text/html", html, sizeof html));
    assert(!ShelfAudioResponseIsMP4(206, "application/octet-stream", html, sizeof html));
    assert(!ShelfAudioResponseIsMP4(403, "audio/mp4", mp4, sizeof mp4));
    assert(!ShelfAudioResponseIsMP4(200, NULL, mp4, sizeof mp4));
    assert(!ShelfAudioResponseIsMP4(200, "audio/mp4", NULL, 64));
    assert(!ShelfAudioResponseIsMP4(200, "audio/mp4", mp4, 4));
    puts("Owned matching core: identity, duration, version, review, HTTP/audio admission and invalid-input checks passed");
}
