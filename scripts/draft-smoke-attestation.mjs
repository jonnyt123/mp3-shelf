/** Verified draft GitHub asset upload attestation, NOT native/iPhone acceptance. */
const SHA = /^[0-9a-f]{40}$/;
const HASH = /^[0-9a-f]{64}$/;
const TAG = /^mp3shelf-upload-smoke-([0-9a-f]{12})-[0-9]{13}-[0-9a-f]{6}$/;
const PREFIX = 'MP3SHELF_DRAFT_UPLOAD_SMOKE_VERIFIED';
const MAX_AGE = 7 * 24 * 60 * 60 * 1000;

export function smokeAttestationLine({ toolingSha, tag, zipSHA256, manifestSHA256 }) {
  if (!SHA.test(toolingSha ?? '') || !TAG.test(tag ?? '') ||
      !tag.startsWith('mp3shelf-upload-smoke-' + toolingSha.slice(0, 12) + '-') ||
      !HASH.test(zipSHA256 ?? '') || !HASH.test(manifestSHA256 ?? ''))
    throw Error('Draft smoke attestation requires exact tooling SHA, unique tag and two archive digests.');
  return PREFIX + ' TOOLING_SHA=' + toolingSha + ' TAG=' + tag +
    ' ZIP_SHA256=' + zipSHA256 + ' MANIFEST_SHA256=' + manifestSHA256 +
    ' RESULT=UPLOAD_DOWNLOAD_VERIFIED_AND_CLEANED';
}
export function verifiedSmokeComment(comment, currentToolingSha, now = Date.now()) {
  if (!SHA.test(currentToolingSha ?? '') ||
      comment?.user?.login !== 'jonnyt123' ||
      typeof comment.body !== 'string' ||
      !Number.isFinite(now)) return null;
  const timestamp = Date.parse(comment.created_at ?? '');
  if (!Number.isFinite(timestamp) || timestamp > now + 5*60*1000 ||
      now - timestamp > MAX_AGE) return null;
  const match = comment.body.trim().match(
    /^MP3SHELF_DRAFT_UPLOAD_SMOKE_VERIFIED TOOLING_SHA=([a-f0-9]{40}) TAG=(mp3shelf-upload-smoke-[a-f0-9]{12}-[0-9]{13}-[a-f0-9]{6}) ZIP_SHA256=([a-f0-9]{64}) MANIFEST_SHA256=([a-f0-9]{64}) RESULT=UPLOAD_DOWNLOAD_VERIFIED_AND_CLEANED$/);
  if (!match || match[1] !== currentToolingSha) return null;
  try {
    const expected = smokeAttestationLine({ toolingSha: match[1], tag: match[2],
      zipSHA256: match[3], manifestSHA256: match[4] });
    if (expected !== comment.body.trim()) return null;
  } catch { return null; }
  return { toolingSha: match[1], tag: match[2],
    zipSHA256: match[3], manifestSHA256: match[4],
    createdAt: comment.created_at, commentID: comment.id };
}
