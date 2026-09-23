/* Local design state only. No persistence, file access, provider calls, or app services. */
let sources = structuredClone(initialSources);
let lang = 'zh', scope = 'all', status = 'all', order = 'recent', query = '';
let selected = 1, version = 2, activeTab = 'document', raw = false, citation = false;
let compact = false, scenario = 'populated', nextID = 10, toastTimer;
const $ = id => document.getElementById(id);
const t = (key, ...args) => typeof copy[lang][key] === 'function' ? copy[lang][key](...args) : copy[lang][key] || key;
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const icon = name => `<img src="assets/${name}.png" alt="">`;
const currentSource = () => sources.find(s => s.id === selected);
const scopeName = value => value === 'inbox' ? t('inbox') : value;
const sourceText = source => source.versions.find(v => v.number === source.current)?.text || '';
const isReady = source => source.current !== null;
const items = () => sources.filter(s => (scope === 'all' || s.scope === scope) && (status === 'all' || (status === 'ready' && isReady(s)) || (status === 'local' && !s.remote) || (status === 'failed' && !s.versions[0].ready)) && (!query || `${s.title}\n${sourceText(s)}`.toLocaleLowerCase().includes(query.toLocaleLowerCase()))).sort((a,b) => order === 'recent' ? b.rank-a.rank : a.title.localeCompare(b.title));
function marked(text) {
  if (!query) return esc(text);
  const start = text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase());
  return start < 0 ? esc(text) : `${esc(text.slice(0,start))}<mark>${esc(text.slice(start,start+query.length))}</mark>${esc(text.slice(start+query.length))}`;
}
function localize() {
  document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
  document.querySelectorAll('[data-copy]').forEach(el => el.textContent = t(el.dataset.copy));
  document.querySelectorAll('[data-label]').forEach(el => { el.setAttribute('aria-label',t(el.dataset.label)); el.title=t(el.dataset.label); });
  document.querySelectorAll('[data-placeholder]').forEach(el => { el.placeholder=t(el.dataset.placeholder); el.setAttribute('aria-label',t(el.dataset.placeholder)); });
  $('language').textContent = lang === 'zh' ? 'EN' : '中文';
  $('theme').innerHTML = icon(document.documentElement.dataset.theme === 'light' ? 'moon' : 'sun.max');
  $('scope').innerHTML = `<option value="all">${t('allScopes')}</option><option value="inbox">${t('inbox')}</option><option value="Mira">Mira</option><option value="Field Notes">Field Notes</option>`;
  $('status').innerHTML = `<option value="all">${t('allStatuses')}</option><option value="ready">${t('ready')}</option><option value="local">${t('localOnly')}</option><option value="failed">${t('needsAttention')}</option>`;
  $('sort').innerHTML = `<option value="recent">${t('recent')}</option><option value="title">${t('titleSort')}</option>`;
  $('scenario').innerHTML = ['populated','empty','citation','failure'].map(s => `<option value="${s}">${t(s === 'populated' ? s : s+'Scenario')}</option>`).join('');
  $('scope').value=scope; $('status').value=status; $('sort').value=order; $('scenario').value=scenario;
  $('design-notes').innerHTML=`<h2>${t('notesTitle')}</h2>${[1,2,3,4,5].map(n=>`<p>${t('notes'+n)}</p>`).join('')}`;
  render();
}
function choose(id, open = true) {
  selected=id;
  const source=currentSource();
  version=source?.current || source?.versions[0]?.number;
  activeTab='document'; raw=false; citation=false;
  if(open) $('window').classList.add('detail-open');
  render();
  if (!compact || !open) $('source-list').querySelector(`[data-source="${selected}"]`)?.scrollIntoView({block:'nearest'});
  $('reader').querySelector('.reader-body')?.scrollTo(0,0);
}
function render() {
  const rows=items();
  if(!rows.some(s=>s.id===selected)) {
    selected=rows[0]?.id ?? null;
    const source=currentSource(); version=source?.current || source?.versions[0]?.number;
    citation=false; raw=false;
  }
  $('result-count').textContent=t(query?'hits':'count',rows.length);
  $('source-list').innerHTML=rows.length ? rows.map(s=>{
    let snippet=s.snippet;
    if(query && sourceText(s).toLocaleLowerCase().includes(query.toLocaleLowerCase())) {
      const text=sourceText(s).replace(/\n/g,' '), pos=text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase());
      snippet=(pos>25?'…':'')+text.slice(Math.max(0,pos-25),pos+100);
    }
    return `<div role="listitem"><button class="source-row ${selected===s.id?'selected':''}" data-source="${s.id}" aria-current="${selected===s.id}" aria-label="${esc(s.title)}"><span class="row-title">${icon('doc.text')}<span>${marked(s.title)}</span></span><span class="row-snippet ${!isReady(s)?'row-failure':''}">${isReady(s)?marked(snippet):t('encodingError')}</span><span class="row-meta"><span>${scopeName(s.scope)}</span><span>·</span>${!s.versions[0].ready?`<span class="row-failure">${t(s.current?'updateFailed':'failed')}</span>`:!s.remote?`<span class="row-local">${icon('lock')}${t('localOnly')}</span>`:`<span>${t('markdown')}</span>`}<time>${s.date}</time></span></button></div>`;
  }).join('') : `<div class="empty-state">${icon(query||sources.length?'magnifyingglass':'book.closed')}<h2>${t(sources.length?'noResults':'emptyTitle')}</h2><p>${t(sources.length?'noResultsBody':'emptyBody')}</p><button class="button secondary" data-action="${sources.length?'clear':'import'}">${sources.length?'':icon('plus')}${t(sources.length?'clearFilters':'import')}</button></div>`;
  renderReader();
}
function inline(text) { return esc(text).replace(/`([^`]+)`/g,'<code>$1</code>'); }
function markdown(text) {
  let inList=false;
  const result=[];
  for(const line of text.split('\n')) {
    if(line.startsWith('- ')) { if(!inList){result.push('<ul>');inList=true;} result.push(`<li>${inline(line.slice(2))}</li>`); continue; }
    if(inList){result.push('</ul>');inList=false;}
    if(line.startsWith('# '))result.push(`<h2>${inline(line.slice(2))}</h2>`);
    else if(line.startsWith('## '))result.push(`<h3>${inline(line.slice(3))}</h3>`);
    else if(line.startsWith('> '))result.push(`<blockquote>${inline(line.slice(2))}</blockquote>`);
    else if(line.trim())result.push(`<p>${inline(line)}</p>`);
  }
  if(inList)result.push('</ul>');
  return result.join('');
}
function notice(message, symbol='info.circle', action='') { return `<div class="notice">${icon(symbol)}<div class="notice-body">${message}${action}</div></div>`; }
function renderReader() {
  const s=currentSource();
  if(!s){$('reader').innerHTML=`<div class="empty-reader">${t('selectSource')}</div>`;return;}
  const v=s.versions.find(v=>v.number===version) || s.versions[0];
  version=v.number;
  const versions=s.versions.map(v=>`<option value="${v.number}">${t(v.number===s.current?'currentVersion':'version',v.number)}${v.ready?'':' · '+t('failed')}</option>`).join('');
  $('reader').innerHTML=`<div class="reader-heading"><div class="reader-topline"><button class="text-button back-button" data-action="back">${icon('chevron.left')}${t('back')}</button><div class="breadcrumb">${icon(s.scope==='inbox'?'tray':'folder')}<span>${scopeName(s.scope)}</span><span>/</span><span>${t('markdown')}</span></div><div class="reader-actions"><button class="permission-badge" data-action="permission" aria-label="${t('permission')}">${icon(s.remote?'checkmark':'lock')}${t(s.remote?'modelUse':'localOnly')}</button><button class="icon-button" data-action="more" aria-label="${t('more')}">${icon('ellipsis')}</button></div></div><h2>${esc(s.title)}</h2><p class="reader-filename">${esc(s.file)}<span> · ${esc(s.size)}</span></p><div class="reader-tabs" role="tablist" aria-label="${t('sourcePreview')}">${['document','versions','information'].map(tab=>`<button role="tab" aria-selected="${activeTab===tab}" data-tab="${tab}">${t(tab)}</button>`).join('')}<select class="version-select" id="version-select" aria-label="${t('versionLabel')}">${versions}</select></div></div><div class="reader-body" role="tabpanel"><div class="reading-content">${activeTab==='versions'?history(s):activeTab==='information'?information(s):documentBody(s,v)}</div></div><footer class="reader-footer"><span>${activeTab==='document'?t('snapshotHint'):t('localSnapshots')}</span>${activeTab==='document'&&v.ready?`<button class="text-button" data-action="raw">${icon(raw?'book.closed':'text.alignleft')}${t(raw?'readPreview':'readOriginal')}</button>`:''}</footer>`;
  $('version-select').value=version;
}
function documentBody(s,v) {
  if(citation && !s.remote)return `<div class="empty-state">${icon('lock')}<h2>${t('citationUnavailable')}</h2><p>${t('citationUnavailableBody')}</p></div>`;
  if(!v.ready)return `<div class="empty-state">${icon('exclamationmark.circle')}<h2>${t('failedNoCurrent')}</h2><p>${t('encodingError')}</p><p>${t(s.current?'failedCurrent':'failedBody')}</p><button class="button secondary" data-action="update">${t('retry')}</button>${s.current?`<button class="text-button" data-action="current">${t('backCurrent')}</button>`:''}</div>`;
  let banner=citation?notice(t('citationNotice'),'quote.bubble'):v.number!==s.current?notice(t('historicalNotice'),'clock',` <button class="text-button" data-action="current">${t('backCurrent')}</button>`):'';
  if(s.versions[0].ready===false && v.number===s.current)banner+=notice(t('failedCurrent'),'exclamationmark.circle');
  const contentLang=/[\u4e00-\u9fff]/.test(v.text)?'zh-CN':'en';
  if(raw || citation)return banner+`<div class="raw-source" lang="${contentLang}">${v.text.split('\n').map((line,i)=>`<div class="raw-line ${citation&&i>=13&&i<=15?'highlight':''}"><span class="line-number">${i+1}</span><span>${marked(line)||' '}</span></div>`).join('')}</div>`;
  return banner+`<article class="document" lang="${contentLang}">${markdown(v.text)}</article>`;
}
function history(s) {
  return `<p class="history-help">${t('versionsHelp')}</p>${s.versions.map(v=>`<div class="history-row"><span class="history-symbol">${icon(v.ready?'clock':'exclamationmark.circle')}</span><div class="history-content"><div class="history-title">${t('version',v.number)}${v.number===s.current?`<span class="pill">${t('current')}</span>`:''}${!v.ready?`<span class="pill">${t('failed')}</span>`:''}</div><div class="history-date">${v.date}</div><p>${t(!v.ready?'failedUpdate':v.number===1?'firstImport':'successfulUpdate')}</p></div><button class="text-button" data-version="${v.number}">${t('view')}</button></div>`).join('')}<p class="form-help">${t('historyUnchanged')}</p>`;
}
function information(s) {
  const row=(key,value)=>`<div class="info-row"><span>${t(key)}</span><span>${value}</span></div>`;
  return `<section class="info-section"><h3>${t('information')}</h3>${row('scope',scopeName(s.scope))}${row('file',esc(s.file))}${row('sourceType',t('snapshot')+' · Markdown')}${row('parseState',t(isReady(s)?'ready':'failed'))}${row('versionCount',s.versions.length)}${row('imported',s.versions[s.versions.length-1].date)}${row('updated',s.versions[0].date)}<p class="form-help">${t('fileAccess')}</p></section><section class="info-section"><h3>${t('permission')}</h3><div class="policy-panel"><div class="policy-header"><span>${t(s.remote?'modelUse':'localOnly')}</span><button class="text-button" data-action="permission">${t('changePermission')}</button></div><p>${t(s.remote?'remoteDescription':'localDescription')}</p></div></section><div class="source-bottom-actions"><button class="button secondary" data-action="update">${icon('arrow.up.doc')}${t('update')}</button><button class="text-button danger-text" data-action="delete">${t('delete')}</button></div>`;
}
function openDialog(title,body,actions='') {
  const dialog=$('modal');
  dialog.style.width='530px';
  dialog.innerHTML=`<div class="dialog-heading"><h2 id="modal-title">${title}</h2><button class="icon-button" data-action="close" aria-label="${t('close')}">${icon('xmark')}</button></div>${body}${actions?`<div class="dialog-actions">${actions}</div>`:''}`;
  if(!dialog.open)dialog.showModal();
}
const closeDialog=()=> $('modal').close();
const cancelButton=()=>`<button class="button secondary" data-action="close">${t('cancel')}</button>`;
function toast(message) { clearTimeout(toastTimer);$('toast').textContent=message;$('toast').hidden=false;toastTimer=setTimeout(()=>{$('toast').hidden=true;},4200); }
function importDialog() {
  openDialog(t('importTitle'),`<p class="dialog-intro">${t('importIntro')}</p><div class="drop-zone" id="file-choice">${icon('square.and.arrow.down')}<p>${t('dropHint')}</p><button class="button secondary" data-action="sample-files">${t('chooseSamples')}</button><small>${t('formatHint')}</small></div><div class="form-row"><label for="import-scope">${t('importScope')}</label><select id="import-scope"><option>Mira</option><option value="inbox">${t('inbox')}</option><option>Field Notes</option></select></div><div class="form-row"><label for="import-remote">${t('allowRemote')}</label><input id="import-remote" type="checkbox"></div><p class="form-help">${t('allowRemoteHelp')}</p><p class="form-help">${t('sampleHelp')}</p>`,`${cancelButton()}<button id="import-confirm" class="button primary" data-action="import-confirm" disabled>${t('startImport')}</button>`);
  $('import-scope').value=scope==='all'?'Mira':scope;
}
function sampleFiles() {
  $('file-choice').className='';
  $('file-choice').innerHTML=['sampleNew','sampleDuplicate','sampleBad'].map(key=>`<div class="file-result">${icon('doc.text')}<div><strong>${t(key)}</strong><p>Markdown</p></div><span class="file-state">${key==='sampleNew'?'1.1':key==='sampleDuplicate'?'3.2':'4.6'} KB</span></div>`).join('');
  $('import-confirm').disabled=false;
}
function finishImport() {
  const target=$('import-scope').value, remote=$('import-remote').checked;
  const duplicate=sources.find(s=>s.title===initialSources[0].title&&s.scope===target&&sourceText(s)===principleText);
  const newSource={id:nextID++,title:'阅读方法',file:'阅读方法.md',scope:target,remote,rank:20,date:'09-23',size:'1.1 KB',snippet:'阅读前提出一个问题，读完后回到这个问题。',current:1,versions:[{number:1,date:'2026-09-23 · 11:08',ready:true,text:'# 阅读方法\n\n阅读前提出一个问题，读完后回到这个问题。\n\n## 阅读时\n\n- 保存值得重读的原文与出处。\n- 把作者的观点和自己的判断分开。\n- 记录尚未解决的问题。\n\n## 阅读后\n\n用几句话说明什么改变了。必要时回到原文，而不是只依赖摘要。'}]};
  sources.push(newSource);
  if(!duplicate)sources.push({...structuredClone(initialSources[0]),id:nextID++,scope:target,remote,rank:19,current:1,versions:[{number:1,date:'2026-09-23 · 11:08',ready:true,text:principleText}]});
  sources.push({...structuredClone(initialSources[4]),id:nextID++,scope:target,rank:18,date:'09-23'});
  scope=target;status='all';query='';$('search').value='';scenario='populated';selected=newSource.id;version=1;
  localize();$('window').classList.add('detail-open');
  const summary=lang==='zh'?`${duplicate?1:2} 份已导入，${duplicate?1:0} 份已存在，1 份需要处理。`:`${duplicate?1:2} imported, ${duplicate?1:0} already exists, and 1 needs attention.`;
  openDialog(t('importResultTitle'),`<p class="dialog-intro">${summary}</p>${[['sampleNew','added',''],['sampleDuplicate',duplicate?'duplicate':'added',duplicate?'duplicateHelp':''],['sampleBad','failed','encodingError']].map(([name,state,help])=>`<div class="file-result ${state==='failed'?'failed':''}">${icon(state==='failed'?'exclamationmark.circle':'checkmark')}<div><strong>${t(name)}</strong>${help?`<p>${t(help)}</p>`:''}</div><span class="file-state">${t(state)}</span></div>`).join('')}`,`<button class="button primary" data-action="close">${t('viewImported')}</button>`);
}
function updateDialog() {
  const s=currentSource(); if(!s)return;
  openDialog(t('updateTitle'),`<p class="dialog-intro">${t('updateIntro')}</p><div class="target-card">${esc(s.title)}<small>${scopeName(s.scope)} · ${s.current?t('currentVersion',s.current):t('failed')}</small></div><p class="form-help">${t('updateName')}</p><div class="drop-zone" style="margin-top:18px">${icon('arrow.up.doc')}<button class="button secondary" data-action="choose-update">${t('chooseUpdate')}</button></div><div id="update-options" hidden><label class="radio-choice"><input type="radio" name="update-result" value="ready" checked>${t('updateSuccess')}</label><label class="radio-choice"><input type="radio" name="update-result" value="failed">${t('updateFailure')}</label></div><p class="form-help">${t('sampleHelp')}</p>`,`${cancelButton()}<button id="update-confirm" class="button primary" data-action="update-confirm" disabled>${t('confirmUpdate')}</button>`);
}
function finishUpdate() {
  const s=currentSource();if(!s)return;
  const ready=document.querySelector('input[name="update-result"]:checked').value==='ready';
  const number=Math.max(...s.versions.map(v=>v.number))+1;
  const text=(sourceText(s)||'# 访谈记录\n\n已重新保存为 UTF-8 的访谈记录。')+'\n\n## 补充说明\n\n本次更新补充了资料阅读与引用的说明。旧版本继续保留。';
  s.versions.unshift({number,date:'2026-09-23 · 11:20',ready,text:ready?text:''});
  if(ready){s.current=number;version=number;s.snippet=s.snippet||'已重新保存为 UTF-8 的访谈记录。';}else version=s.current||number;
  s.rank=30;s.date='09-23';activeTab='document';raw=false;citation=false;
  closeDialog();render();toast(t(ready?'updateToast':'updateFailedToast'));
}
function permissionDialog() {
  const s=currentSource();if(!s)return;
  openDialog(t(s.remote?'revokeTitle':'allowTitle'),`<p class="dialog-intro">${t(s.remote?'revokeIntro':'allowIntro')}</p><div class="target-card">${esc(s.title)}<small>${scopeName(s.scope)}</small></div>${s.remote?`<p class="dialog-intro">${t('revokeImpact')}</p>`:''}`,`${cancelButton()}<button class="button primary" data-action="permission-confirm">${t(s.remote?'revokeConfirm':'allowConfirm')}</button>`);
}
function deleteDialog() {
  const s=currentSource();if(!s)return;
  openDialog(t('deleteTitle'),`<p class="dialog-intro">${t('deleteIntro')}</p><div class="target-card">${esc(s.title)}<small>${scopeName(s.scope)} · ${t('versionTotal',s.versions.length)}</small></div><ul class="impact-list"><li>${t('deleteImpact1')}</li><li>${t('deleteImpact2')}</li></ul>`,`${cancelButton()}<button class="button danger" data-action="delete-confirm">${t('deleteConfirm')}</button>`);
}
function citationDialog() {
  const s=sources.find(s=>s.id===1);
  const unavailable=!s||!s.remote;
  openDialog(t('citationTitle'),`<p class="dialog-intro">${t('citationConversation')} · 2026-09-19</p>${unavailable?notice(t('citationUnavailableBody'),'lock'):`<div class="target-card" lang="zh-CN">${t('citationQuestion')}</div><p class="dialog-intro" lang="zh-CN">${t('citationAnswer')}</p><div class="target-card">${esc(s.title)}<small>${t('version',1)} · L14–16</small></div>`}`,`<button class="button ${unavailable?'secondary':'primary'}" data-action="${unavailable?'close':'open-citation'}">${t(unavailable?'close':'openCitation')}</button>`);
}
function resetState() {
  sources=structuredClone(initialSources);scope='all';status='all';order='recent';query='';selected=1;version=2;activeTab='document';raw=false;citation=false;scenario='populated';nextID=10;
  $('search').value='';$('window').classList.remove('detail-open');closeDialog();clearTimeout(toastTimer);$('toast').hidden=true;localize();
}
function setScenario(value) {
  scenario=value;
  if(value==='empty'){sources=[];selected=null;scope='all';status='all';query='';$('search').value='';$('window').classList.remove('detail-open');localize();}
  else if(value==='citation')citationDialog();
  else if(value==='failure'){
    if(!sources.some(s=>s.id===5))sources.push(structuredClone(initialSources[4]));
    scope='all';status='all';query='';$('search').value='';choose(5);localize();
  }else resetState();
  $('scenario').value=scenario;
}
function fit() {
  const width=compact?850:1280,height=compact?620:800;
  const rect=$('stage').getBoundingClientRect();
  const scale=Math.min(1,(rect.width-32)/width,Math.max(.25,(rect.height-30)/height));
  $('window').style.transform=`scale(${scale})`;
  $('frame-slot').style.width=width*scale+'px';$('frame-slot').style.height=height*scale+'px';
}
document.addEventListener('click',event=>{
  const source=event.target.closest('[data-source]');if(source){choose(Number(source.dataset.source));return;}
  const tab=event.target.closest('[data-tab]');if(tab){activeTab=tab.dataset.tab;renderReader();return;}
  const historyVersion=event.target.closest('[data-version]');if(historyVersion){version=Number(historyVersion.dataset.version);activeTab='document';raw=false;citation=false;renderReader();return;}
  const button=event.target.closest('[data-action]');if(!button)return;
  const action=button.dataset.action;
  if(action==='close')closeDialog();
  else if(action==='import')importDialog();
  else if(action==='sample-files')sampleFiles();
  else if(action==='import-confirm')finishImport();
  else if(action==='update')updateDialog();
  else if(action==='choose-update'){$('update-options').hidden=false;$('update-confirm').disabled=false;button.innerHTML=icon('checkmark')+'Markdown';}
  else if(action==='update-confirm')finishUpdate();
  else if(action==='permission')permissionDialog();
  else if(action==='permission-confirm') { const s=currentSource();s.remote=!s.remote;closeDialog();render();toast(t(s.remote?'allowToast':'revokeToast')); }
  else if(action==='delete')deleteDialog();
  else if(action==='delete-confirm'){sources=sources.filter(s=>s.id!==selected);closeDialog();$('window').classList.remove('detail-open');render();toast(t('deleteToast'));}
  else if(action==='more'){
    openDialog(t('more'),`<div class="menu" style="margin-top:14px"><button data-action="update">${icon('arrow.up.doc')}${t('update')}</button><button data-action="permission">${icon('lock')}${t('permission')}</button><button data-action="delete" class="danger-text">${icon('trash')}${t('delete')}</button></div>`);$('modal').style.width='330px';
  }else if(action==='raw'){raw=!raw;citation=false;renderReader();}
  else if(action==='back'){$('window').classList.remove('detail-open');$('source-list').querySelector(`[data-source="${selected}"]`)?.focus({preventScroll:true});}
  else if(action==='current'){version=currentSource().current;raw=false;citation=false;activeTab='document';renderReader();}
  else if(action==='clear'){scope='all';status='all';query='';$('search').value='';localize();}
  else if(action==='open-citation'){
    scope='all';status='all';query='';$('search').value='';selected=1;version=1;activeTab='document';citation=true;raw=true;closeDialog();$('window').classList.add('detail-open');localize();
    $('reader').querySelector('.highlight')?.scrollIntoView({block:'center'});
  }
});
$('search').addEventListener('input',event=>{query=event.target.value;render();});
$('scope').addEventListener('change',event=>{scope=event.target.value;render();});
$('status').addEventListener('change',event=>{status=event.target.value;render();});
$('sort').addEventListener('change',event=>{order=event.target.value;render();});
$('reader').addEventListener('change',event=>{if(event.target.id==='version-select'){version=Number(event.target.value);activeTab='document';raw=false;citation=false;renderReader();}});
$('scenario').addEventListener('change',event=>setScenario(event.target.value));
$('theme').addEventListener('click',()=>{document.documentElement.dataset.theme=document.documentElement.dataset.theme==='light'?'dark':'light';localize();});
$('language').addEventListener('click',()=>{lang=lang==='zh'?'en':'zh';localize();});
$('size').addEventListener('click',()=>{compact=!compact;$('window').classList.toggle('compact',compact);$('window').classList.remove('detail-open');$('size').setAttribute('aria-pressed',String(compact));fit();});
$('reset').addEventListener('click',resetState);
$('notes').addEventListener('click',()=>{const open=$('design-notes').hidden;$('design-notes').hidden=!open;$('notes').setAttribute('aria-expanded',String(open));});
$('hide-sidebar').addEventListener('click',()=>$('window').classList.add('sidebar-hidden'));
$('show-sidebar').addEventListener('click',()=>$('window').classList.remove('sidebar-hidden'));
$('knowledge-nav').addEventListener('click',()=>{scope='all';status='all';query='';$('search').value='';$('window').classList.remove('detail-open');localize();});
$('source-list').addEventListener('keydown',event=>{
  const rows=items(), index=rows.findIndex(s=>s.id===selected);
  if(['ArrowDown','ArrowUp'].includes(event.key)&&rows.length){event.preventDefault();const offset=event.key==='ArrowDown'?1:-1;choose(rows[Math.max(0,Math.min(rows.length-1,index+offset))].id,false);$('source-list').querySelector(`[data-source="${selected}"]`)?.focus();}
});
document.addEventListener('keydown',event=>{
  if((event.metaKey||event.ctrlKey)&&event.key==='f'&&!$('modal').open){event.preventDefault();$('window').classList.remove('detail-open');$('search').focus();}
  if(event.key==='Escape'&&!$('modal').open){$('design-notes').hidden=true;$('notes').setAttribute('aria-expanded','false');}
});
window.addEventListener('resize',fit);
localize();fit();
