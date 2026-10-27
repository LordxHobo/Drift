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
  appearance: Appearance
  accent: number
  preferOfficialAudio: boolean
  volume: number
  /** Start Drift when signing in to the computer (Windows and Mac). */
  openAtLogin: boolean
}

export interface Account {
  linked: boolean
  uid?: string
  username?: string
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
  album(id: string): Promise<AlbumPage>
  findAlbum(title: string, artist: string): Promise<AlbumRef | null>
  discography(ref: BrowseRef): Promise<AlbumRef[]>
  radio(trackId: string): Promise<Track[]>
  prepare(track: Track): Promise<StreamInfo>
  lyrics(track: Track): Promise<Lyrics>

  library(): Promise<Library>
  setLiked(track: Track, liked: boolean): Promise<void>
  createPlaylist(name: string, tracks: Track[]): Promise<string>
  addToPlaylist(id: string, tracks: Track[]): Promise<void>
  removeFromPlaylist(id: string, indexes: number[]): Promise<void>
  movePlaylistTrack(id: string, from: number, to: number): Promise<void>
  renamePlaylist(id: string, name: string): Promise<void>
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

  updateState(): Promise<UpdateState>
  checkForUpdates(): Promise<void>
  installUpdate(): Promise<void>
}

export type DriftEvent = 'library' | 'settings' | 'account' | 'pairing' | 'media' | 'update'

export const apiMethods: (keyof DriftApi)[] = [
  'appInfo', 'search', 'suggestions', 'artist', 'findArtist', 'album', 'findAlbum', 'discography', 'radio',
  'prepare', 'lyrics', 'library', 'setLiked', 'createPlaylist', 'addToPlaylist', 'removeFromPlaylist',
  'movePlaylistTrack', 'renamePlaylist', 'deletePlaylist', 'saveAlbum', 'follow', 'unfollow', 'played',
  'checkNewReleases', 'settings', 'setSettings', 'account', 'syncNow', 'startPairing', 'cancelPairing',
  'pairing', 'unlink', 'openExternal', 'updateState', 'checkForUpdates', 'installUpdate'
]

/** The phone stores dates as seconds since 2001-01-01. */
export const appleEpoch = 978307200
export const nowApple = (): number => Date.now() / 1000 - appleEpoch
