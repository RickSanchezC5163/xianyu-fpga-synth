/* 中文网页控制器：仅管理 HTTP 请求，不执行音乐节拍。
 * 所有曲名与响应均通过 textContent 写入，避免把上传文字作为 HTML 执行。
 * working 防止本页重复提交；真正的跨请求保护在固件互斥锁中。
 */
'use strict';
const el=id=>document.getElementById(id);
let working=false,initial=true,refreshing=false,catalogLoading=false,catalog=null;
const note=text=>{el('result').textContent=text;};
function lock(value){working=value;document.querySelectorAll('button').forEach(b=>{b.disabled=value;});}
/** 发送二进制曲谱或 JSON 配网请求；把 HTTP 202 解释为开始连接，而非已联网。 */
async function textRequest(path,body=new Uint8Array(),type='application/octet-stream'){
  const r=await fetch(path,{method:'POST',headers:{'Content-Type':type},body});
  let text=await r.text();
  if(path==='/network' && r.headers.get('content-type')?.includes('application/json')){
    const state=JSON.parse(text);
    text=state.connection_requested?'配网信息已保存，正在连接路由器；获得局域网地址后会显示在上方。':'配网信息已保存，但连接请求未成功；请检查设置后重试。';
  }
  note(r.ok?text:'操作未完成（'+r.status+'）：'+text);
  if(r.ok && (/^\/(score|select)(\?|$)/.test(path) || path==='/commit'))await readActiveScore();
  return r.ok;
}
/** Bounded title query; retain full names in the catalog, never split UTF-8. */
function metadataQuery(title,part=1,total=1){
  if(!Number.isInteger(part)||!Number.isInteger(total)||part<1||part>total||total>999)throw Error('片段编号无效');
  let short='';
  for(const c of String(title||'Wi-Fi Score')){
    if(new TextEncoder().encode(short+c).length>48)break;
    short+=c;
  }
  return 'title='+encodeURIComponent(short)+'&part='+part+'&total='+total;
}
/** Explicit real FPGA readback, separate from historical ACK / saved slots. */
async function readActiveScore(){
  const out=el('activeScore');out.textContent='当前FPGA曲谱：待读回';
  try{
    const r=await fetch('/fpga');if(!r.ok)throw Error('状态不可读');
    const d=await r.json();
    if(!d.confirmed){out.textContent='当前FPGA曲谱：未知（未获得有效读回，代码'+d.result+'）';return;}
    out.textContent=d.source==='rom'?'当前FPGA曲谱：ROM · 内置练习':
      '当前FPGA曲谱：Wi-Fi · '+d.title+(d.total?' · 第'+d.part+'/'+d.total+'段':'')+' · '+d.events+'事件 · '+d.bpm+' BPM';
  }catch(e){out.textContent='当前FPGA曲谱：未知（设备暂不可读）';}
}
/** 包装一次用户操作；禁止重复点击，并在结束后刷新曲库与状态。异常时不承诺提交未发生。 */
async function work(fn){
  if(working)return;
  lock(true);
  try{await fn();}catch(e){note('请求中断：'+e.message+'。若正在提交，结果可能未知；请刷新并查询设备。');}
  finally{lock(false);await refresh(false);}
}
/** 读取网络、设备和曲库快照；历史 FPGA ACK 与联网成功是不同状态。 */
async function refresh(showError=true){
  if(working || refreshing)return;
  refreshing=true;
  try{
    // 串行读取并消费正文，不让一个浏览器的状态轮询同时占三个socket。
    const states=[];
    for(const url of ['/network','/status','/library']){
      const r=await fetch(url);if(!r.ok)throw Error('ESP 正忙或状态暂不可读');states.push(await r.json());
    }
    const [n,d,l]=states;
    const network=el('networkState');network.replaceChildren();
    if(n.connected && n.station_ip){
      network.append(document.createTextNode('已连接 '+n.ssid+' · 局域网入口：'));
      const a=document.createElement('a');a.href='http://'+n.station_ip+'/';a.textContent=a.href;network.append(a);
    }else network.textContent=n.connecting?'正在连接路由器（重试 '+n.retry_count+'/'+n.retry_limit+'）':'尚未接入路由器；可通过设置热点 '+n.ap_ssid+' 打开 '+n.ap_ip;
    const ack=d.fpga_ack_seen?'最近 FPGA 回执 '+Math.floor(d.ack_age_ms/1000)+' 秒前':'尚未收到 FPGA 回执';
    let selected=d.selected_slot>=0?' · 本次会话已确认槽位 '+(d.selected_slot+1):'';
    if(d.pending_verified)selected+=' · 有已验证暂存曲谱，等待提交';
    el('deviceState').textContent=d.target+' · '+ack+selected;
    if(initial){el('ssid').value=n.ssid||'';el('networkDetails').open=!n.configured;initial=false;note('曲库已读取。保存文件不会自动传输；请选择曲目后发送给琴。');}
    renderScores(l.slots||[]);
  }catch(e){if(showError)note('读取失败：'+e.message);}
  finally{refreshing=false;}
}
function selectedCatalog(){
  if(!catalog)throw Error('内置曲目尚未读取，请点重读');
  const song=catalog.songs.find(s=>String(s.id)===el('catalogSong').value);
  const part=song?.parts.find(p=>String(p.number)===el('catalogPart').value);
  if(!part)throw Error('请选择有效片段');
  const bytes=Uint8Array.from(atob(catalog.blobs[part.blob]),c=>c.charCodeAt(0));
  if(bytes.length!==part.bytes || bytes.length<24 || bytes.length>2056 || String.fromCharCode(...bytes.slice(0,4))!=='XS01')throw Error('内置片段损坏，未发送');
  return {song,part,bytes};
}
function showCatalogInfo(){
  try{
    const {song,part}=selectedCatalog();
    const warnings=[song.mixed_voice?'混合声部分离草稿':'独立声部候选'];
    if(song.has_voice_gaps)warnings.push('主奏可能有交接空缺');
    if(song.parts.length<song.parts_total)warnings.push('含无法表示的缺段');
    el('catalogInfo').textContent=song.title+' · 第'+part.number+'段 / 共'+song.parts_total+'段 · '+(part.duration_ms/1000).toFixed(1)+'秒 · '+part.bpm+' BPM · '+part.bytes+'字节；'+song.parts.length+'段可用；'+warnings.join('，')+'，待听审';
  }catch(e){el('catalogInfo').textContent=e.message;}
}
function chooseCatalogSong(){
  const song=catalog?.songs.find(s=>String(s.id)===el('catalogSong').value);
  const selector=el('catalogPart');selector.replaceChildren();
  for(const p of song?.parts||[]){
    const option=document.createElement('option');option.value=String(p.number);
    option.textContent=song.title+' · 第'+String(p.number).padStart(2,'0')+'段 / 共'+song.parts_total+'段 · '+(p.duration_ms/1000).toFixed(1)+'秒';selector.append(option);
  }
  selector.value=song?.parts.length?String(song.parts[0].number):'';showCatalogInfo();
}
async function loadCatalog(){
  if(catalogLoading || working)return;
  catalogLoading=true;
  try{
    const r=await fetch('/catalog.json');if(!r.ok)throw Error('曲目目录暂不可读');
    const next=await r.json();if(next.version!==1 || !Array.isArray(next.songs)||!Array.isArray(next.blobs))throw Error('曲目目录版本不匹配');
    const old=el('catalogSong').value;catalog=next;el('catalogSong').replaceChildren();
    for(const song of catalog.songs){const option=document.createElement('option');option.value=String(song.id);option.textContent=song.title;el('catalogSong').append(option);}
    el('catalogSong').value=catalog.songs.some(s=>String(s.id)===old)?old:String((catalog.songs.find(s=>s.id===15)||catalog.songs[0]).id);
    chooseCatalogSong();
  }catch(e){el('catalogInfo').textContent='读取内置曲目失败：'+e.message;}
  finally{catalogLoading=false;}
}
/** 用 DOM 节点显示八槽位列表及操作按钮，不拼接不可信 HTML。 */
function renderScores(slots){
  const holder=el('scores');holder.replaceChildren();
  for(const s of slots){
    const row=document.createElement('div');row.className='score row between';
    const info=document.createElement('div'),title=document.createElement('h3'),meta=document.createElement('small');
    title.textContent=(s.slot+1)+'. '+(s.valid?s.title:s.empty?'空槽位':'文件不可读');
    meta.textContent=s.valid?s.events+' 个事件 · '+s.bpm+' BPM':s.empty?'可以保存新曲谱':s.error||'校验失败';
    info.append(title,meta);row.append(info);
    const actions=document.createElement('div');actions.className='row';
    if(s.valid){const send=document.createElement('button');send.textContent='发送给琴';send.disabled=working;send.onclick=()=>work(()=>textRequest('/select?slot='+s.slot));actions.append(send);}
    if(!s.empty){const del=document.createElement('button');del.className='danger';del.textContent='删除';del.disabled=working;del.onclick=()=>{if(confirm('从 ESP 曲库删除槽位 '+(s.slot+1)+'？不会清除 FPGA 活动谱。'))work(()=>textRequest('/delete?slot='+s.slot));};actions.append(del);}
    row.append(actions);holder.append(row);
  }
}
/** 浏览器预检查 XS01 文件大小和魔数；固件仍必须执行完整语义校验。 */
async function chosenFile(){
  const f=el('file').files[0];if(!f)throw Error('请选择 .xys 文件');
  if(f.size<24 || f.size>2056)throw Error('文件应为 24..2056 字节 XS01 符号谱');
  const bytes=await f.arrayBuffer();
  const first=new Uint8Array(bytes,0,4);
  if(String.fromCharCode(...first)!=='XS01')throw Error('文件不是 XS01；MIDI/录音需先转换，不能改扩展名代替');
  return bytes;
}
el('refresh').onclick=()=>refresh();
el('catalogReload').onclick=()=>loadCatalog();
el('catalogSong').onchange=()=>chooseCatalogSong();
el('catalogPart').onchange=()=>showCatalogInfo();
el('catalogSend').onclick=()=>work(async()=>{
  const {song,part,bytes}=selectedCatalog();
  return textRequest('/score?'+metadataQuery(song.title,part.number,song.parts_total),bytes);
});
el('catalogSave').onclick=()=>work(async()=>{
  const {part,bytes}=selectedCatalog(),slot=el('slot').value;
  if(!confirm('将'+part.storage_title+'保存到槽位 '+(Number(slot)+1)+'？该槽位原文件将被替换。'))return;
  await textRequest('/library?slot='+slot+'&title='+encodeURIComponent(part.storage_title),bytes);
});
el('probe').onclick=()=>work(()=>textRequest('/probe'));
el('fpgaRead').onclick=()=>work(()=>readActiveScore());
el('commit').onclick=()=>work(()=>textRequest('/commit'));
el('send').onclick=()=>work(async()=>textRequest('/score?'+metadataQuery(el('title').value),await chosenFile()));
el('save').onclick=()=>work(async()=>{
  const title=el('title').value.trim();
  if(!title || new TextEncoder().encode(title).length>48)throw Error('曲名需要 1..48 个 UTF-8 字节');
  const slot=el('slot').value;
  if(!confirm('保存到槽位 '+(Number(slot)+1)+'？该槽位原文件将被替换。'))return;
  await textRequest('/library?slot='+slot+'&title='+encodeURIComponent(title),await chosenFile());
});
el('file').onchange=()=>{const f=el('file').files[0];if(f && !el('title').value)el('title').value=f.name.replace(/\.[^.]+$/,'');};
el('networkForm').onsubmit=e=>{
  e.preventDefault();work(async()=>{
    const ssid=el('ssid').value,password=el('password').value;
    const sl=new TextEncoder().encode(ssid).length,pl=new TextEncoder().encode(password).length;
    if(sl<1 || sl>32 || (pl!==0 && (pl<8 || pl>63)))throw Error('Wi-Fi 名称需 1..32 字节；密码留空或 8..63 字节');
    await textRequest('/network',JSON.stringify({ssid,password}),'application/json');
    el('password').value='';
  });
};
el('forget').onclick=()=>{if(confirm('只忘记路由器连接？曲库保留，设置热点继续可用。'))work(()=>textRequest('/network/forget'));};
for(let n=0;n<8;n++){const o=document.createElement('option');o.value=n;o.textContent='槽位 '+(n+1);el('slot').append(o);}
refresh().then(()=>loadCatalog());setInterval(()=>refresh(false),4000);
