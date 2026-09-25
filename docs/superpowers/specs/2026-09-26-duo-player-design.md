# Duo Player — Design

A floating macOS Spotify remote that looks and folds like iPhone Duo.
Spotify desktop app (or any Connect device) plays audio; we control it via Web API. Premium required.

## Platform

- Native SwiftUI, macOS 26. `LSUIElement` (no Dock icon).
- One borderless, non-activating `NSPanel`, level `.floating`, draggable by background, transparent background.
- ~20pt transparent margin around the device so tilt/shadow never clip.

## Device states

Screen size W×H (one "screen"). Hinge on the left edge of the cover.

**Closed (cover)** — one screen, W wide.
- Corners: rounded top-right + bottom-right only; left (hinge) edge square.
- Album art fills the screen; title + artist top-left; 2-line synced lyrics strip over the art bottom.
- Side rail on the right edge.

**Open (inner)** — one continuous screen, 2W wide, rounded outer corners only.
- Right half: identical to cover (same position, same content), minus the lyrics strip.
- Left half: new screen with a segmented tab bar at top — **Lyrics · Queue · Library**.

### Side rail (right edge, both states, never moves)
Top → bottom: camera dot, open/close (book icon), previous, play/pause (larger), next.

### Other controls (no overflow menu)
- Scroll over art → volume. Drag progress bar on art → seek.
- Right-click art → Like, Device picker, Lyrics placement (left screen / strip on art).
- Keys: Space play/pause, ←/→ previous/next, ⌘\ open/close.

## Fold animation (page turn)

Open:
1. Panel frame grows left by W (right edge anchored) — cover never moves on screen.
2. The page (left screen) rotates from 0° → 180° around the cover's left edge via `.rotation3DEffect(axis: y, anchor: .leading)`. Closed, it is tucked behind the cover.
3. Only the page's screen is visible (inner left). SwiftUI has no backface culling → page content hidden until past 90°.
4. Blur `18·(1−t)` and black overlay `0.8·(1−t)` on the page; sharp when flat. Album side never blurs.
5. Lyrics strip on art fades out; cover's left corners square→joined.

Close: exact reverse; panel shrinks after the turn ends.

Driven by one `t ∈ [0,1]`, animated with a spring (~0.8s feel).

### Body effect (fake 3D, SwiftUI only)
All driven by `t` with `edge = sin(π·t)`:
- Page edge: separate rounded rect, width `thickness·edge` (~10pt), metal gray, on the page's outer edge.
- Hinge spine: rounded 12pt bar at the hinge, opacity `min(1, 1.6·edge)`.
- Cast shadow: left→right gradient over the album art, opacity `edge` (lighter once past 90°).
- Body tilt: whole device `rotation3DEffect` X `7°·edge`, Y `−9°·edge`.
- Offset backplate behind the cover for thickness.

## Left screen tabs

**Lyrics** — synced lines, current line large/white, past dim, upcoming gray; auto-scroll. "No lyrics" state when none.

**Queue** — `GET /me/player/queue`. Tap row → skip forward to it. No reorder/remove (API can't). Add via right-click "Add to queue" in Library.

**Library** — list/grid toggle in header; grid = 4 columns of covers, name on hover.
- Top level: Liked songs + `/me/playlists`, paginated on scroll.
- Tap playlist → track list (back chevron in pane header). Tap track → play in playlist context.

## Data

**Auth** — Authorization Code + PKCE via `ASWebAuthenticationSession`, custom URL scheme redirect. No client secret, no server. Tokens in Keychain; refresh on 401/expiry.
Scopes: `user-read-playback-state user-modify-playback-state user-read-currently-playing user-library-read user-library-modify playlist-read-private`.

**Playback** — poll `GET /me/player` every 1s; interpolate progress locally between polls. Controls: play, pause, next, previous, seek, volume, `PUT /me/tracks` (like), transfer device.

**Lyrics** — `GET https://lrclib.net/api/get?artist_name&track_name&album_name&duration`. Parse `[mm:ss.xx]` → `[(TimeInterval, String)]`; current line = last with time ≤ progress. In-memory cache by track ID.

## Errors
- No active device → cover shows "Open Spotify to start" + device picker.
- 401 → refresh; refresh fails → sign-in screen.
- 429 → back off using `Retry-After`.
- Lyrics miss/network fail → "No lyrics" (silent).

## Files
- `App.swift` — panel, fold state, keyboard shortcuts.
- `PlayerView.swift` — cover, page, rail, body effect, tabs.
- `Spotify.swift` — auth, polling, API calls.
- `Lyrics.swift` — LRCLIB fetch + LRC parse.

## Testing
One `assert`-based check for the LRC parser + current-line lookup (the only non-trivial pure logic). Rest verified by running the app.

## Out of scope (for now)
Search, Metal shaders, RealityKit, playlist editing, queue reorder, lid-sensor tie-in.
