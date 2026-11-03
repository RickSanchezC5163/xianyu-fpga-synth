import { useEffect, useRef, useState } from 'react';
import { api, ApiError, duration, parseScore, utf8Limit, type Active, type Device, type Network, type Scenario, type Segment, type Slot, type Song } from './api';

type Selection = { song: Song; part: Segment };
type Confirmation = { kind: 'save' | 'delete'; slot: number; selection?: Selection };
export function useInstrument() {
  const [songs, setSongs] = useState<Song[]>([]), [slots, setSlots] = useState<Slot[]>([]);
  const [query, setQuery] = useState(''), [songId, setSongId] = useState(''), [segmentId, setSegmentId] = useState(1), [targetSlot, setTargetSlot] = useState(1);
  const [scenario, setScenario] = useState<Scenario>('ready'), [message, setMessage] = useState('正在读取S3，尚未查询琴端。');
  const [connected, setConnected] = useState<boolean | null>(null), [working, setWorking] = useState(false), [loaded, setLoaded] = useState(false);
  const [active, setActive] = useState<Active | null>(null), [activeFresh, setActiveFresh] = useState(false), [checkedAt, setCheckedAt] = useState('—');
  const [device, setDevice] = useState<Device | null>(null), [network, setNetwork] = useState<Network | null>(null);
  const [notice, setNotice] = useState<string | null>(null), [confirm, setConfirm] = useState<Confirmation | null>(null);
  const [networkOpen, setNetworkOpen] = useState(false), [ssid, setSsid] = useState(''), [password, setPassword] = useState('');
  const [fileError, setFileError] = useState<string | null>(null);
  const lock = useRef(false), seededNetwork = useRef(false);
  const selectedSong = songs.find(s => s.id === songId);
  const selectedSegment = selectedSong?.segments.find(p => p.id === segmentId) ?? selectedSong?.segments[0];
  const selection = selectedSong && selectedSegment ? { song: selectedSong, part: selectedSegment } : null;
  const offline = connected !== true, busy = working;
  const filteredSongs = songs.filter(s => s.title.toLowerCase().includes(query.toLowerCase()));

  function fail(error: unknown) {
    const text = error instanceof Error ? error.message : '操作未完成。';
    setMessage(text); setNotice(text);
    if (error instanceof ApiError && error.reason === 'network') { setConnected(false); setActiveFresh(false); setScenario('offline'); }
    else if (error instanceof ApiError && error.reason === 'timeout') { setActiveFresh(false); setScenario('timeout'); }
    else if (error instanceof ApiError && error.status === 409) setScenario('busy');
    else setScenario('timeout');
  }
  async function state() {
    const n = await api.network(), d = await api.status(), list = await api.slots();
    setNetwork(n); setDevice(d); setSlots(list); setLoaded(true); setConnected(true);
    if (!seededNetwork.current) { setSsid(n.ssid || ''); seededNetwork.current = true; }
  }
  async function readActive() {
    setActiveFresh(false);
    const value = await api.active();
    if (!value.confirmed) { setScenario('unknown'); setMessage(`尚未获得有效琴端读回，代码${value.result ?? '未知'}。`); return; }
    setActive(value); setActiveFresh(true); setCheckedAt(new Date().toLocaleTimeString('zh-CN', { hour12: false }));
  }
  async function perform(action: () => Promise<string>, read = false) {
    if (lock.current) return;
    lock.current = true; setWorking(true); setScenario('sending'); setMessage('请求已发送，正在等待设备返回。');
    if (read) setActiveFresh(false);
    try {
      const text = await action(); setMessage(text); setNotice(text); setScenario('success');
      await state();
      if (read) await readActive();
    } catch (error) {
      fail(error);
      if (error instanceof ApiError && error.status === 409) {
        try { setDevice(await api.status()); } catch { /* Keep the original operation failure visible. */ }
      }
    }
    finally { lock.current = false; setWorking(false); }
  }
  async function refresh(initial = false) {
    if (lock.current) return;
    lock.current = true; setWorking(true);
    try {
      await state();
      const list = await api.catalog();
      setSongs(old => [...list, ...old.filter(s => s.id === 'imported')]);
      setSongId(id => list.some(s => s.id === id) || id === 'imported' ? id : (list.find(s => s.title.includes('送别'))?.id ?? list[0]?.id ?? ''));
      setScenario('ready'); setMessage(initial ? '曲库已读取。选择、保存和发送分别进行；尚未查询琴端。' : '曲库已刷新；琴端当前曲谱请单独查询。');
    } catch (error) { fail(error); }
    finally { lock.current = false; setWorking(false); }
  }
  useEffect(() => { void refresh(true); }, []);
  function chooseSong(id: string) {
    setSongId(id); setSegmentId(songs.find(s => s.id === id)?.segments[0]?.id ?? 1); setNotice(null);
  }
  function handleSend() { if (selection) { const target = selection; void perform(() => api.send(target.song, target.part), true); } }
  function requestSave(number = targetSlot) {
    if (!selection || !loaded || lock.current) return;
    const slot = slots.find(s => s.number === number); if (!slot) return;
    const target = { ...selection };
    if (slot.state === 'empty') void commitSave(number, target);
    else setConfirm({ kind: 'save', slot: number, selection: target });
  }
  async function commitSave(number: number, saved = confirm?.selection ?? selection) {
    if (!saved) return;
    setConfirm(null); await perform(() => api.save(number, saved.part));
  }
  function deleteSlot(number: number) { setConfirm(null); void perform(() => api.deleteSlot(number)); }
  function sendSlot(number: number) { void perform(() => api.sendSlot(number), true); }
  function retryCommit() { if (device?.pending_verified) void perform(() => api.retry(), true); }
  function queryActive() { void perform(async () => '查询已完成；信息以琴端读回为准。', true); }
  function requestDelete(number: number) { if (!lock.current) setConfirm({ kind: 'delete', slot: number }); }
  async function validateFile(file?: File) {
    if (!file) return;
    setFileError(null);
    try {
      if (!file.name.toLowerCase().endsWith('.xys')) throw new Error('仅支持XS01 .xys；MIDI/MP3/WAV需要先转换。');
      const data = await file.arrayBuffer(), parsed = parseScore(data);
      const title = file.name.replace(/\.xys$/iu, '') || '导入曲谱', suffix = '·01/01';
      const song: Song = { id: 'imported', title, detail: '本地导入 · 尚未保存或发送', bpm: parsed.bpm, total: 1,
        segments: [{ id: 1, duration: duration(parsed.durationMs), durationMs: parsed.durationMs, events: parsed.events, bpm: parsed.bpm, data, storageTitle: utf8Limit(title, 48 - new TextEncoder().encode(suffix).length) + suffix }] };
      setSongs(old => [...old.filter(s => s.id !== 'imported'), song]); setSongId(song.id); setSegmentId(1);
      setNotice(`已检查并选中 ${file.name}，尚未保存或发送。`);
    } catch (error) { setFileError(error instanceof Error ? error.message : '文件无效。'); }
  }
  function configure() {
    const count = new TextEncoder().encode(ssid).length, pass = new TextEncoder().encode(password).length;
    if (!count || count > 32 || (pass !== 0 && (pass < 8 || pass > 63))) { setNotice('Wi-Fi名称需1–32字节，密码为空或8–63字节。'); return; }
    void perform(async () => { const result = await api.configure(ssid, password); setPassword(''); return result; });
  }
  function forget() { if (window.confirm('忘记路由器设置？设备设置热点和曲库会保留。')) void perform(async () => { const result = await api.forget(); setSsid(''); setPassword(''); return result; }); }
  async function copy(text: string) {
    try { if (!navigator.clipboard) throw new Error(); await navigator.clipboard.writeText(text); setNotice('已复制。'); }
    catch { setNotice('浏览器不支持自动复制，请长按或手动选择消息文字。'); }
  }
  return { songs, slots, query, setQuery, songId, segmentId, setSegmentId, targetSlot, setTargetSlot, scenario, message, connected,
    working, loaded, active, activeFresh, checkedAt, device, network, notice, setNotice, confirm, setConfirm,
    networkOpen, setNetworkOpen, ssid, setSsid, password, setPassword, fileError, selectedSong, selectedSegment, filteredSongs,
    offline, busy, chooseSong, handleSend, requestSave, commitSave, deleteSlot, sendSlot, retryCommit, queryActive, requestDelete,
    validateFile, refresh, configure, forget, copy };
}
