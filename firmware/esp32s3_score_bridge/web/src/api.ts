export type Scenario = 'ready' | 'sending' | 'success' | 'busy' | 'timeout' | 'offline' | 'unknown';
export type Segment = { id: number; duration: string; durationMs: number; events: number; bpm: number; data: ArrayBuffer; storageTitle: string; review?: string };
export type Song = { id: string; title: string; detail: string; bpm: number; total: number; segments: Segment[] };
export type Slot = { number: number; state: 'valid' | 'empty' | 'damaged'; title?: string; segment?: number; total?: number; bpm?: number; events?: number };
export type Device = { target: string; psram_total: number; pending_verified: boolean; selected_slot: number; fpga_ack_seen: boolean };
export type Network = { ap_ssid: string; ap_ip: string; ssid: string; station_ip: string; configured: boolean; connected: boolean; connecting: boolean };
export type Active = { confirmed: boolean; source: 'wifi_ram' | 'rom' | 'unknown'; title?: string; part?: number; total?: number; events?: number; bpm?: number; result?: number; token?: number };

export class ApiError extends Error {
  constructor(public status: number, message: string, public reason: 'network' | 'timeout' | 'response' = 'response') { super(message); }
}

// The S3 HTTP service has four client sockets and a single upload mutex.
// Serialize this tab's requests, including queries after mutations.
let tail: Promise<unknown> = Promise.resolve();
function request(path: string, method = 'GET', body?: BodyInit, type?: string): Promise<Response> {
  const run = tail.catch(() => {}).then(async () => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), 30000);
    try {
      const response = await fetch(path, { method, body, headers: type ? { 'Content-Type': type } : undefined, signal: controller.signal, cache: 'no-store' });
      // Consume inside the queue: a Response alone is not a finished transfer.
      const text = await response.text();
      if (!response.ok) throw new ApiError(response.status, text || `请求未完成 (${response.status})`);
      return new Response(text, { status: response.status, headers: response.headers });
    } catch (error) {
      if (error instanceof ApiError) throw error;
      const timeout = error instanceof Error && error.name === 'AbortError';
      throw new ApiError(0, timeout ? '等待超时，结果未确认；请查询琴端，不要自动重传。' : '无法连接 S3，请检查 Wi-Fi 和网页地址。', timeout ? 'timeout' : 'network');
    } finally { window.clearTimeout(timer); }
  });
  tail = run.then(() => {}, () => {});
  return run;
}
async function json(path: string) { return (await request(path)).json(); }
const post = async (path: string, body?: BodyInit, type?: string) => (await request(path, 'POST', body, type)).text();
export const api = {
  network: async (): Promise<Network> => {
    const value = await json('/network');
    if (typeof value.ap_ip !== 'string' || typeof value.connected !== 'boolean') throw new ApiError(0, '网络接口返回格式不匹配。');
    return value;
  },
  status: async (): Promise<Device> => {
    const value = await json('/status');
    if (typeof value.target !== 'string' || typeof value.pending_verified !== 'boolean') throw new ApiError(0, '设备状态接口返回格式不匹配。');
    return value;
  },
  active: async (): Promise<Active> => {
    const value = await json('/fpga');
    if (typeof value.confirmed !== 'boolean' || !['wifi_ram', 'rom', 'unknown'].includes(value.source)) throw new ApiError(0, '琴端读回格式不匹配。');
    return value;
  },
  slots: async (): Promise<Slot[]> => {
    const value = await json('/library');
    if (!Array.isArray(value.slots)) throw new ApiError(0, '槽位接口返回格式不匹配。');
    const result: Slot[] = Array.from({ length: 4 }, (_, i) => ({ number: i + 1, state: 'damaged' }));
    // Accept the old eight-slot device response during migration, but expose
    // and write only the four resident slots. Existing slots5..8 stay untouched.
    if (value.slots.length !== 4 && value.slots.length !== 8) throw new ApiError(0, '槽位快照不完整，请重新读取。');
    const seen = new Set<number>();
    for (const s of value.slots) {
      if (!Number.isInteger(s.slot) || s.slot < 0 || s.slot > 7 || seen.has(s.slot)) throw new ApiError(0, '槽位编号无效或重复。');
      seen.add(s.slot);
      if (s.slot >= 4) continue;
      const match = typeof s.title === 'string' ? s.title.match(/^(.*)·(\d{1,3})\/(\d{1,3})$/u) : null;
      result[s.slot] = { number: s.slot + 1, state: s.valid ? 'valid' : s.empty ? 'empty' : 'damaged', title: match ? match[1] : s.title, segment: match ? Number(match[2]) : 1, total: match ? Number(match[3]) : 1, bpm: s.bpm, events: s.events };
    }
    if (![0, 1, 2, 3].every(i => seen.has(i))) throw new ApiError(0, '四个常驻槽位快照不完整，请重新读取。');
    return result;
  },
  catalog: async (): Promise<Song[]> => {
    const c = await json('/catalog.json');
    if (c.version !== 1 || !Array.isArray(c.songs) || !Array.isArray(c.blobs)) throw new ApiError(0, '曲库格式不匹配。');
    return c.songs.map((s: { id: string | number; title: string; parts_total: number; parts: { number: number; duration_ms: number; events: number; bpm: number; blob: number; storage_title: string }[]; mixed_voice?: boolean; has_voice_gaps?: boolean }) => ({
      id: String(s.id), title: s.title, total: s.parts_total, bpm: s.parts[0]?.bpm ?? 0,
      detail: `${s.mixed_voice ? '混合声部分离候选' : '单旋律候选'} · ${s.parts.length}/${s.parts_total} 段可用 · 待听审${s.has_voice_gaps ? ' · 可能有主奏交接空缺' : ''}`,
      segments: s.parts.map(p => {
        if (typeof c.blobs[p.blob] !== 'string') throw new ApiError(0, '曲库片段数据缺失。');
        const raw = atob(c.blobs[p.blob]); const data = Uint8Array.from(raw, x => x.charCodeAt(0)).buffer;
        const parsed = parseScore(data);
        if (parsed.events !== p.events || parsed.bpm !== p.bpm) throw new ApiError(0, '曲库片段摘要与文件不一致。');
        return { id: p.number, duration: duration(p.duration_ms), durationMs: p.duration_ms, events: p.events, bpm: p.bpm, data, storageTitle: p.storage_title, review: s.mixed_voice || s.has_voice_gaps ? '主旋律提取候选，待听审确认' : undefined };
      }),
    }));
  },
  send: (song: Song, part: Segment) => post('/score?' + new URLSearchParams({ title: utf8Limit(song.title, 48), part: String(part.id), total: String(song.total) }), part.data, 'application/octet-stream'),
  save: (number: number, part: Segment) => post('/library?' + new URLSearchParams({ slot: String(slotIndex(number)), title: part.storageTitle }), part.data, 'application/octet-stream'),
  sendSlot: (number: number) => post('/select?slot=' + slotIndex(number)),
  deleteSlot: (number: number) => post('/delete?slot=' + slotIndex(number)),
  retry: () => post('/commit'),
  probe: () => post('/probe'),
  configure: (ssid: string, password: string) => post('/network', JSON.stringify({ ssid, password }), 'application/json'),
  forget: () => post('/network/forget'),
};
export function slotIndex(number: number) { if (!Number.isInteger(number) || number < 1 || number > 4) throw new Error('请选择槽位1–4。'); return number - 1; }
export function utf8Limit(text: string, max: number) { let out = ''; for (const c of text) { if (new TextEncoder().encode(out + c).length > max) break; out += c; } return out; }
export function duration(ms: number) { const sec = Math.round(ms / 1000); return `${String(Math.floor(sec / 60)).padStart(2, '0')}:${String(sec % 60).padStart(2, '0')}`; }
export function parseScore(data: ArrayBuffer) {
  if (data.byteLength < 24 || data.byteLength > 2056) throw new Error('XS01文件需要24–2056字节。');
  const v = new DataView(data); const sig = new TextDecoder().decode(data.slice(0, 4)); const count = v.getUint16(4, true); const bpm = v.getUint8(6);
  if (sig !== 'XS01' || count < 2 || count > 256 || data.byteLength !== 8 + count * 8 || bpm < 30 || bpm > 240 || v.getUint8(7) > 103) throw new Error('XS01文件头或长度无效。');
  let prev = -1, word = 0n;
  for (let i = 0; i < count; i++) {
    word = v.getBigUint64(8 + i * 8, true); const tick = Number(word & 0xffffffffn);
    if ((word >> 57n) !== 0n || (i === 0 && tick !== 0) || tick <= prev) throw new Error('曲谱事件顺序或保留位无效。');
    prev = tick;
  }
  if ((word >> 32n) !== 0n) throw new Error('最后事件必须松开全部键。');
  return { events: count, bpm, durationMs: prev * 60000 / (96 * bpm) };
}
