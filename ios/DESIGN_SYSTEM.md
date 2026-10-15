# MP3 Shelf — iOS Visual Design System

## Creative direction

A considered, premium, dark-first music experience. Color should feel like a
limited-edition album sleeve—not a casino dashboard. Quiet neutral surfaces
allow a single colorful piece of artwork or high-value action to command the
screen. Never add multiple competing gradients, neon glows on every element,
or decorative textures behind dense text.

## Core tokens

| Purpose | SwiftUI token | Approx. color |
|---|---|---|
| Canvas | `ShelfTheme.background` | `#0B0D13` obsidian |
| Cards | `ShelfTheme.surface` | `#161A25` charcoal navy |
| Raised controls | `ShelfTheme.elevated` | `#1D212E` |
| Primary interaction | `ShelfTheme.accent` | `#B69CFE` soft violet |
| Secondary identity | `ShelfTheme.coral` | `#FD917C` muted coral |
| Verified/offline/active | `ShelfTheme.mint` | `#74DDC7` sea glass |
| Supporting text | `ShelfTheme.subdued` | `#A5ACBC` |
| Borders | `ShelfTheme.border` | White @ 9% |

Use bright colors sparingly. Purple is interactive, sea glass signifies offline
success, and coral differentiates creation/playlist destinations. Do not use
red/green purely decoratively in status workflows. Avoid unsupported color-only
state communication.

## Layout and type

- Use SwiftUI semantic system fonts with rounded design for headlines; preserve
  Dynamic Type, VoiceOver, and native text truncation.
- Default horizontal safe-area padding: 20–27pt, not fixed screen positions.
- Card corner radii: 18–25pt; editorial hero panels up to 28pt.
- Artwork is square, large when featured, with subtle 19% corner rounding.
- Use `PremiumEyebrow` for uppercase metadata, `PremiumSectionHeading` for
  content hierarchy, `PremiumIcon` for consistent restrained color, and
  `PremiumBackdrop` as the soft ambient background.
- Controls should retain comfortable hit targets (~44pt), including mini-player
  actions and song overflow menus.
- Use thin 1pt neutral borders and occasional soft shadow rather than outlines
  and shadows everywhere.

## Screen patterns

- **Library:** human, editorial offline headline; one rich featured panel;
  segmented favorites; neutral song cards with active-song accent.
- **Playlists:** colored, generated artwork tiles; clear counts; separate
  import/Spotify entry point.
- **Now Playing:** album artwork is the focal point; progress and playback are
  highly legible; only one dominant violet play control.
- **Mini-player:** a restrained glass dock above the system tab bar; subtle
  3pt progress line; don't obstruct tabs.
- **Imports/settings/downloads:** neutral utility cards, carefully chosen
  icon accents, minimal visual noise. Respect provider licensing text.
- **Lyrics:** active lyric line in mint and muted surrounding text, with
  generous line spacing.

## Accessibility and regression rules

Do not remove functional playlist/source/download controls for aesthetics.
Contrast, line truncation, reduced-motion preferences, keyboard and VoiceOver
labels matter more than decorative polish. Respect safe areas and never
hard-code iPhone dimensions. Test narrow phones and large Dynamic Type. Keep
music data, files, authentication and transport logic independent of this theme.

## Release validation

The GitHub macOS workflow builds the iOS Simulator target, launches the app,
captures a screenshot, and runs metadata/discovery tests. These checks cannot
prove physical iPhone lock-screen behavior or real-world licensed-source
availability. Keep the visual branch in draft pending device QA.

## First-run and visual QA decisions

- A fresh install with zero songs must expose **Import your music**
  inside the first featured panel, without requiring scrolling on a
  standard iPhone. Offer **Import a Spotify playlist** immediately below.
- A playlist library with zero collections must expose a full-size
  **Create a playlist** button, not just the navigation bar plus icon.
- When local music exists, switch the Listen screen to its library filters,
  song cards and artwork-led featured panel; do not show onboarding again.
- No fake saved songs or placeholder Spotify success states in production.
- Debug Simulator screenshot flags allow visual QA of actual UI without
  modifying customer data: `--mp3shelf-snapshot-playlists`,
  `--mp3shelf-snapshot-add-music`, and `--mp3shelf-snapshot-settings`.
  These flags exist only under `#if DEBUG`; the release always opens Listen.
- The `ios-build.yml` workflow captures real Simulator frames for Listen,
  Playlists, Add Music and Settings and uploads them together as the
  `mp3shelf-premium-all-tabs` artifact. Manual screenshot review is still
  required because a successful compilation does not prove strong layout.
- Verify UI in compact iPhones and at large Dynamic Type sizes, keeping
  the primary action tappable and source/licensing information readable.
