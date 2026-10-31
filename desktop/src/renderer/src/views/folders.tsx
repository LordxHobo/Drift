// Folders of playlists in Your Library: make, rename and delete them, and move playlists in and out.
import { useEffect, useState } from 'react'
import type { Library, Playlist, PlaylistFolder } from '@shared/types'
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
