import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import { back, forward, fullPlayerStore, go, navStore, platformStore, settingsStore, useRoute, useStore } from './state'
import type { Route } from './state'
import { next, previous, toggle } from './player'
import { accents, musicRed } from './util'
import { ContextMenu, DialogHost, Toast } from './ui'
import {
  DriftPlayerBar, DriftSidebar, FullPlayer, LyricsView, MusicSidePanel, MusicSidebar, MusicTopPlayer, SidePanel, TopBar
} from './layout'
import { AlbumPage, ArtistPage, HomePage, SearchBox, SearchPage } from './views/browse'
import { CollectionPage, LikedPage, PlaylistPage } from './views/collections'
import { SongPage } from './views/details'
import { SettingsPage } from './views/settings'
import { ImportDialog } from './views/import'

function useDark(): boolean {
  const appearance = useStore(settingsStore).appearance
  const [system, setSystem] = useState(() => window.matchMedia('(prefers-color-scheme: dark)').matches)
  useEffect(() => {
    const m = window.matchMedia('(prefers-color-scheme: dark)')
    const f = (): void => setSystem(m.matches)
    m.addEventListener('change', f)
    return () => m.removeEventListener('change', f)
  }, [])
  return appearance === 'dark' || (appearance === 'device' && system)
}

function Page({ route }: { route: Route }): JSX.Element {
  switch (route.name) {
    case 'home':
      return <HomePage />
    case 'search':
      return <SearchPage q={route.q ?? ''} />
    case 'artist':
      return <ArtistPage key={route.id} id={route.id} hint={route.hint} />
    case 'album':
      return <AlbumPage key={route.id} id={route.id} hint={route.hint} />
    case 'playlist':
      return <PlaylistPage key={route.id} id={route.id} />
    case 'liked':
      return <LikedPage />
    case 'collection':
      return <CollectionPage key={route.kind} kind={route.kind} />
    case 'song':
      return <SongPage key={route.track.id} track={route.track} />
    case 'settings':
      return <SettingsPage />
    case 'lyrics':
      return <LyricsView />
  }
}

function useShortcuts(): void {
  useEffect(() => {
    const key = (e: KeyboardEvent): void => {
      const target = e.target as HTMLElement
      const typing = target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable
      const mod = e.ctrlKey || e.metaKey
      if (e.code === 'Space' && !typing && target.getAttribute('role') !== 'slider') {
        e.preventDefault()
        toggle()
      } else if (mod && e.key === 'ArrowRight') {
        e.preventDefault()
        next()
      } else if (mod && e.key === 'ArrowLeft') {
        e.preventDefault()
        previous()
      } else if (mod && (e.key === 'l' || e.key === 'k' || e.key === 'f')) {
        e.preventDefault()
        if (useRouteName() !== 'search') go({ name: 'search' })
        window.setTimeout(() => window.dispatchEvent(new Event('drift:focus-search')), 30)
      } else if (e.altKey && e.key === 'ArrowLeft') {
        back()
      } else if (e.altKey && e.key === 'ArrowRight') {
        forward()
      } else if (mod && e.key === ',') {
        go({ name: 'settings' })
      }
    }
    // Mouse side buttons go back and forward.
    const mouse = (e: MouseEvent): void => {
      if (e.button === 3) back()
      if (e.button === 4) forward()
    }
    window.addEventListener('keydown', key)
    window.addEventListener('mouseup', mouse)
    return () => {
      window.removeEventListener('keydown', key)
      window.removeEventListener('mouseup', mouse)
    }
  }, [])
}

const useRouteName = (): string => navStore.get().stack[navStore.get().index].name

export function App(): JSX.Element {
  const settings = useStore(settingsStore)
  const platform = useStore(platformStore)
  const dark = useDark()
  const route = useRoute()
  const full = useStore(fullPlayerStore)
  useShortcuts()

  useEffect(() => {
    const root = document.documentElement
    root.dataset.style = settings.style
    root.dataset.theme = dark ? 'dark' : 'light'
    root.dataset.platform = platform
    const accent = settings.style === 'music' ? musicRed : (accents[settings.accent] ?? accents[0])[dark ? 'dark' : 'light']
    root.style.setProperty('--accent', accent)
    root.style.setProperty('--accent-bright', settings.style === 'music' ? musicRed : (accents[settings.accent] ?? accents[0]).dark)
  }, [settings.style, settings.accent, dark, platform])

  if (settings.style === 'music') {
    return (
      <div className={`app music ${full ? 'full-open' : ''}`}>
        <div className="titlebar" />
        <div className="m-body">
          <MusicSidebar />
          <div className="m-main">
            <MusicTopPlayer />
            <div className="m-content">
              <main className="main-scroll">
                <Page route={route.name === 'lyrics' ? { name: 'home' } : route} />
              </main>
              <MusicSidePanel />
            </div>
          </div>
        </div>
        <FullPlayer />
        <ContextMenu />
        <ImportDialog />
        <DialogHost />
        <Toast />
      </div>
    )
  }

  return (
    <div className="app drift">
      <div className="titlebar" />
      <div className="d-body">
        <DriftSidebar />
        <main className={`panel main ${route.name === 'lyrics' ? 'lyrics-mode' : ''}`}>
          {route.name !== 'lyrics' && <TopBar>{route.name === 'search' ? <SearchBox q={route.q ?? ''} /> : null}</TopBar>}
          <div className="main-scroll">
            <Page route={route} />
          </div>
        </main>
        <SidePanel />
      </div>
      <DriftPlayerBar />
      <ContextMenu />
      <ImportDialog />
      <DialogHost />
      <Toast />
    </div>
  )
}
