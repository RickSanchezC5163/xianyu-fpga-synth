import { useEffect, useRef, type ReactNode, type ButtonHTMLAttributes } from 'react';
import { useInstrument } from './useInstrument';

function Icon({ name, size = 18 }: { name: 'string' | 'refresh' | 'search' | 'chevron' | 'upload' | 'wifi' | 'copy' | 'close' | 'more'; size?: number }) {
  const paths: Record<string, ReactNode> = {
    string: <><path d="M5 4v16M10 7v10M15 3v18M20 8v8" /><path d="M3 8c5-4 13 12 18 6" /></>,
    refresh: <><path d="M20 7v5h-5" /><path d="M19 12a7.5 7.5 0 1 0-1.8 6" /></>,
    search: <><circle cx="11" cy="11" r="6.5" /><path d="m16 16 4 4" /></>,
    chevron: <path d="m8 10 4 4 4-4" />,
    upload: <><path d="M12 16V4m-4 4 4-4 4 4" /><path d="M5 14v5h14v-5" /></>,
    wifi: <><path d="M4 9a12 12 0 0 1 16 0M7 13a7.5 7.5 0 0 1 10 0M10 17a3 3 0 0 1 4 0" /><circle cx="12" cy="20" r=".7" fill="currentColor" /></>,
    copy: <><rect x="8" y="8" width="10" height="11" rx="2" /><path d="M15 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h2" /></>,
    close: <path d="m6 6 12 12M18 6 6 18" />,
    more: <><circle cx="5" cy="12" r="1" fill="currentColor" /><circle cx="12" cy="12" r="1" fill="currentColor" /><circle cx="19" cy="12" r="1" fill="currentColor" /></>,
  };
  return <svg aria-hidden="true" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">{paths[name]}</svg>;
}

function Button({ children, variant = 'secondary', className = '', ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'primary' | 'secondary' | 'ghost' | 'danger' }) {
  return <button className={`button button--${variant} ${className}`} {...props}>{children}</button>;
}

function Badge({ children, tone = 'neutral' }: { children: ReactNode; tone?: 'success' | 'warning' | 'danger' | 'neutral' | 'info' }) {
  return <span className={`badge badge--${tone}`}><span className="badge__dot" />{children}</span>;
}

function SectionTitle({ eyebrow, title, action }: { eyebrow: string; title: string; action?: ReactNode }) {
  return <div className="section-title"><div><div className="eyebrow">{eyebrow}</div><h2>{title}</h2></div>{action}</div>;
}

function App() {
  const {
    songs, slots, query, setQuery, songId, setSegmentId, targetSlot, setTargetSlot, scenario, message, connected,
    loaded, active, activeFresh, checkedAt, device, network, notice, setNotice, confirm, setConfirm,
    networkOpen, setNetworkOpen, ssid, setSsid, password, setPassword, fileError, selectedSong, selectedSegment, filteredSongs,
    offline, busy, chooseSong, handleSend, requestSave, commitSave, deleteSlot, sendSlot, retryCommit, queryActive, requestDelete,
    validateFile, refresh, configure, forget, copy,
  } = useInstrument();
  const fileRef = useRef<HTMLInputElement>(null);
  const modalRef = useRef<HTMLDivElement>(null);
  const preview = device?.target === 'local-preview';
  useEffect(() => {
    if (!confirm) return;
    const previous = document.activeElement as HTMLElement | null;
    const modal = modalRef.current;
    const controls = () => [...(modal?.querySelectorAll<HTMLElement>('button:not(:disabled)') ?? [])];
    controls()[0]?.focus();
    const key = (event: KeyboardEvent) => {
      if (event.key === 'Escape') { setConfirm(null); return; }
      if (event.key !== 'Tab') return;
      const list = controls(), first = list[0], last = list[list.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    };
    document.addEventListener('keydown', key);
    return () => { document.removeEventListener('keydown', key); previous?.focus(); };
  }, [confirm]);
  const titles = { ready: '等待操作', sending: '正在处理请求', success: '操作已完成', busy: '设备忙，等待处理', timeout: '操作未获确认', offline: 'S3连接待恢复', unknown: '琴端状态未知' };
  const tone = scenario === 'success' ? 'success' : scenario === 'busy' || scenario === 'unknown' ? 'warning' : scenario === 'offline' || scenario === 'timeout' ? 'danger' : 'info';
  const scenarioMessage = { title: titles[scenario], tone, body: message };

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand">
          <span className="brand__mark"><Icon name="string" size={24} /></span>
          <span><strong>弦域</strong><small>S3 乐谱库</small></span>
        </div>
        <div className="topbar__tools">
          <div className="prototype-label">{preview ? '离线界面预览' : '设备接口版'}</div>
        </div>
      </header>
      {preview && <div className="preview-banner">离线预览：槽位、操作与琴端读回均为本地模拟，未连接或修改硬件。</div>}

      <main>
        <section className="device-bar">
          <div className="device-bar__item">
            <Badge tone={offline ? 'danger' : 'success'}>{connected === null ? '连接中' : offline ? 'S3 离线' : 'S3 在线'}</Badge>
            <div><strong>{offline ? '连接尚未确认' : network?.connected ? '已接入局域网' : '设备热点可访问'}</strong><small>{network ? (network.connected ? network.station_ip : network.ap_ip) : '读取设备信息后显示地址'}</small></div>
          </div>
          <div className="device-bar__divider" />
          <div className="device-bar__item">
            <Badge tone={activeFresh ? 'success' : 'warning'}>{activeFresh ? 'FPGA 已确认' : active ? '旧记录' : '未查询'}</Badge>
            <div><strong>{activeFresh ? '实际曲谱已回读' : '琴端状态待确认'}</strong><small>上次有效查询 {checkedAt}</small></div>
          </div>
          <div className="device-bar__actions">
            <Button variant="ghost" disabled={busy} onClick={() => void refresh()}><Icon name="refresh" />刷新</Button>
            <Button variant="secondary" disabled={offline || busy} onClick={queryActive}>查询琴端曲谱</Button>
          </div>
        </section>

        <section className={`system-message system-message--${scenarioMessage.tone}`} aria-live="polite">
          <div className="system-message__pulse" />
          <div><strong>{scenarioMessage.title}</strong><p>{scenarioMessage.body}</p></div>
          {device?.pending_verified && <Button variant="secondary" disabled={offline || busy} onClick={retryCommit}>重试待提交曲谱</Button>}
          <Button variant="ghost" className="copy-button" title="复制完整消息" onClick={() => void copy(`${scenarioMessage.title}\n${scenarioMessage.body}`)}><Icon name="copy" /></Button>
        </section>

        {notice && <div className="toast" role="status"><span>{notice}</span><Button variant="ghost" onClick={() => setNotice(null)} aria-label="关闭"><Icon name="close" /></Button></div>}

        <div className="workspace-grid">
          <section className="panel library-panel">
            <SectionTitle eyebrow="浏览器当前选择" title="乐谱库" action={<span className="count">{songs.length} 首曲目</span>} />
            <div className="search-box"><Icon name="search" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="按完整曲名搜索" /></div>
            <div className="song-list">
              {filteredSongs.length ? filteredSongs.map((song) => (
                <button key={song.id} className={`song-row ${song.id === songId ? 'is-selected' : ''}`} disabled={busy} onClick={() => chooseSong(song.id)}>
                  <span className="song-row__cover"><Icon name="string" /></span>
                  <span className="song-row__text"><strong>{song.title}</strong><small>{song.detail}</small></span>
                  <span className="song-row__meta">{song.segments.length} 段<Icon name="chevron" /></span>
                </button>
              )) : <div className="empty-state"><strong>未找到相关曲目</strong><span>尝试输入完整曲名或清除搜索条件。</span><Button variant="secondary" onClick={() => setQuery('')}>清除搜索</Button></div>}
            </div>
            <button className="import-row" disabled={busy} onClick={() => fileRef.current?.click()}>
              <span className="import-row__icon"><Icon name="upload" /></span>
              <span><strong>导入 XS01 乐谱</strong><small>仅 .xys · 24–2056 字节 · 2–256 个事件</small></span>
              <span className="import-row__action">选择文件</span>
            </button>
            <input ref={fileRef} className="visually-hidden" type="file" accept=".xys" disabled={busy} onChange={(event) => validateFile(event.target.files?.[0])} />
            {fileError && <div className="inline-error"><strong>文件未导入</strong><span>{fileError}</span><Button variant="ghost" onClick={() => void copy(fileError)}>复制错误详情</Button></div>}
          </section>

          {selectedSong && selectedSegment ? <section className="panel selection-panel">
            <SectionTitle eyebrow="待处理乐谱" title={selectedSong.title} action={<Badge tone="info">浏览选择</Badge>} />
            <p className="selection-panel__detail">{selectedSong.detail}</p>
            <div className="segment-label"><strong>选择段落</strong><span>共 {selectedSong.total} 段</span></div>
            <div className="segment-tabs">
              {selectedSong.segments.map((segment) => <button key={segment.id} disabled={busy} aria-label={`选择第${segment.id}段`} onClick={() => setSegmentId(segment.id)} className={segment.id === selectedSegment.id ? 'is-selected' : ''}><strong>{String(segment.id).padStart(2, '0')}</strong><small>{segment.duration}</small></button>)}
            </div>
            <div className="segment-summary">
              <div><small>当前段落</small><strong>段落 {String(selectedSegment.id).padStart(2, '0')} / 共 {selectedSong.total} 段</strong></div>
              <div><small>时长</small><strong>{selectedSegment.duration}</strong></div>
              <div><small>BPM</small><strong>{selectedSegment.bpm}</strong></div>
              <div><small>事件数</small><strong>{selectedSegment.events}</strong></div>
            </div>
            {selectedSegment.review && <div className="review-note"><Badge tone="warning">待复核</Badge><span>{selectedSegment.review}</span></div>}
            <div className="action-zone">
              <div className="send-target"><small>将发送</small><strong>{selectedSong.title}</strong><span>段落 {String(selectedSegment.id).padStart(2, '0')} / 共 {selectedSong.total} 段</span></div>
              <Button variant="primary" disabled={offline || busy} onClick={handleSend}>{scenario === 'sending' ? <><span className="spinner" />等待 FPGA 确认</> : '发送到乐器'}</Button>
            </div>
            <div className="save-zone">
              <label><span>保存目标槽位</span><select disabled={busy || !loaded} value={targetSlot} onChange={(event) => setTargetSlot(Number(event.target.value))}>{slots.map((slot) => <option key={slot.number} value={slot.number}>槽位 {slot.number} · {slot.state === 'empty' ? '空' : slot.state === 'damaged' ? '数据损坏' : slot.title}</option>)}</select></label>
              <Button variant="secondary" disabled={offline || busy || !loaded} onClick={() => requestSave()}>保存到槽位 {targetSlot}</Button>
              <p>保存到 S3 不会切换琴当前乐谱。</p>
            </div>
          </section> : <section className="panel selection-panel"><SectionTitle eyebrow="待处理曲谱" title="请选择一个片段" /><p className="section-intro">{offline ? '连接S3后读取曲库，也可以先检查本地XS01文件。' : '正在读取曲库，或导入本地XS01文件。'}</p></section>}
        </div>

        <section className="panel active-score">
          <SectionTitle eyebrow="FPGA 单一活动乐谱" title="乐器当前乐谱" action={<Badge tone={activeFresh ? 'success' : 'warning'}>{activeFresh ? '已回读确认' : '未知 / 旧记录'}</Badge>} />
          <div className="active-score__body">
            <div className="active-score__title">
              <span className="source-chip">{active?.source === 'wifi_ram' ? 'Wi-Fi RAM' : active?.source === 'rom' ? '内置 ROM' : '来源未知'}</span>
              <h3>{!activeFresh && active ? '上次记录：' : ''}{active?.title ?? '尚未获得有效琴端读回'}</h3>
              <p>{activeFresh ? '来自FPGA实际读回，不随上方浏览选择变化。' : '旧记录不能证明琴端当前状态，请重新查询。'}</p>
            </div>
            <div className="active-score__stats">
              <div><small>段落</small><strong>{active?.part ? `${active.part} / ${active.total}` : '—'}</strong></div><div><small>事件数</small><strong>{active?.events || '—'}</strong></div><div><small>BPM</small><strong>{active?.bpm || '—'}</strong></div><div><small>查询时间</small><strong>{checkedAt}</strong></div>
            </div>
          </div>
        </section>

        <section className="slots-section">
          <SectionTitle eyebrow="S3 断电保存区" title="我的 4 个常驻槽位" action={<span className="slots-legend"><i className="valid" />有效 {slots.filter((s) => s.state === 'valid').length}<i />空 {slots.filter((s) => s.state === 'empty').length}<i className="damaged" />损坏 {slots.filter((s) => s.state === 'damaged').length}</span>} />
          <p className="section-intro">固定使用槽位1–4，每槽保存一个片段。保存到S3与加载为琴端当前曲谱分别确认。{!loaded && '槽位尚未读取，不显示虚构内容。'}</p>
          <div className="slots-grid">
            {slots.map((slot) => (
              <article key={slot.number} className={`slot-card slot-card--${slot.state}`}>
                <div className="slot-card__top"><span className="slot-number">{slot.number}</span><Badge tone={slot.state === 'valid' ? 'success' : slot.state === 'damaged' ? 'danger' : 'neutral'}>{slot.state === 'valid' ? '有效' : slot.state === 'damaged' ? '损坏' : '空槽位'}</Badge></div>
                {slot.state === 'valid' ? <>
                  <div className="slot-card__content"><h3>{slot.title}</h3><p>段落 {String(slot.segment).padStart(2, '0')} / 共 {slot.total} 段</p><div><span>{slot.events} 事件</span><span>{slot.bpm} BPM</span></div></div>
                  <div className="slot-card__actions"><Button variant="primary" disabled={offline || busy} onClick={() => sendSlot(slot.number)}>发送槽位 {slot.number} 到琴</Button><Button variant="ghost" disabled={offline || busy || !selectedSegment} onClick={() => { setTargetSlot(slot.number); requestSave(slot.number); }}>覆盖保存</Button><Button variant="ghost" className="danger-text" disabled={offline || busy} onClick={() => requestDelete(slot.number)}>删除</Button></div>
                </> : slot.state === 'damaged' ? <>
                  <div className="slot-card__content"><h3>槽位数据损坏</h3><p>无法读取曲名与段落信息</p><div><span>建议删除后重新保存</span></div></div>
                  <div className="slot-card__actions"><Button variant="secondary" disabled={offline || busy || !selectedSegment} onClick={() => { setTargetSlot(slot.number); requestSave(slot.number); }}>覆盖保存到槽位 {slot.number}</Button><Button variant="ghost" className="danger-text" disabled={offline || busy} onClick={() => requestDelete(slot.number)}>删除</Button></div>
                </> : <>
                  <div className="slot-card__empty"><span><Icon name="string" /></span><strong>等待保存乐谱段落</strong><p>可在上方选择此槽位作为保存目标</p></div>
                  <Button variant="ghost" onClick={() => { setTargetSlot(slot.number); document.querySelector('.selection-panel')?.scrollIntoView({ behavior: 'smooth' }); }}>选择槽位 {slot.number}</Button>
                </>}
              </article>
            ))}
          </div>
        </section>

        <section className={`panel network-panel ${networkOpen ? 'is-open' : ''}`}>
          <button className="network-panel__toggle" onClick={() => setNetworkOpen(!networkOpen)} aria-expanded={networkOpen}>
            <span className="network-panel__icon"><Icon name="wifi" /></span>
            <span><strong>网络设置</strong><small>{network?.connected ? `已连接 ${network.ssid} · ${network.station_ip}` : network?.connecting ? '正在连接路由器' : '通过设备热点访问，可设置2.4GHz网络'}</small></span>
            <Icon name="chevron" />
          </button>
          {networkOpen && <div className="network-panel__body">
            <div className="network-form">
              <label><span>2.4 GHz Wi-Fi 名称</span><input value={ssid} onChange={(event) => setSsid(event.target.value)} /></label>
              <label><span>密码</span><input type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="输入后不会回显" /></label>
              <Button variant="primary" disabled={offline || busy} onClick={configure}>连接网络</Button>
              <Button variant="ghost" className="danger-text" disabled={offline || busy} onClick={forget}>忘记此网络</Button>
            </div>
            <div className="network-address"><small>已获得局域网地址</small><strong>{network?.station_ip ? `http://${network.station_ip}/` : '尚未取得局域网地址'}</strong><span>热点恢复入口始终可通过 192.168.4.1 访问</span></div>
          </div>}
        </section>
      </main>

      <footer><span>弦域 S3 · 曲谱管理</span><span>槽位 1–8 · XS01</span></footer>

      {confirm && <div className="modal-backdrop" role="presentation" onMouseDown={() => setConfirm(null)}>
        <div ref={modalRef} className="modal" role="dialog" aria-modal="true" aria-labelledby="confirm-title" onMouseDown={(event) => event.stopPropagation()}>
          <div className="modal__icon"><Icon name={confirm.kind === 'delete' ? 'close' : 'refresh'} size={22} /></div>
          <h2 id="confirm-title">{confirm.kind === 'delete' ? `删除槽位 ${confirm.slot}？` : `覆盖槽位 ${confirm.slot}？`}</h2>
          <p>{confirm.kind === 'delete' ? '该槽位中的 XS01 段落将被永久删除。此操作不会改变琴当前乐谱。' : `原有内容将被“${confirm.selection?.song.title ?? '当前片段'} · 段落 ${String(confirm.selection?.part.id ?? 1).padStart(2, '0')}”替换。`}</p>
          <div className="modal__summary"><span>目标</span><strong>S3 槽位 {confirm.slot}</strong></div>
          <div className="modal__actions"><Button variant="ghost" onClick={() => setConfirm(null)}>取消</Button><Button variant={confirm.kind === 'delete' ? 'danger' : 'primary'} disabled={busy} onClick={() => confirm.kind === 'delete' ? deleteSlot(confirm.slot) : void commitSave(confirm.slot, confirm.selection)}>{confirm.kind === 'delete' ? '确认删除' : '确认覆盖保存'}</Button></div>
        </div>
      </div>}
    </div>
  );
}

export default App;
