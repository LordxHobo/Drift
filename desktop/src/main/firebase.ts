// Drift's Firebase project over plain HTTPS (same calls as the phone's Firebase.swift).
import { app, net, safeStorage } from 'electron'
import { join } from 'node:path'
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs'

// Both values are public by design (every Firebase app ships them); access is controlled by the
// Firestore security rules.
export const projectID = 'drift-ymp'
const apiKey = 'AIzaSyCescn-3XQ1r48CmyUn1E2S2z4YxwVOmP4'
export const documentsPath = `projects/${projectID}/databases/(default)/documents`
const documentsURL = `https://firestore.googleapis.com/v1/${documentsPath}`

export class FirebaseError extends Error {
  constructor(
    public status: number,
    message: string
  ) {
    super(message)
  }
}

async function send(method: string, url: string, opts: { json?: unknown; form?: string; token?: string } = {}): Promise<[number, any]> {
  const headers: Record<string, string> = {}
  if (opts.token) headers.Authorization = `Bearer ${opts.token}`
  let body: string | undefined
  if (opts.json !== undefined) {
    headers['Content-Type'] = 'application/json'
    body = JSON.stringify(opts.json)
  } else if (opts.form !== undefined) {
    headers['Content-Type'] = 'application/x-www-form-urlencoded'
    body = opts.form
  }
  const res = await net.fetch(url, { method, headers, body })
  const text = await res.text()
  let data: any
  try {
    data = text ? JSON.parse(text) : undefined
  } catch {
    data = undefined
  }
  return [res.status, data]
}

const errorMessage = (body: any): string => body?.error?.message ?? ''

export interface Session {
  uid: string
  refreshToken: string
}

/** One sign-in: the phone's account once linked, or a short-lived one used while linking. */
export class Auth {
  private idToken?: string
  private expiry = 0

  constructor(public session?: Session, private onChange?: (s: Session) => void) {}

  get uid(): string | undefined {
    return this.session?.uid
  }

  async token(): Promise<string> {
    if (this.idToken && this.expiry > Date.now() + 60_000) return this.idToken
    if (this.session) await this.refresh(this.session.refreshToken)
    else await this.signUp()
    return this.idToken!
  }

  private async signUp(): Promise<void> {
    const [status, d] = await send('POST', `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${apiKey}`, {
      json: { returnSecureToken: true }
    })
    if (status !== 200 || !d?.idToken) throw new FirebaseError(status, errorMessage(d) || 'Couldn’t reach Drift’s server.')
    this.store(d.localId, d.idToken, d.refreshToken, d.expiresIn)
  }

  private async refresh(rt: string): Promise<void> {
    const [status, d] = await send('POST', `https://securetoken.googleapis.com/v1/token?key=${apiKey}`, {
      form: `grant_type=refresh_token&refresh_token=${encodeURIComponent(rt)}`
    })
    if (status === 400) throw new FirebaseError(400, 'Your sign-in expired. Link your phone again.')
    if (status !== 200 || !d?.id_token) throw new FirebaseError(status, errorMessage(d) || 'Couldn’t reach Drift’s server.')
    this.store(d.user_id, d.id_token, d.refresh_token, d.expires_in)
  }

  private store(uid: string, id: string, refresh: string, expiresIn: unknown): void {
    this.idToken = id
    this.expiry = Date.now() + (Number(expiresIn) || 3600) * 1000
    const changed = this.session?.refreshToken !== refresh || this.session?.uid !== uid
    this.session = { uid, refreshToken: refresh }
    if (changed) this.onChange?.(this.session)
  }

  /** Deletes this (temporary) account from Firebase. */
  async deleteAccount(): Promise<void> {
    const token = await this.token()
    await send('POST', `https://identitytoolkit.googleapis.com/v1/accounts:delete?key=${apiKey}`, { json: { idToken: token } })
  }
}

// MARK: Firestore

export class Firestore {
  constructor(private auth: Auth) {}

  private url(path: string, query: [string, string][] = []): string {
    const u = new URL(`${documentsURL}/${path}`)
    for (const [k, v] of query) u.searchParams.append(k, v)
    return u.toString()
  }

  async get(path: string): Promise<any | undefined> {
    const [status, body] = await send('GET', this.url(path), { token: await this.auth.token() })
    if (status === 404) return undefined
    if (status !== 200) throw new FirebaseError(status, errorMessage(body))
    return body
  }

  /** Create or update. `updateTime`: only if nobody changed it since then (else FirebaseError). Returns the new update time. */
  async patch(path: string, fields: Record<string, unknown>, opts: { mask?: string[]; mustNotExist?: boolean; updateTime?: string } = {}): Promise<string | undefined> {
    const q: [string, string][] = (opts.mask ?? []).map((m) => ['updateMask.fieldPaths', m])
    if (opts.mustNotExist) q.push(['currentDocument.exists', 'false'])
    if (opts.updateTime) q.push(['currentDocument.updateTime', opts.updateTime])
    const [status, body] = await send('PATCH', this.url(path, q), { json: { fields }, token: await this.auth.token() })
    if (status !== 200) throw new FirebaseError(status, errorMessage(body))
    return typeof body?.updateTime === 'string' ? body.updateTime : undefined
  }

  async delete(path: string): Promise<void> {
    const [status, body] = await send('DELETE', this.url(path), { token: await this.auth.token() })
    if (status !== 200 && status !== 404) throw new FirebaseError(status, errorMessage(body))
  }

  /** Runs a query on a collection and returns the matching documents. */
  async query(structured: Record<string, unknown>): Promise<any[]> {
    const [status, body] = await send('POST', `${documentsURL}:runQuery`, { json: { structuredQuery: structured }, token: await this.auth.token() })
    if (status !== 200) throw new FirebaseError(status, errorMessage(body))
    return (Array.isArray(body) ? body : []).map((r: any) => r.document).filter(Boolean)
  }

  /** Several documents at once. */
  async batchGet(paths: string[]): Promise<any[]> {
    if (!paths.length) return []
    const [status, body] = await send('POST', `${documentsURL}:batchGet`, {
      json: { documents: paths.map((p) => `${documentsPath}/${p}`) },
      token: await this.auth.token()
    })
    if (status !== 200) throw new FirebaseError(status, errorMessage(body))
    return (Array.isArray(body) ? body : []).map((r: any) => r.found).filter(Boolean)
  }

  async list(path: string, fields: string[] = []): Promise<any[]> {
    const out: any[] = []
    let pageToken: string | undefined
    do {
      const q: [string, string][] = [['pageSize', '100'], ...fields.map((f): [string, string] => ['mask.fieldPaths', f])]
      if (pageToken) q.push(['pageToken', pageToken])
      const [status, body] = await send('GET', this.url(path, q), { token: await this.auth.token() })
      if (status === 404) return out
      if (status !== 200) throw new FirebaseError(status, errorMessage(body))
      out.push(...(body?.documents ?? []))
      pageToken = body?.nextPageToken
    } while (pageToken)
    return out
  }
}

/** Building and reading Firestore's typed values. */
export const FV = {
  s: (v: string) => ({ stringValue: v }),
  b: (v: boolean) => ({ booleanValue: v }),
  i: (v: number) => ({ integerValue: String(Math.round(v)) }),
  bytes: (base64: string) => ({ bytesValue: base64 }),
  string: (f: any, k: string): string | undefined => f?.[k]?.stringValue,
  bool: (f: any, k: string): boolean | undefined => f?.[k]?.booleanValue,
  int: (f: any, k: string): number | undefined => {
    const v = f?.[k]?.integerValue
    return v === undefined ? undefined : Number(v)
  },
  data: (f: any, k: string): string | undefined => f?.[k]?.bytesValue,
  null: () => ({ nullValue: null }),
  strings: (v: string[]) => ({ arrayValue: { values: v.map((x) => ({ stringValue: x })) } }),
  map: (fields: Record<string, unknown>) => ({ mapValue: { fields } }),
  stringArray: (f: any, k: string): string[] =>
    (f?.[k]?.arrayValue?.values ?? []).map((v: any) => v?.stringValue).filter((v: unknown): v is string => typeof v === 'string'),
  mapFields: (f: any, k: string): any => f?.[k]?.mapValue?.fields
}

export const docName = (doc: any): string => String(doc?.name ?? '').split('/').pop() ?? ''

// MARK: Keeping the sign-in on this computer (encrypted with the system's key store)

const sessionFile = (): string => join(app.getPath('userData'), 'session.bin')

export function loadSession(): Session | undefined {
  try {
    const raw = readFileSync(sessionFile())
    const text = raw.subarray(0, 5).toString() === 'PLAIN' ? raw.subarray(5).toString() : safeStorage.decryptString(raw)
    const s = JSON.parse(text)
    return s?.uid && s?.refreshToken ? s : undefined
  } catch {
    return undefined
  }
}

export function saveSession(s: Session): void {
  const text = JSON.stringify(s)
  const data = safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(text) : Buffer.from('PLAIN' + text)
  writeFileSync(sessionFile(), data, { mode: 0o600 })
}

export function deleteSession(): void {
  if (existsSync(sessionFile())) rmSync(sessionFile())
}
