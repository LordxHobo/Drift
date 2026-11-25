// Folders of playlists in Your Library: make, rename and delete them, and move playlists in and out.
import { useEffect, useState } from 'react'
import type { Library, Playlist, PlaylistFolder, Track } from '@shared/types'
import { dialogStore, drift, libraryStore, readLocal, toast, writeLocal } from '../state'
import type { MenuItem } from '../state'

/** Asks for a name and makes a folder (with these playlists already in it). */
export function newFolder(playlistIds: string[] = []): void {
  dialogStore.set({
    kind: 'prompt',
    title: 'New folder',
    value: '',
    placeholder: 'New folder',
    confirm: 'Create',
    onDone: async (name) => {
      const id = await drift.createFolder(name, playlistIds)
      openFolder(id, true)
      toast(playlistIds.length ? `Moved to ${name.trim() || 'New folder'}` : `Made ${name.trim() || 'New folder'}`)
    }
  })
}

export function folderMenu(f: PlaylistFolder): MenuItem[] {
  return [
    {
      label: 'Rename…',
      icon: 'edit',
      action: () =>
        dialogStore.set({
          kind: 'prompt',
          title: 'Rename folder',
          value: f.name,
          placeholder: f.name,
          confirm: 'Rename',
          onDone: (name) => void drift.renameFolder(f.id, name)
        })
    },
    {
      label: 'Delete folder',
      icon: 'trash',
      danger: true,
      action: () =>
        dialogStore.set({
          kind: 'confirm',
          title: `Delete ${f.name}?`,
          message: 'Its playlists stay in Your Library.',
          confirm: 'Delete',
          danger: true,
          onDone: () => void drift.deleteFolder(f.id)
        })
    }
  ]
}

/** "Move to folder" for a playlist's menu. */
export function moveToFolderItem(p: Playlist): MenuItem {
  const folders = libraryStore.get().folders ?? []
  const inFolder = folders.find((f) => f.id === p.folder)
  return {
    label: 'Move to folder',
    icon: 'folder',
    submenu: [
      { label: 'New folder…', icon: 'plus', action: () => newFolder([p.id]) },
      ...(folders.length ? [{ label: '', separator: true }] : []),
      ...folders.map((f) => ({
        label: f.name,
        icon: f.id === p.folder ? 'check' : 'folder',
        action: () => {
          if (f.id === p.folder) return
          void drift.setPlaylistFolder(p.id, f.id)
          toast(`Moved to ${f.name}`)
        }
      })),
      ...(inFolder
        ? [{ label: '', separator: true }, {
            label: `Take out of ${inFolder.name}`,
            icon: 'close',
            action: () => void drift.setPlaylistFolder(p.id, null)
          }]
        : [])
    ]
  }
}

// Dragging playlists onto folders (the sidebars).
const dragType = 'application/x-drift-playlist'

/** Props for a playlist row that can be dragged. */
export function playlistDragProps(p: Playlist): { draggable: true; onDragStart: (e: React.DragEvent) => void } {
  return {
    draggable: true,
    onDragStart: (e) => {
      e.dataTransfer.setData(dragType, p.id)
      e.dataTransfer.effectAllowed = 'move'
    }
  }
}

/** Props for something playlists can be dropped on: a folder, or (null) the list itself, out of any folder. */
export function folderDropProps(folder: string | null, setOver: (on: boolean) => void): {
  onDragOver: (e: React.DragEvent) => void; onDragLeave: (e: React.DragEvent) => void; onDrop: (e: React.DragEvent) => void
} {
  return {
    onDragOver: (e) => {
      if (!e.dataTransfer.types.includes(dragType)) return
      e.preventDefault()
      e.stopPropagation()
      e.dataTransfer.dropEffect = 'move'
      setOver(true)
    },
    onDragLeave: (e) => {
      if (!(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node)) setOver(false)
    },
    onDrop: (e) => {
      const id = e.dataTransfer.getData(dragType)
      setOver(false)
      if (!id) return
      e.preventDefault()
      e.stopPropagation()
      const lib = libraryStore.get()
      const p = lib.playlists.find((x) => x.id === id)
      if (!p || (p.folder ?? null) === folder) return
      void drift.setPlaylistFolder(id, folder)
      const f = lib.folders?.find((x) => x.id === folder)
      toast(f ? `Moved to ${f.name}` : `Took ${p.name} out of its folder`)
      if (folder) openFolder(folder, true)
    }
  }
}

// Dragging songs onto playlists in the sidebar (from search, albums, artists, Liked songs or another playlist).
const songType = 'application/x-drift-songs'

/** Starts dragging songs: a small label with the song's name follows the pointer. */
export function startSongDrag(e: React.DragEvent, tracks: Track[]): void {
  e.dataTransfer.setData(songType, JSON.stringify(tracks))
  e.dataTransfer.effectAllowed = 'copyMove'
  const ghost = document.createElement('div')
  ghost.className = 'song-drag-ghost'
  ghost.textContent = tracks.length === 1 ? tracks[0].title : `${tracks.length} songs`
  document.body.appendChild(ghost)
  e.dataTransfer.setDragImage(ghost, 14, 14)
  setTimeout(() => ghost.remove(), 0)
}

/** Props for a sidebar playlist that songs can be dropped on: the song is added (copied, if it came from another playlist). */
export function songDropProps(p: Playlist): {
  onDragOver: (e: React.DragEvent) => void; onDragLeave: (e: React.DragEvent) => void; onDrop: (e: React.DragEvent) => void
} {
  const off = (el: Element): void => el.classList.remove('drop-over')
  return {
    onDragOver: (e) => {
      if (p.isAlbum || !e.dataTransfer.types.includes(songType)) return
      e.preventDefault()
      e.stopPropagation()
      e.dataTransfer.dropEffect = 'copy'
      e.currentTarget.classList.add('drop-over')
    },
    onDragLeave: (e) => {
      if (!(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node)) off(e.currentTarget)
    },
    onDrop: (e) => {
      off(e.currentTarget)
      const raw = e.dataTransfer.getData(songType)
      if (p.isAlbum || !raw) return
      e.preventDefault()
      e.stopPropagation()
      let tracks: Track[] = []
      try { tracks = JSON.parse(raw) as Track[] } catch { return }
      const list = libraryStore.get().playlists.find((x) => x.id === p.id)
      if (!list) return
      const existing = new Set(list.tracks.map((t) => t.id))
      const fresh = tracks.filter((t) => !existing.has(t.id))
      if (!fresh.length) return toast(`Already in ${list.name}`)
      void drift.addToPlaylist(list.id, fresh)
      toast(`Added to ${list.name}`)
    }
  }
}

/** Playlists in a folder, or (null) the ones in no folder. */
export function playlistsIn(lib: Library, folder: string | null, list = lib.playlists): Playlist[] {
  const known = new Set((lib.folders ?? []).map((f) => f.id))
  return list.filter((p) => (p.folder && known.has(p.folder) ? p.folder === folder : folder === null))
}

// Which folders are open in the sidebar (remembered on this computer).
const listeners = new Set<() => void>()
let open: string[] = readLocal<string[]>('openFolders', [])

export function openFolder(id: string, on: boolean): void {
  open = on ? [...new Set([...open, id])] : open.filter((x) => x !== id)
  writeLocal('openFolders', open)
  listeners.forEach((f) => f())
}

export function useOpenFolders(): string[] {
  const [, setTick] = useState(0)
  useEffect(() => {
    const f = (): void => setTick((n) => n + 1)
    listeners.add(f)
    return () => {
      listeners.delete(f)
    }
  }, [])
  return open
}
