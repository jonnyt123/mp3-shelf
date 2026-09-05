# MP3 Shelf

An iPhone-first, installable web app that imports many MP3s in one Files picker and keeps them in a searchable offline library. It includes persistent playlists, shuffle, repeat-one/repeat-all, previous/next controls, and automatic next-track playback.

## Run locally

```bash
npm install
npm run dev
```

On iPhone, deploy over HTTPS, open it in Safari, then use **Share → Add to Home Screen**.

## What iOS allows

Safari cannot scan Files automatically. The user must grant access through Apple's picker. MP3 Shelf uses multiple selection so a group can be imported at once, then stores copies in IndexedDB. Clearing Safari website data or iOS storage eviction can remove local tracks.

## Optional Supabase sync

The MVP is local-first and needs no account. `supabase/migrations/0001_cloud_library.sql` defines a private per-user catalog and Storage bucket for later cloud sync. Large audio uploads should use Supabase's TUS resumable endpoint.

## Verification

```bash
npm test
npm run typecheck
npm run build
```
