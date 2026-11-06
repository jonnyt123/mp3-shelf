#include "ShelfMatching.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

int ShelfAudioResponseIsMP4(int status, const char *mime,
                           const uint8_t *prefix, size_t prefix_count) {
    if ((status != 200 && status != 206) || !mime || !prefix || prefix_count < 12) return 0;
    if (strcmp(mime, "audio/mp4") && strcmp(mime, "audio/m4a") &&
        strcmp(mime, "audio/x-m4a") && strcmp(mime, "application/octet-stream")) return 0;
    return !memcmp(prefix + 4, "ftyp", 4);
}

static size_t bounded_length(const char *value) {
    if (!value) return 0;
    size_t count = 0;
    while (count <= 1024 && value[count]) count++;
    return count;
}
static double similarity(const char *a, const char *b) {
    size_t m = strlen(a), n = strlen(b);
    if (!m || !n || m > 256 || n > 256) return 0;
    unsigned previous[257], current[257];
    for (size_t j = 0; j <= n; j++) previous[j] = (unsigned)j;
    for (size_t i = 1; i <= m; i++) {
        current[0] = (unsigned)i;
        for (size_t j = 1; j <= n; j++) {
            unsigned remove = previous[j] + 1, add = current[j - 1] + 1;
            unsigned change = previous[j - 1] + (a[i - 1] != b[j - 1]);
            unsigned best = remove < add ? remove : add;
            current[j] = best < change ? best : change;
        }
        memcpy(previous, current, (n + 1) * sizeof(unsigned));
    }
    return 1.0 - (double)previous[n] / (double)(m > n ? m : n);
}
ShelfMatchResult ShelfMatchEvaluate(const ShelfMatchInput *input) {
    ShelfMatchResult result = {ShelfMatchRejected, ShelfMatchMissingIdentity, 0};
    if (!input) return result;
    size_t title = bounded_length(input->requested_title);
    size_t artist = bounded_length(input->requested_artist);
    size_t candidate = bounded_length(input->candidate_title);
    size_t owner = bounded_length(input->candidate_artist);
    if (!title || !artist || !candidate || title > 1024 || artist > 1024 ||
        candidate > 1024 || owner > 1024) return result;
    if (input->live_stream) { result.reason = ShelfMatchLiveStream; return result; }
    if (input->requested_versions != input->candidate_versions) {
        result.reason = ShelfMatchWrongVersion; return result;
    }
    char artist_title[2049], title_artist[2049];
    snprintf(artist_title, sizeof artist_title, "%s%s", input->requested_artist, input->requested_title);
    snprintf(title_artist, sizeof title_artist, "%s%s", input->requested_title, input->requested_artist);
    int compound = !strcmp(input->candidate_title, artist_title) || !strcmp(input->candidate_title, title_artist);
    int credited = input->candidate_artist && !strcmp(input->candidate_artist, input->requested_artist);
    if (!credited && !compound) { result.reason = ShelfMatchWrongArtist; return result; }
    int exact = !strcmp(input->candidate_title, input->requested_title) || compound;
    if (!exact && similarity(input->candidate_title, input->requested_title) < 0.88) {
        result.reason = ShelfMatchWrongTitle; return result;
    }
    result.score = (exact ? 55 : 40) + (credited ? 30 : 25);
    if (credited && input->verified_channel) result.score += 5;
    if (!isfinite(input->requested_duration) || !isfinite(input->candidate_duration) ||
        input->requested_duration <= 0 || input->candidate_duration <= 0) {
        result.decision = ShelfMatchReview; result.reason = ShelfMatchUnknownDuration; return result;
    }
    if (fabs(input->requested_duration - input->candidate_duration) > 4.0) {
        result.decision = ShelfMatchRejected; result.reason = ShelfMatchWrongDuration; return result;
    }
    result.score += 10;
    result.decision = exact && credited && result.score >= 95 ? ShelfMatchAutomatic : ShelfMatchReview;
    result.reason = exact ? ShelfMatchExact : ShelfMatchSimilarTitle;
    return result;
}
