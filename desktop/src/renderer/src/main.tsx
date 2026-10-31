import { createRoot } from 'react-dom/client'
import './styles.css'
import { App } from './App'
import { loadAll } from './state'
import { restore } from './player'
import { startAutoInstall } from './autoupdate'
import { startActivity } from './activity'
import { startJam } from './jam'
import { startInvites } from './views/invite'
import { startRemote } from './remote'
import { startVideo } from './video'

void loadAll().then(() => {
  restore()
  startAutoInstall()
  startActivity()
  startVideo()
  startJam()
  startInvites()
  startRemote()
  createRoot(document.getElementById('root')!).render(<App />)
})
