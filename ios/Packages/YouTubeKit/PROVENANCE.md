# YouTubeKit provenance

Source: https://github.com/alexeichhorn/YouTubeKit
Tag: 0.4.8
Commit: 65be95dbb1dbd749499e0638871568c823822276
License: MIT; LICENSE and bundled JavaScript notices retained.

Local changes: platform/product-only package manifest; playlist-scoped URLSession
context used by all local YouTube.swift/InnerTube.swift HTTP calls. The app always
selects `.local`; it does not enable the library's optional remote server fallback.
Local metadata adds author/duration/isLive so the app rechecks the resolved video.
No account cookies or private Spotify audio extraction are part of the integration.
Native Apple compilation and extraction remain unverified in the Linux environment.

Local compatibility changes: exclude pre-iOS-15 data-task shims so Foundation
async cancellation is used; replace unstructured concurrentMap tasks with a
structured task group that inherits cancellation and the session context.

Local requests require an explicit scoped session and validate their initial host
against YouTube/YouTube-nocookie/ytimg/googlevideo before using Foundation.
The caller supplies a matching redirect allowlist and network restrictions.
