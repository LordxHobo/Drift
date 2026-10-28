import { createRoot } from 'react-dom/client'
import './styles.css'
import { App } from './App'
import { loadAll } from './state'
import { restore } from './player'
import { startAutoInstall } from './autoupdate'
import { startActivity } from './activity'
import { startVideo } from './video'

void loadAll().then(() => {
  restore()
  startAutoInstall()
  startActivity()
  startVideo()
  createRoot(document.getElementById('root')!).render(<App />)
})
