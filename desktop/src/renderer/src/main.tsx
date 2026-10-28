import { createRoot } from 'react-dom/client'
import './styles.css'
import { App } from './App'
import { loadAll } from './state'
import { restore } from './player'
import { startAutoInstall } from './autoupdate'
import { startActivity } from './activity'

void loadAll().then(() => {
  restore()
  startAutoInstall()
  startActivity()
  createRoot(document.getElementById('root')!).render(<App />)
})
