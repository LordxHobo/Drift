// Edit details: name, cover (automatic, a color or a photo) and whether it shows on your profile.
import { useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import type { CoverStyle, Playlist } from '@shared/types'
import { Icon } from '../icons'
import { drift, libraryStore, Store, toast, useStore } from '../state'
import { PlaylistCover } from '../ui'
import { tiles } from '../util'

export const editPlaylistStore = new Store<string | null>(null)

export function editPlaylist(id: string): void {
  editPlaylistStore.set(id)
}

/** A square crop of the picture, small enough to sync (under about 200 KB, like the phone). */
async function squareJPEG(file: File): Promise<string> {
  const url = URL.createObjectURL(file)
  try {
    const img = new Image()
    img.src = url
    await img.decode()
    const side = Math.min(img.naturalWidth, img.naturalHeight)
    for (const [size, quality] of [[600, 0.82], [500, 0.75], [400, 0.7], [300, 0.65]] as const) {
      const c = document.createElement('canvas')
      c.width = c.height = size
      c.getContext('2d')!.drawImage(img, (img.naturalWidth - side) / 2, (img.naturalHeight - side) / 2, side, side, 0, 0, size, size)
      const data = c.toDataURL('image/jpeg', quality).split(',')[1]
      if (data.length * 0.75 < 195_000) return data
    }
    throw new Error('too big')
  } finally {
    URL.revokeObjectURL(url)
  }
}

export function EditPlaylistDialog(): JSX.Element | null {
  const id = useStore(editPlaylistStore)
  const lib = useStore(libraryStore)
  const p = lib.playlists.find((x) => x.id === id)
  const [name, setName] = useState('')
  const [style, setStyle] = useState<CoverStyle>('auto')
  const [color, setColor] = useState(0)
  const [cover, setCover] = useState<string | null>(null)
  const [isPublic, setPublic] = useState(true)
  const file = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (!p) return
    setName(p.name)
    setStyle(p.coverStyle ?? 'auto')
    setColor(p.colorIndex)
    setCover(p.cover ?? null)
    setPublic(p.isPublic ?? true)
  }, [id])

  if (!id || !p) return null
  const close = (): void => editPlaylistStore.set(null)
  const preview: Playlist = { ...p, coverStyle: style, colorIndex: color, cover }
  const save = (): void => {
    void drift.updatePlaylist(p.id, { name, coverStyle: style === 'photo' && !cover ? 'auto' : style, colorIndex: color, cover, isPublic })
    close()
  }

  return (
    <div className="dialog-layer" onMouseDown={close}>
      <form
        className="dialog edit-playlist"
        onMouseDown={(e) => e.stopPropagation()}
        onSubmit={(e) => {
          e.preventDefault()
          save()
        }}
        onKeyDown={(e) => e.key === 'Escape' && close()}
      >
        <h3>Edit details</h3>
        <div className="edit-body">
          <button type="button" className="edit-cover" onClick={() => file.current?.click()} title="Choose a photo">
            <PlaylistCover p={preview} size={180} radius={6} />
            <span className="edit-cover-hint"><Icon name="edit" size={22} /> Choose photo</span>
          </button>
          <div className="edit-fields">
            <input className="field" value={name} onChange={(e) => setName(e.target.value)} placeholder="Name" autoFocus />
            <div className="seg">
              {(['auto', 'color', 'photo'] as const).map((s) => (
                <button
                  type="button"
                  key={s}
                  className={style === s ? 'on' : ''}
                  onClick={() => (s === 'photo' && !cover ? file.current?.click() : setStyle(s))}
                >
                  {s === 'auto' ? 'Artwork' : s === 'color' ? 'Color' : 'Photo'}
                </button>
              ))}
            </div>
            {style === 'color' && (
              <div className="swatches wrap">
                {tiles.map((c, i) => (
                  <button type="button" key={c} className={`swatch ${color === i ? 'on' : ''}`} style={{ background: c }} aria-label={`Color ${i + 1}`} onClick={() => setColor(i)} />
                ))}
              </div>
            )}
            {style === 'photo' && cover && (
              <button type="button" className="link small-link" onClick={() => (setCover(null), setStyle('auto'))}>Remove photo</button>
            )}
            {!p.isAlbum && (
              <label className="check-row">
                <input type="checkbox" checked={isPublic} onChange={(e) => setPublic(e.target.checked)} />
                Show on my profile
              </label>
            )}
          </div>
        </div>
        <input
          ref={file}
          type="file"
          accept="image/*"
          hidden
          onChange={(e) => {
            const f = e.target.files?.[0]
            e.target.value = ''
            if (!f) return
            squareJPEG(f)
              .then((data) => {
                setCover(data)
                setStyle('photo')
              })
              .catch(() => toast('That picture couldn’t be used. Try another one.'))
          }}
        />
        <div className="dialog-buttons">
          <button type="button" className="btn ghost" onClick={close}>Cancel</button>
          <button type="submit" className="btn primary">Save</button>
        </div>
      </form>
    </div>
  )
}
