// Shapes shared by the main process and the window. Tracks, playlists and followed artists use the
// same JSON as the phone app, so they sync both ways without conversion.

/** A song (backed by a YouTube video ID). Unknown fields from the phone are kept as they are. */
export interface Track {
  id: string
  title: string
  artist: string
  album?: string | null
  duration?: number | null
  artworkURL?: string | null
  podcast?: boolean | null
  channelID?: string | null
  channelAvatar?: string | null
  /** Seconds since 2001-01-01 (how the phone stores dates). */
  published?: number | null
  /** A regular YouTube upload rather than a YouTube Music song. */
  upload?: boolean | null
  /** Marked explicit on YouTube Music (the "E" badge). */
  explicit?: boolean | null
  /** Picked by hand with "Replace with another version": played exactly as it is. */
  chosen?: boolean | null
  /** When it was added to this playlist or Liked songs (seconds since 2001, like the phone). */
  added?: number | null
  /** Collaborative playlists: who added it (their profile ID). */
  addedBy?: string | null
  /** A podcast episode from a show's feed: its audio file (not on YouTube). */
  audioURL?: string | null
  /** …and the feed it's from (to open its show). */
  feedURL?: string | null
  [extra: string]: unknown
}

export type CoverStyle = 'auto' | 'color' | 'photo'

export interface Playlist {
  /** Upper-case UUID, same as on the phone. */
  id: string
  name: string
  tracks: Track[]
  colorIndex: number
  coverStyle?: CoverStyle | null
  coverSymbol?: string | null
  isPublic?: boolean | null
  isAlbum?: boolean | null
  albumArtist?: string | null
  /** Custom cover photo (base64 JPEG), synced with the phone. */
  cover?: string | null
  /** Collaborative: shared with friends who can add, remove and move songs too. */
  collab?: CollabInfo | null
}

export interface CollabInfo {
  /** Who made it (their profile ID). */
  owner: string
  members: string[]
  /** Profile ID → username. */
  names: Record<string, string>
}

/** What the Edit playlist window can change. */
export interface PlaylistChange {
  name?: string
  coverStyle?: CoverStyle
  colorIndex?: number
  /** Base64 JPEG, or null to remove the photo. */
  cover?: string | null
  isPublic?: boolean
}

export interface ArtistRef {
  id: string
  name: string
  thumbnail?: string | null
}

export interface AlbumRef {
  id: string
  title: string
  subtitle: string
  thumbnail?: string | null
}

export interface BrowseRef {
  id: string
  params?: string | null
}

export interface NewRelease {
  album: AlbumRef
  artistName: string
  /** Seconds since 2001-01-01. */
  foundAt: number
}

export interface FollowedArtist {
  artist: ArtistRef
  followedAt: number
  known: string[]
  newReleases: NewRelease[]
}

export interface ArtistPage {
  id: string
  name: string
  thumbnail?: string | null
  subtitle?: string | null
  topSongs: Track[]
  albums: AlbumRef[]
  singles: AlbumRef[]
  albumsMore?: BrowseRef | null
  singlesMore?: BrowseRef | null
}

export interface AlbumPage {
  id: string
  title: string
  subtitle: string
  artist: string
  thumbnail?: string | null
  tracks: Track[]
  /** The album is marked explicit. */
  explicit?: boolean
  /** Other editions (clean/explicit, deluxe…). */
  otherVersions?: (AlbumRef & { explicit?: boolean })[]
  /** Opened the explicit edition instead of this clean one. */
  cleanId?: string
}

export interface SearchResults {
  songs: Track[]
  videos: Track[]
  artists: ArtistRef[]
  albums: AlbumRef[]
}

export interface Library {
  liked: Track[]
  playlists: Playlist[]
  artists: FollowedArtist[]
  /** Recently played on this computer (not synced). */
  recent: Track[]
}

export type UIStyle = 'drift' | 'music'
export type Appearance = 'device' | 'dark' | 'light'

export interface Settings {
  style: UIStyle
  /** The icon in the Apple Music style. */
  musicIcon: 'pink' | 'white'
  appearance: Appearance
  accent: number
  preferOfficialAudio: boolean
  /** Play the explicit (uncensored) version of a song when there is one. */
  preferExplicit: boolean
  volume: number
  /** Start Drift when signing in to the computer (Windows and Mac). */
  openAtLogin: boolean
  /** Skip intros, outros and talking in music videos (SponsorBlock). */
  skipNonMusic: boolean
  /** Skip sponsor reads and reminders in episodes (SponsorBlock). */
  skipSponsors: boolean
  podcastSpeed: number
  /** Share what's playing with an Orbit server. */
  orbitEnabled: boolean
  /** e.g. https://orbit.example.com or http://192.168.1.20:3000 */
  orbitUrl: string
  /** Show what's playing on Discord (needs the Discord app on this computer). */
  discordEnabled: boolean
  discordAppId: string
  /** Closing the window keeps Drift playing in the tray (Windows and Linux). */
  closeToTray: boolean
  /** Show the video of podcast episodes. */
  podcastVideo: boolean
  /** Highest video quality (lines): 480, 720 or 1080. */
  videoQuality: number
}

/** What the player is doing, for friends, Orbit, Discord and the tray. */
export interface PlayerPresence {
  track: Track | null
  playing: boolean
  /** Seconds. */
  position: number
  duration: number
}

export interface ConnectionState {
  state: 'off' | 'ok' | 'error' | 'waiting'
  message?: string
}

export interface ConnectionsStatus {
  orbit: ConnectionState & { hasToken: boolean }
  discord: ConnectionState
}

export interface Account {
  linked: boolean
  uid?: string
  username?: string
  /** Shown instead of the username when set. */
  displayName?: string
  /** Profile photo as a data URL. */
  avatar?: string
  syncing: boolean
  lastSync?: number
  error?: string
}

export type PairingState =
  | { phase: 'idle' }
  | { phase: 'starting' }
  | { phase: 'waiting'; code: string; expires: number }
  | { phase: 'linking' }
  | { phase: 'done' }
  | { phase: 'failed'; message: string }

export interface LyricLine {
  time: number
  text: string
}

/** A chapter of an episode. */
export interface Chapter {
  title: string
  /** Seconds from the start. */
  start: number
  thumbnail?: string
}

export type Lyrics =
  | { kind: 'synced'; lines: LyricLine[]; source: string }
  | { kind: 'plain'; text: string; source: string }
  | { kind: 'none' }

export interface StreamInfo {
  /** The video that actually plays (the album version of a music video, when there is one). */
  playId: string
  mime: string
  bitrate: number
  size?: number
  duration?: number
  client: string
  note: string
}

export interface UpdateState {
  phase: 'idle' | 'checking' | 'none' | 'downloading' | 'ready' | 'available' | 'error' | 'dev'
  /** The new version. */
  version?: string
  percent?: number
  message?: string
  /** Where to download it by hand (Mac, where updates can't install themselves). */
  url?: string
}

/** A song that couldn't be found when importing. */
export interface MissingSong {
  title: string
  artist: string
  duration?: number | null
}

/** One of Drift's own notifications (import reports, like on the phone). */
export interface AppNotice {
  id: string
  kind: 'importReport'
  /** Milliseconds. */
  date: number
  title: string
  detail: string
  read: boolean
  playlistId?: string
  listName?: string
  missing: MissingSong[]
  retrying?: boolean
}

export interface ImportState {
  phase: 'idle' | 'reading' | 'matching' | 'done' | 'failed'
  listName?: string
  total: number
  processed: number
  missing: MissingSong[]
  playlistId?: string
  /** Only the first 100 songs could be read (albums, or playlists when the full page didn't work). */
  hitLimit?: boolean
  /** How many songs Spotify says the playlist has, when fewer could be read. */
  spotifyTotal?: number
  startedAt?: number
  /** When matching started (for the time estimate). */
  matchStart?: number
  error?: string
  /** Songs found again by "Look for these again". */
  foundAgain?: number
  retrying?: boolean
}

export interface DownloadsState {
  /** Downloaded songs (track IDs). */
  done: string[]
  /** Waiting to download. */
  queued: string[]
  active: { id: string; title: string; received: number; total: number }[]
  /** Kept downloaded: "liked" or playlist IDs (new songs in them download too). */
  keep: string[]
  /** Space used, in bytes. */
  bytes: number
  folder: string
  /** Recent download speed, bytes per second. */
  rate: number
  failed: { id: string; title: string; error: string }[]
}

/** A Drift profile as others see it. */
export interface UserProfile {
  id: string
  username: string
  /** Profile photo as a data URL. */
  avatar?: string
  following: string[]
  shareActivity: boolean
  nowPlaying?: Track
  playing: boolean
  /** Seconds since 1970. */
  updatedAt?: number
  /** In a Listen Together session (its code), so friends can join. */
  jam?: string | null
  /** Friends may invite them to listen together (null = yes, the default). */
  allowInvites?: boolean | null
  /** The name shown everywhere (capitals, spaces, emoji welcome); the username stays unique. */
  displayName?: string | null
}

/** What to call someone: their display name, or their username until they set one. */
export function nameOf(u: { username: string; displayName?: string | null }): string {
  return u.displayName?.trim() || u.username
}

/** Display names: one line, at most this many characters (same as the phone). */
export const displayNameLimit = 30

/** For searching: lowercase, without accents ("João" is found by "joao"), like the phone. */
export function searchKey(s: string): string {
  return s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
}

/** An invite to listen together, from a friend. */
export interface JamInvite {
  from: string
  fromName: string
  code: string
  title: string
  artist: string
  /** Milliseconds since 1970. */
  at: number
}

/** Listen Together: what everyone in the session hears. */
export interface JamState {
  code: string
  host: string
  members: string[]
  /** Profile ID → username. */
  names: Record<string, string>
  track?: Track | null
  /** What plays after it. */
  queue: Track[]
  playing: boolean
  /** Position (seconds) at `at`. */
  position: number
  /** When `position` was true (milliseconds, the server's clock). */
  at: number
  version: number
  updatedBy: string
  /** This computer's clock minus the server's (milliseconds). */
  offset: number
  me: string
}

/** What this computer sends when someone here changes what's playing. */
export interface JamChange {
  track: Track | null
  queue: Track[]
  playing: boolean
  position: number
}

/** A playlist someone shows on their profile. */
export interface SharedPlaylist {
  id: string
  ownerId: string
  ownerName: string
  name: string
  count: number
  duration: number
  colorIndex: number
  style: CoverStyle
  /** Cover photo (base64 JPEG). */
  cover?: string
  /** First songs, for the cover. */
  preview: Track[]
}

/** A followed podcast (same shape as the phone's): a YouTube channel, or a show with its own feed. */
export interface PodcastChannel {
  id: string
  name: string
  avatarURL?: string | null
  subtitle?: string | null
  /** A show from its feed (RSS) rather than a YouTube channel. */
  feedURL?: string | null
}

/** Where an episode was left off. */
export interface EpisodeProgress {
  track: Track
  position: number
  duration: number
  /** Milliseconds since 1970. */
  updated: number
  finished: boolean
}

export interface PodcastsState {
  subscriptions: PodcastChannel[]
  progress: Record<string, EpisodeProgress>
  feeds: Record<string, Track[]>
  refreshing: boolean
}

/** A part of a video the SponsorBlock community marked as skippable. */
export interface SkipSegment {
  start: number
  end: number
  category: string
}

export interface AppInfo {
  version: string
  platform: string
}

/** Everything the window can ask the main process for. */
export interface DriftApi {
  appInfo(): Promise<AppInfo>
  search(query: string): Promise<SearchResults>
  suggestions(query: string): Promise<string[]>
  artist(id: string, name?: string): Promise<ArtistPage>
  findArtist(name: string): Promise<ArtistRef | null>
  /** `exact`: the album asked for, even when it's clean and an explicit edition exists. */
  album(id: string, exact?: boolean): Promise<AlbumPage>
  findAlbum(title: string, artist: string): Promise<AlbumRef | null>
  discography(ref: BrowseRef): Promise<AlbumRef[]>
  radio(trackId: string): Promise<Track[]>
  prepare(track: Track): Promise<StreamInfo>
  /** Gets the next songs ready in the background. */
  prefetch(tracks: Track[]): Promise<void>
  /** Any YouTube video (fan uploads, live sets…), or the video behind a pasted link. */
  searchYouTube(query: string, more?: string): Promise<{ tracks: Track[]; more?: string }>
  /** Every version of a song on YouTube Music, clean ones included (for replacing a song). */
  versions(query: string): Promise<Track[]>
  /** Listen Together: start a session, join one (code), leave it, send a change, the current state. */
  jamStart(): Promise<JamState>
  jamJoin(code: string): Promise<JamState>
  jamLeave(): Promise<void>
  jamPublish(change: JamChange): Promise<void>
  jamState(): Promise<JamState | null>
  /** Collaborative playlists: make one of yours shared (or change who's in it), leave, stop sharing. */
  collabShare(playlistId: string, people: { id: string; username: string }[]): Promise<void>
  collabLeave(playlistId: string): Promise<void>
  collabStop(playlistId: string): Promise<void>
  collabSync(): Promise<void>
  /** A shared playlist on screen (checked every few seconds), or null. */
  collabWatch(id: string | null): Promise<void>
  /** Swaps the song at a place in a playlist (or Liked songs) for another version. */
  replaceTrack(place: { playlistId: string } | { liked: true }, index: number, oldId: string, track: Track): Promise<void>
  lyrics(track: Track): Promise<Lyrics>
  /** An episode's chapters (from YouTube, or the timestamps in its description). */
  chapters(id: string): Promise<Chapter[]>
  /** The video heights an episode offers (e.g. [360, 720, 1080]). */
  videoQualities(id: string): Promise<number[]>

  library(): Promise<Library>
  setLiked(track: Track, liked: boolean): Promise<void>
  createPlaylist(name: string, tracks: Track[]): Promise<string>
  addToPlaylist(id: string, tracks: Track[]): Promise<void>
  removeFromPlaylist(id: string, indexes: number[]): Promise<void>
  movePlaylistTrack(id: string, from: number, to: number): Promise<void>
  renamePlaylist(id: string, name: string): Promise<void>
  updatePlaylist(id: string, change: PlaylistChange): Promise<void>
  deletePlaylist(id: string): Promise<void>
  saveAlbum(page: AlbumPage): Promise<string>
  follow(artist: ArtistRef, page: ArtistPage | null): Promise<void>
  unfollow(id: string): Promise<void>
  played(track: Track): Promise<void>
  checkNewReleases(): Promise<void>

  settings(): Promise<Settings>
  setSettings(change: Partial<Settings>): Promise<Settings>

  account(): Promise<Account>
  syncNow(): Promise<void>
  startPairing(): Promise<void>
  cancelPairing(): Promise<void>
  pairing(): Promise<PairingState>
  unlink(): Promise<void>

  openExternal(url: string): Promise<void>

  startImport(link: string): Promise<void>
  importState(): Promise<ImportState>
  retryMissing(): Promise<void>
  notifications(): Promise<AppNotice[]>
  markNotificationsRead(): Promise<void>
  removeNotification(id: string): Promise<void>
  /** Looks for an import report's missing songs again. */
  retryReport(id: string): Promise<void>
  clearImport(): Promise<void>

  downloads(): Promise<DownloadsState>
  downloadedTracks(): Promise<Track[]>
  download(tracks: Track[]): Promise<void>
  removeDownloads(ids: string[]): Promise<void>
  keepDownloaded(collection: string, keep: boolean): Promise<void>
  removeAllDownloads(): Promise<void>
  openDownloadsFolder(): Promise<void>
  retryFailedDownloads(): Promise<void>

  me(): Promise<UserProfile | null>
  friends(): Promise<UserProfile[]>
  /** Several profiles at once (someone's following list). */
  users(ids: string[]): Promise<UserProfile[]>
  followers(id?: string): Promise<UserProfile[]>
  user(id: string): Promise<UserProfile | null>
  searchUsers(text: string): Promise<UserProfile[]>
  followUser(id: string, follow: boolean): Promise<UserProfile | null>
  sharedPlaylists(user: UserProfile): Promise<SharedPlaylist[]>
  sharedPlaylistTracks(ownerId: string, id: string): Promise<Track[]>
  setShareActivity(on: boolean): Promise<void>
  setAllowInvites(on: boolean): Promise<void>
  /** Invites friends (profile ids) to a Listen Together session; returns the ids it couldn't invite. */
  jamInvite(friendIds: string[], code: string, track: Track): Promise<string[]>
  /** Clears an invite once answered. */
  jamInviteAnswered(invite: JamInvite): Promise<void>
  usernameAvailable(name: string): Promise<boolean | null>
  updateProfile(change: { username?: string; displayName?: string; avatar?: string | null }): Promise<UserProfile | null>
  setPrivateSession(on: boolean): Promise<void>
  playerState(state: PlayerPresence): Promise<void>
  connections(): Promise<ConnectionsStatus>
  setOrbitToken(token: string): Promise<void>
  testOrbit(): Promise<void>

  podcasts(): Promise<PodcastsState>
  searchPodcasts(query: string): Promise<{ channels: PodcastChannel[]; episodes: Track[] }>
  /** Shows in Apple's podcast directory, or the show behind a pasted feed link. */
  searchShows(query: string): Promise<PodcastChannel[]>
  /** The podcasts on a YouTube channel's Podcasts tab. */
  channelPodcasts(channel: PodcastChannel): Promise<PodcastChannel[]>
  channelEpisodes(channel: PodcastChannel): Promise<Track[]>
  followChannel(channel: PodcastChannel, follow: boolean): Promise<void>
  refreshPodcasts(force: boolean): Promise<void>
  episodeProgress(track: Track, position: number, duration: number): Promise<void>
  markPlayed(track: Track, played: boolean): Promise<void>
  videoFromLink(link: string): Promise<Track | null>
  skipSegments(id: string, podcast: boolean): Promise<SkipSegment[]>

  updateState(): Promise<UpdateState>
  checkForUpdates(): Promise<void>
  installUpdate(): Promise<void>
}

export type DriftEvent = 'library' | 'settings' | 'account' | 'pairing' | 'media' | 'update' | 'import' | 'downloads' | 'me' | 'podcasts' | 'connections' | 'notifications' | 'openNotice' | 'jam' | 'jamEnded' | 'jamInvite'

export const apiMethods: (keyof DriftApi)[] = [
  'appInfo', 'search', 'suggestions', 'artist', 'findArtist', 'album', 'findAlbum', 'discography', 'radio',
  'prepare', 'prefetch', 'jamStart', 'jamJoin', 'jamLeave', 'jamPublish', 'jamState', 'collabShare', 'collabLeave', 'collabStop', 'collabSync', 'collabWatch', 'searchYouTube', 'versions', 'replaceTrack', 'lyrics', 'chapters', 'videoQualities', 'library', 'setLiked', 'createPlaylist', 'addToPlaylist', 'removeFromPlaylist',
  'movePlaylistTrack', 'renamePlaylist', 'updatePlaylist', 'deletePlaylist', 'saveAlbum', 'follow', 'unfollow', 'played',
  'checkNewReleases', 'settings', 'setSettings', 'account', 'syncNow', 'startPairing', 'cancelPairing',
  'pairing', 'unlink', 'openExternal', 'updateState', 'checkForUpdates', 'installUpdate',
  'startImport', 'importState', 'retryMissing', 'notifications', 'markNotificationsRead', 'removeNotification', 'retryReport', 'clearImport',
  'downloads', 'downloadedTracks', 'download', 'removeDownloads', 'keepDownloaded', 'removeAllDownloads',
  'openDownloadsFolder', 'retryFailedDownloads',
  'me', 'friends', 'users', 'followers', 'user', 'searchUsers', 'followUser', 'sharedPlaylists', 'sharedPlaylistTracks',
  'setShareActivity', 'setAllowInvites', 'jamInvite', 'jamInviteAnswered', 'usernameAvailable', 'updateProfile', 'setPrivateSession', 'playerState', 'connections', 'setOrbitToken', 'testOrbit',
  'podcasts', 'searchPodcasts', 'searchShows', 'channelPodcasts', 'channelEpisodes', 'followChannel', 'refreshPodcasts', 'episodeProgress', 'markPlayed',
  'videoFromLink', 'skipSegments'
]

/** The phone stores dates as seconds since 2001-01-01. */
export const appleEpoch = 978307200
export const nowApple = (): number => Date.now() / 1000 - appleEpoch
