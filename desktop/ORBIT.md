# Drift → Orbit: "Listening to" status (contract v1)

Drift (desktop app) can show what you're listening to on an Orbit server, the way Discord shows
"Listening to Spotify". Drift already sends it; Orbit needs one endpoint, a token and the display.

## How it works

- Drift sends an **activity** to the Orbit server over HTTP(S) whenever something changes (new song,
  play/pause, a jump of more than 3 seconds), plus a **heartbeat every 60 seconds** while playing.
- When nothing plays (stopped, private session, Drift closing, sharing turned off) Drift sends a
  **DELETE** to clear it.
- If Orbit hears nothing for `expiresInMs` (180 s), it clears the activity itself (crash, sleep,
  network loss). This is the safety net; Orbit must not rely on getting the DELETE.
- It's server-to-server style: Drift's main process sends it (no browser, no CORS). It works from any
  computer, and the phone app can use the same endpoint later.

## What the user sets up

1. In Orbit: **User Settings → Connections → Drift → Create token**. Orbit shows the token once.
2. In Drift: **Settings → Connections → Orbit**: turn it on, enter the **server address** (for example
   `https://orbit.example.com` or `http://192.168.1.20:3000` on the home network) and paste the
   **token**. "Test connection" sends the current song (or a clear) right away.

Drift calls `{serverAddress}/api/integrations/drift/activity`, with any trailing `/` removed from the
address. If Orbit's API lives somewhere else (for example behind `/orbit`), the user includes that in
the address.

## Endpoint

### `PUT /api/integrations/drift/activity` (set or refresh)

Headers:

```
Authorization: Bearer <token>
Content-Type: application/json
User-Agent: Drift/<version>
X-Drift-Activity-Version: 1
```

Body:

```json
{
  "app": "Drift",
  "type": "listening",
  "state": "playing",
  "track": {
    "id": "dQw4w9WgXcQ",
    "title": "Song title",
    "artist": "Artist name",
    "album": "Album name",
    "artworkUrl": "https://lh3.googleusercontent.com/...=w544-h544",
    "durationMs": 212000,
    "url": "https://music.youtube.com/watch?v=dQw4w9WgXcQ"
  },
  "positionMs": 34000,
  "startedAt": 1793100000000,
  "sentAt": 1793100034000,
  "expiresInMs": 180000
}
```

| Field | Type | Notes |
|---|---|---|
| `app` | `"Drift"` | Always "Drift". Orbit can show it as the app name. |
| `type` | `"listening"` \| `"podcast"` | `podcast` = a podcast episode or YouTube video ("Listening to a podcast"). |
| `state` | `"playing"` \| `"paused"` | Paused activities are sent once; no heartbeats while paused, so they expire after `expiresInMs`. |
| `track.id` | string (11 chars) | YouTube video ID. Stable per song. |
| `track.title` | string | Up to ~200 chars in practice. Orbit should trim to its own limit. |
| `track.artist` | string | May be empty for some uploads. |
| `track.album` | string \| null | |
| `track.artworkUrl` | https URL | From `i.ytimg.com`, `lh3.googleusercontent.com` or `yt3.ggpht.com`. Square for songs, 16:9 for videos. Orbit may proxy or cache it. |
| `track.durationMs` | number \| null | null when unknown (rare, some videos). |
| `track.url` | https URL | Link to open the song (YouTube Music for songs, YouTube for uploads and podcasts). |
| `positionMs` | number | Position when sent. |
| `startedAt` | epoch ms \| null | When position 0 would have been (`sentAt - positionMs`). Only while playing; null when paused. Use it for a live progress bar. |
| `sentAt` | epoch ms | Drift's clock when sent; use with the server's clock to correct clock differences. |
| `expiresInMs` | number | How long to keep showing it without another PUT (180000). |

Answer **204 No Content** (or 200). Drift treats 2xx as success.

### `DELETE /api/integrations/drift/activity` (clear)

Same `Authorization` header, no body. Answer 204, also when there was nothing to clear.

### Errors Drift understands

| Status | Drift shows |
|---|---|
| 401 / 403 | "Orbit didn't accept the token" (user makes a new one) |
| 404 | "This Orbit server doesn't support Drift yet" |
| 429 | "Orbit asked Drift to slow down" (tries again on the next change or heartbeat) |
| other 4xx/5xx | "Orbit answered <status>" |

Suggested limits: body up to 8 KB; 30 requests per minute per token (Drift normally sends one per
change, at most one every ~1.5 s while skipping through songs, plus one per minute).

## Tokens

- Created per user in Orbit's settings, shown once, stored **hashed** (for example SHA-256), with a
  name ("Drift on Jason-PC"), created date and last-used date. The user can revoke them.
- Only allowed to set and clear that user's Drift activity (no other API access).
- Format is up to Orbit; Drift accepts any string up to a few hundred characters.

## What Orbit does with it

1. **Store** the latest activity per user (in memory is enough, with the expiry timer; optionally
   keep the last one for the profile). A new PUT replaces the old one and restarts the timer.
2. **Clock correction**: `offset = serverNow - sentAt`; use `startedAt + offset` on the server.
3. **Broadcast** over Socket.io to everyone who can see the user (shared servers, DMs, friends), for
   example `presence:activity` with `{ userId, activity }`, and `activity: null` when cleared or
   expired. Include current activities in the initial presence payload on connect.
4. **Show it**:
   - Member list and DM list: a small line under the name, "Listening to **Song** · Artist" with a
     music icon (or "Listening to a podcast").
   - Profile popout: artwork, title, artist, album, a progress bar (playing: `now - startedAt`,
     clamped to `durationMs`; paused: `positionMs`, with "Paused"), and an "Open" button to `track.url`.
5. **Privacy**: a user setting in Orbit to hide their activity from others even when Drift sends it.

## Trying it without Drift

```bash
# set
curl -X PUT "$ORBIT/api/integrations/drift/activity" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"app":"Drift","type":"listening","state":"playing","track":{"id":"dQw4w9WgXcQ","title":"Test song","artist":"Test artist","album":null,"artworkUrl":"https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg","durationMs":212000,"url":"https://music.youtube.com/watch?v=dQw4w9WgXcQ"},"positionMs":0,"startedAt":'"$(date +%s000)"',"sentAt":'"$(date +%s000)"',"expiresInMs":180000}'

# clear
curl -X DELETE "$ORBIT/api/integrations/drift/activity" -H "Authorization: Bearer $TOKEN"
```
