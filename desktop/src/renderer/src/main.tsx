import { createRoot } from 'react-dom/client'
import './styles.css'
import { App } from './App'
import { loadAll } from './state'
import { restore } from './player'
import { startAutoInstall } from './autoupdate'

void loadAll().then(() => {
  restore()
  startAutoInstall()
  createRoot(document.getElementById('root')!).render(<App />)
})
