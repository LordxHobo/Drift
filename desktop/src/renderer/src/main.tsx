import { createRoot } from 'react-dom/client'
import './styles.css'
import { App } from './App'
import { loadAll } from './state'
import { restore } from './player'

void loadAll().then(() => {
  restore()
  createRoot(document.getElementById('root')!).render(<App />)
})
