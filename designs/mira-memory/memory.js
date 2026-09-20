/* Design-only state. Chinese sample quotations are intentional synthetic user content. */
const copy = {
  zh: {
    designTitle:'记忆管理',synthetic:'设计预览 · 合成示例',emptyPreview:'空状态',reset:'重置',designNotes:'设计说明',
    memories:'记忆',newConversation:'新对话',knowledge:'知识库',tasks:'任务',workspace:'工作区',inbox:'收件箱',createWorkspace:'创建工作区',conversations:'最近对话',settings:'设置',
    addMemory:'添加记忆',search:'搜索记忆内容',scopeFilter:'筛选适用范围',allScopes:'全部范围',global:'全局',current:'当前',history:'历史',sort:'排序方式',recent:'最近更新',oldest:'最早更新',
    captureHint:'对话中形成的记忆会出现在这里。',toggleSidebar:'切换侧栏',theme:'深色',light:'浅色',count:n=>`${n} 条记忆`,
    active:'当前有效',superseded:'已替代',archived:'已归档',forgottenStatus:'已遗忘',forgottenTitle:'这条记忆已遗忘',forgottenBody:'记忆正文和来源摘录已清除，仅保留遗忘状态。原对话仍可在本机阅读。',automatic:'自动记住',explicit:'明确记住',manual:'手动添加',
    preference:'偏好',constraint:'约束',goal:'目标',fact:'事实',procedure:'流程',decision:'决定',context:'背景',learning:'经验',
    edit:'编辑文字',replace:'更新为新记忆',more:'更多操作',back:'返回列表',type:'类型',scope:'适用范围',remote:'模型使用',remoteOn:'允许用于远程模型',localOnly:'仅保存在本地',remoteHelp:'实际使用仍受来源和工作区权限限制。',localHelp:'不会发送给远程模型。',globalHelp:'可在各工作区中召回',projectHelp:'仅用于此工作区',
    source:'来源',sourceMessage:'你的原话',viewSource:'查看原对话',manualSource:'由你手动添加',manualSourceHint:'这条记忆没有关联的对话来源。',changes:'最近变化',viewHistory:'查看记录',saved:'记住这条信息',revised:'修正了文字表述',replaced:'替代了之前的偏好',oldLabel:'之前的记忆',newLabel:'新的记忆',
    historicalNote:'这条记忆已被替代，不再用于普通召回。',archivedNote:'这条记忆已归档，暂不用于召回。',viewCurrent:'查看当前记忆',valid:'持续有效',forget:'遗忘这条记忆',archive:'归档',restore:'恢复使用',
    emptyTitle:'还没有记忆',emptyBody:'你可以手动添加，也可以在对话中告诉 Mira 值得长期记住的信息。',noResults:'没有找到相关记忆',noResultsBody:'试试更短的关键词，或切换适用范围。',clearSearch:'清除搜索',emptyHistory:'还没有历史记录',emptyHistoryBody:'被替代、归档或遗忘的记录会显示在这里。',selectMemory:'选择一条记忆，查看内容与来源',
    editTitle:'编辑文字',editIntro:'修正措辞或补充说明，保留这条记忆的身份与来源。如果事实或偏好变了，请使用“更新为新记忆”。',replaceTitle:'更新为新记忆',replaceIntro:'新的记忆生效后，旧记忆保留在历史中，不再参与普通召回。',newTitle:'添加记忆',newIntro:'记下一条长期有用的信息，例如偏好、约束或决定。',content:'记忆内容',cancel:'取消',save:'保存修改',create:'添加',confirmReplace:'确认替代',sensitive:'敏感信息',sensitiveHelp:'标记后默认仅保存在本地。',remoteToggle:'允许用于远程模型',remoteToggleHelp:'与对话相关时，可发送给你配置的模型服务。',fixedScope:'已有记忆的适用范围保持不变。',contentRequired:'请输入记忆内容。',
    forgetTitle:'遗忘这条记忆？',forgetIntro:'记忆正文、来源摘录及相关派生内容将清除。Mira 会保留遗忘记录，防止从同一来源自动记回。',forgetPreserve:'原对话中的消息仍可在本机阅读。',forgetIrreversible:'此操作无法撤销。',confirmForget:'遗忘',forgotten:'已遗忘。原对话仍保留。',updated:'文字已更新，原始来源保持不变。',created:'已添加记忆。',replacedToast:'新记忆已生效，旧记忆保留在历史中。',archivedToast:'已归档，不再用于召回。',restoredToast:'已恢复为当前记忆。',
    sourceTitle:'原对话',sourceContext:'来源消息',sourcePreview:'来源预览 · 合成内容',close:'关闭',revisionTitle:'变化记录',revisionIntro:'文字修订与含义变化分别保留。来源中的原话不会随编辑改变。',currentText:'当前表述',originalText:'最初记住',
    notesTitle:'设计提案 01',notes1:'<strong>延续现有窗口。</strong>保留 Mira 侧栏、34 pt 导航行、52 pt 标题栏和中性配色。主区以列表与详情承载记忆。',notes2:'<strong>内容优先，来源紧随。</strong>列表直接展示记忆，详情解释范围、模型使用权限和原话。文字编辑与含义变化分开。',notes3:'<strong>窄窗单页深入。</strong>850 × 620 时先看列表，点击进入详情，可返回原列表。深色、中英文和空状态可在顶栏切换。',notes4:'<strong>仅供评审。</strong>全部记录为合成示例；操作只改变当前预览。尚未接入 Swift、资料库或模型服务。原生玻璃与控件以最终 macOS 实现为准。',
    historyFooter:'历史记忆不参与普通召回',detailFooter:'由你管理，随时可以纠正',unchanged:'内容未改变。',
  },
  en: {
    designTitle:'Memory management',synthetic:'Design preview · synthetic data',emptyPreview:'Empty state',reset:'Reset',designNotes:'Design notes',
    memories:'Memories',newConversation:'New conversation',knowledge:'Knowledge',tasks:'Tasks',workspace:'Workspace',inbox:'Inbox',createWorkspace:'Create workspace',conversations:'Recent conversations',settings:'Settings',
    addMemory:'Add memory',search:'Search memory content',scopeFilter:'Filter by scope',allScopes:'All scopes',global:'Global',current:'Current',history:'History',sort:'Sort order',recent:'Recently updated',oldest:'Oldest first',
    captureHint:'Memories formed in conversations appear here.',toggleSidebar:'Toggle sidebar',theme:'Dark',light:'Light',count:n=>`${n} ${n===1?'memory':'memories'}`,
    active:'Current',superseded:'Superseded',archived:'Archived',forgottenStatus:'Forgotten',forgottenTitle:'This memory was forgotten',forgottenBody:'Memory text and source excerpts have been cleared. Only the forgotten status remains. Original conversations are still readable locally.',automatic:'Captured automatically',explicit:'Explicitly saved',manual:'Added by you',
    preference:'Preference',constraint:'Constraint',goal:'Goal',fact:'Fact',procedure:'Procedure',decision:'Decision',context:'Context',learning:'Learning',
    edit:'Edit wording',replace:'Replace with new memory',more:'More actions',back:'Back to list',type:'Kind',scope:'Scope',remote:'Model use',remoteOn:'Allowed in remote requests',localOnly:'Local only',remoteHelp:'Source and workspace permissions still apply.',localHelp:'Not sent to remote models.',globalHelp:'Available across workspaces',projectHelp:'Only in this workspace',
    source:'Source',sourceMessage:'Your words',viewSource:'View conversation',manualSource:'Added by you',manualSourceHint:'This memory has no linked conversation source.',changes:'Recent changes',viewHistory:'View history',saved:'This information was remembered',revised:'Wording corrected',replaced:'Replaced an earlier preference',oldLabel:'Previous memory',newLabel:'New memory',
    historicalNote:'This memory has been superseded and is excluded from normal recall.',archivedNote:'This memory is archived and excluded from recall.',viewCurrent:'View current memory',valid:'No expiration',forget:'Forget this memory',archive:'Archive',restore:'Use again',
    emptyTitle:'No memories yet',emptyBody:'Add a memory yourself, or tell Mira what is worth remembering in a conversation.',noResults:'No matching memories',noResultsBody:'Try a shorter search or change the scope.',clearSearch:'Clear search',emptyHistory:'No history yet',emptyHistoryBody:'Superseded, archived, and forgotten records will appear here.',selectMemory:'Select a memory to view its content and source',
    editTitle:'Edit wording',editIntro:'Correct wording while preserving this memory and its source. If the fact or preference changed, use “Replace with new memory”.',replaceTitle:'Replace with new memory',replaceIntro:'The new memory becomes current. The previous memory remains in history and is excluded from normal recall.',newTitle:'Add memory',newIntro:'Save something useful for the long term, such as a preference, constraint, or decision.',content:'Memory content',cancel:'Cancel',save:'Save changes',create:'Add',confirmReplace:'Confirm replacement',sensitive:'Sensitive information',sensitiveHelp:'Local-only by default when marked sensitive.',remoteToggle:'Allow use in remote model requests',remoteToggleHelp:'May be sent to a configured provider when relevant.',fixedScope:'The scope of an existing memory stays unchanged.',contentRequired:'Enter memory content.',
    forgetTitle:'Forget this memory?',forgetIntro:'Memory text, source excerpts, and related derived content will be cleared. A forgotten record remains to prevent automatic capture from the same source.',forgetPreserve:'Original conversation messages remain readable locally.',forgetIrreversible:'This cannot be undone.',confirmForget:'Forget',forgotten:'Forgotten. The original conversation is preserved.',updated:'Wording updated. The original source is unchanged.',created:'Memory added.',replacedToast:'New memory is current. The previous one remains in history.',archivedToast:'Archived and excluded from recall.',restoredToast:'Restored as a current memory.',
    sourceTitle:'Original conversation',sourceContext:'Source message',sourcePreview:'Source preview · synthetic content',close:'Close',revisionTitle:'Change history',revisionIntro:'Wording revisions and changes in meaning are distinct. Editing never changes the original quotation.',currentText:'Current wording',originalText:'First remembered',
    notesTitle:'Design proposal 01',notes1:'<strong>Keep the existing shell.</strong>Preserve the Mira sidebar, 34 pt navigation rows, 52 pt titlebar, and neutral palette. Use a list and detail pane for memories.',notes2:'<strong>Content, followed by evidence.</strong>Show scope, remote-use policy, and the original quotation. Separate wording edits from changes in meaning.',notes3:'<strong>Drill in at minimum size.</strong>At 850 × 620, open details from the list and return without losing context. Preview dark mode, both languages, and empty states above.',notes4:'<strong>For review only.</strong>All records are synthetic; actions affect this preview only. No Swift, library, or model integration. Browser approximations do not establish native macOS visual acceptance.',
    historyFooter:'Historical memories are excluded from normal recall',detailFooter:'Yours to review and correct',unchanged:'No changes to save.',
  }
};

const initialMemories = [
  {id:1,content:'回复先给结论，再展开必要的细节。',scope:'global',kind:'preference',origin:'automatic',remote:true,status:'active',date:'09-20',time:'10:24',rank:20,sourceTitle:'更合适的回答方式',quote:'以后回答问题，先告诉我结论，再展开必要的细节。复杂的问题可以多解释一点，不用刻意压缩成几句话。',changes:['replaced','saved'],replaces:7},
  {id:2,content:'Mira 的界面保持中性配色，优先使用系统字体与原生控件。',scope:'Mira',kind:'decision',origin:'explicit',remote:true,status:'active',date:'09-19',time:'16:38',rank:19,sourceTitle:'Mira 的设计方向',quote:'记住，Mira 的界面保持中性配色，优先使用系统字体与原生控件。',changes:['saved']},
  {id:3,content:'技术文档以中文解释思路，代码和标识符保留英文。',scope:'global',kind:'preference',origin:'automatic',remote:true,status:'active',date:'09-19',time:'09:12',rank:18,sourceTitle:'文档怎么写更顺手',quote:'技术文档用中文解释思路我读起来更快，代码和标识符还是保留英文。',changes:['saved']},
  {id:4,content:'Mira 的首版先完成 macOS，iOS 放在后续阶段。',scope:'Mira',kind:'constraint',origin:'explicit',remote:true,status:'active',date:'09-18',time:'14:05',rank:17,sourceTitle:'首版范围',quote:'先把 macOS 这一版做好，iOS 等后面再说。记住这个范围。',changes:['saved']},
  {id:5,content:'每周留出一段完整的时间阅读，不把它拆成零碎任务。',scope:'global',kind:'goal',origin:'manual',remote:false,status:'active',date:'09-17',time:'20:16',rank:16,sourceTitle:'',quote:'',changes:['saved']},
  {id:6,content:'比较方案时，先列关键取舍，再给出明确建议。',scope:'global',kind:'preference',origin:'automatic',remote:true,status:'active',date:'09-16',time:'11:32',rank:15,sourceTitle:'选择一个更合适的方案',quote:'比较方案时先把关键取舍列出来，最后给我一个明确的建议。',changes:['saved']},
  {id:7,content:'回复尽量压缩到三句话以内。',scope:'global',kind:'preference',origin:'automatic',remote:true,status:'superseded',date:'09-20',time:'10:24',rank:14,sourceTitle:'简短一点的回答',quote:'最近我只想快速浏览，回复尽量压缩到三句话以内。',changes:['saved'],replacedBy:1},
  {id:8,content:'阅读时优先选择纸质书。',scope:'global',kind:'preference',origin:'manual',remote:false,status:'archived',date:'09-12',time:'18:03',rank:13,sourceTitle:'',quote:'',changes:['saved']}
].map(m=>({...m,sourceDate:m.date,sourceTime:m.time}));
let memories=structuredClone(initialMemories),lang='zh',tab='current',query='',scope='all',sort='recent',selected=1,emptyMode=false,nextId=10,toastTimer;
const $=id=>document.getElementById(id);
const t=(key,...args)=>typeof copy[lang][key]==='function'?copy[lang][key](...args):copy[lang][key]||key;
const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const icon=(name)=>`<img src="assets/${name}.png" alt="">`;
const scopeName=m=>m.scope==='global'?t('global'):m.scope;
const scopeIcon=m=>m.scope==='global'?'globe':'folder';
const currentMemory=()=>memories.find(m=>m.id===selected);
const available=()=>emptyMode?[]:memories.filter(m=>(tab==='current'?m.status==='active':m.status!=='active')&&(scope==='all'||m.scope===scope)&&(!query||(m.content||t('forgottenTitle')).toLocaleLowerCase().includes(query.toLocaleLowerCase()))).sort((a,b)=>sort==='recent'?b.rank-a.rank:a.rank-b.rank);

function localize(){
  document.documentElement.lang=lang==='zh'?'zh-CN':'en';
  document.querySelectorAll('[data-copy]').forEach(el=>el.textContent=t(el.dataset.copy));
  document.querySelectorAll('[data-label]').forEach(el=>{el.setAttribute('aria-label',t(el.dataset.label));el.title=t(el.dataset.label)});
  document.querySelectorAll('[data-placeholder]').forEach(el=>{el.placeholder=t(el.dataset.placeholder);el.setAttribute('aria-label',t(el.dataset.placeholder))});
  $('language').textContent=lang==='zh'?'EN':'中文';
  $('theme').innerHTML=icon(document.documentElement.dataset.theme==='light'?'moon':'sun.max')+t(document.documentElement.dataset.theme==='light'?'theme':'light');
  $('scope').innerHTML=`<option value="all">${t('allScopes')}</option><option value="global">${t('global')}</option><option value="Mira">Mira</option>`;
  $('scope').value=scope;
  $('sort').innerHTML=`<option value="recent">${t('recent')}</option><option value="oldest">${t('oldest')}</option>`;
  $('sort').value=sort;
  $('sidebar-toggle').innerHTML=icon('sidebar.left');$('show-sidebar').innerHTML=icon('sidebar.left');
  $('design-notes').innerHTML=`<h2>${t('notesTitle')}</h2><p>${t('notes1')}</p><p>${t('notes2')}</p><p>${t('notes3')}</p><p>${t('notes4')}</p>`;
  render();
}
function render(){
  const rows=available();
  if(!rows.some(m=>m.id===selected))selected=rows[0]?.id??null;
  $('result-count').textContent=t('count',rows.length);
  $('current-tab').setAttribute('aria-selected',String(tab==='current'));
  $('history-tab').setAttribute('aria-selected',String(tab==='history'));
  $('memory-list').innerHTML=rows.length?rows.map(m=>`<div role="listitem"><button class="memory-row ${selected===m.id?'selected':''}" data-memory="${m.id}" aria-label="${esc(m.content||t('forgottenTitle'))}" aria-current="${selected===m.id?'true':'false'}"><span class="row-content">${esc(m.content||t('forgottenTitle'))}</span><span class="row-meta">${icon(scopeIcon(m))}<span>${scopeName(m)}</span><span class="row-dot">·</span><span>${m.status==='forgottenStatus'?t('forgottenStatus'):t(m.kind)}</span>${!m.remote&&m.status!=='forgottenStatus'?`<span class="row-policy">${icon('lock')}${t('localOnly')}</span>`:''}<span class="time">${m.status==='active'?m.date:t(m.status)}</span></span></button></div>`).join(''):emptyState();
  renderDetail();
}
function emptyState(){
  let title,body,action='';
  if(query){title=t('noResults');body=t('noResultsBody');action=`<button class="button secondary" data-action="clear-search">${t('clearSearch')}</button>`}
  else if(tab==='history'){title=t('emptyHistory');body=t('emptyHistoryBody')}
  else{title=t('emptyTitle');body=t('emptyBody');action=`<button class="button secondary" data-action="new">${icon('plus')}${t('addMemory')}</button>`}
  return `<div class="empty-state">${icon(query?'magnifyingglass':'brain')}<h2>${title}</h2><p>${body}</p>${action}</div>`;
}
function renderDetail(){
  const m=currentMemory();
  if(!m||emptyMode){$('memory-detail').innerHTML=`<div class="placeholder-detail">${t('selectMemory')}</div>`;return}
  if(m.status==='forgottenStatus'){$('memory-detail').innerHTML=`<div class="detail-content"><div class="detail-topline"><button class="text-button back-button" data-action="back">${icon('chevron.left')}${t('back')}</button><span class="status-pill">${t('forgottenStatus')}</span></div><h2>${t('forgottenTitle')}</h2><p class="status-note">${t('forgottenBody')}</p><div class="metadata"><div class="meta-row"><span class="meta-label">${t('scope')}</span><span>${scopeName(m)}</span></div><div class="meta-row"><span class="meta-label">${t('forgottenStatus')}</span><span>2026-${m.date} · ${m.time}</span></div></div></div>`;return}
  const changes=m.changes||['saved'];
  const historyNote=m.status==='superseded'?`<div class="status-note">${t('historicalNote')}${memories.some(x=>x.id===m.replacedBy)?` <button class="text-button" data-action="view-current">${t('viewCurrent')}${icon('arrow.up.right')}</button>`:''}</div>`:m.status==='archived'?`<div class="status-note">${t('archivedNote')}</div>`:'';
  $('memory-detail').innerHTML=`<div class="detail-content">
    <div class="detail-topline"><div class="detail-kicker"><button class="text-button back-button" data-action="back">${icon('chevron.left')}${t('back')}</button><span class="status-pill">${t(m.status)}</span><span>2026-${m.date}</span></div><button class="icon-button" data-action="more" aria-label="${t('more')}" aria-expanded="false">${icon('ellipsis')}</button></div>
    <h2>${esc(m.content)}</h2>${historyNote}
    <div class="detail-actions">${m.status==='active'?`<button class="button secondary" data-action="edit">${icon('square.and.pencil')}${t('edit')}</button><button class="text-button" data-action="replace">${t('replace')}${icon('arrow.up.right')}</button>`:m.status==='archived'?`<button class="button secondary" data-action="restore">${t('restore')}</button>`:''}</div>
    <div class="metadata"><div class="meta-row"><span class="meta-label">${t('scope')}</span><span class="meta-value">${icon(scopeIcon(m))}${scopeName(m)}<span style="color:var(--tertiary)">· ${m.scope==='global'?t('globalHelp'):t('projectHelp')}</span></span></div><div class="meta-row"><span class="meta-label">${t('type')}</span><span class="meta-value">${t(m.kind)}</span></div><div class="meta-row"><span class="meta-label">${t('remote')}</span><span class="meta-value" title="${m.remote?t('remoteHelp'):t('localHelp')}">${icon(m.remote?'checkmark':'lock')}${m.remote?t('remoteOn'):t('localOnly')}</span></div></div>
    <section class="detail-section"><h3>${t('source')}</h3>${m.quote?`<div class="source-card"><div class="source-title">${icon('quote.bubble')}<span>${t('sourceMessage')}</span></div><p class="source-quote">“${esc(m.quote)}”</p><div class="source-foot"><span>${esc(m.sourceTitle)}</span><button class="text-button" data-action="source">${t('viewSource')}${icon('arrow.up.right')}</button></div></div>`:`<div class="source-card"><div class="source-title">${icon('square.and.pencil')}${t('manualSource')}</div><p class="form-help">${t('manualSourceHint')}</p></div>`}</section>
    <section class="detail-section"><div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:14px"><h3 style="margin:0">${t('changes')}</h3><button class="text-button" data-action="revisions">${t('viewHistory')}${icon('chevron.right')}</button></div><div class="timeline">${changes.slice(0,2).map((c,i)=>`<div class="timeline-item"><div class="timeline-label">${t(c)}</div><div class="timeline-date">${i===0?`2026-${m.date} · ${m.time}`:'2026-09-12 · 09:40'}${c==='saved'?` · ${t(m.origin)}`:''}</div></div>`).join('')}</div></section>
    <footer class="detail-footer"><span>${t(m.status==='active'?'detailFooter':'historyFooter')}</span><button class="forget-button" data-action="forget">${t('forget')}</button></footer>
  </div>`;
}
function selectMemory(id){selected=Number(id);$('window').classList.add('detail-open');render();$('memory-detail').scrollTop=0}
function setTab(value){tab=value;selected=null;$('window').classList.remove('detail-open');render()}
function toast(message){clearTimeout(toastTimer);$('toast').textContent=message;$('toast').hidden=false;toastTimer=setTimeout(()=>$('toast').hidden=true,3500)}
function closeDialog(){$('modal').close();$('modal').innerHTML=''}
function positionDialog(){const rect=$('window').getBoundingClientRect(),compact=$('window').classList.contains('compact'),scale=rect.width/(compact?850:1240);Object.assign($('modal').style,{margin:'0',left:`${rect.x+rect.width/2}px`,top:`${rect.y+rect.height/2}px`,transform:`translate(-50%,-50%) scale(${scale})`,transformOrigin:'center',maxHeight:`${compact?556:700}px`})}
function showDialog(markup){$('modal').innerHTML=markup;positionDialog();$('modal').showModal();$('modal').querySelector('textarea')?.focus()}
function heading(title){return `<div class="dialog-heading"><h2 id="modal-title">${title}</h2><button class="icon-button" data-action="close" aria-label="${t('close')}">${icon('xmark')}</button></div>`}
function editor(mode){
  const old=currentMemory(),isNew=mode==='new',m=isNew?{content:'',scope:scope==='Mira'?'Mira':'global',kind:'preference',remote:false,sensitive:false}:old;
  if(!m)return;
  const intro=mode==='new'?'newIntro':mode==='replace'?'replaceIntro':'editIntro';
  showDialog(`${heading(t(`${mode==='new'?'new':mode==='replace'?'replace':'edit'}Title`))}<p class="dialog-intro">${t(intro)}</p><form id="memory-form" data-mode="${mode}" data-id="${m.id||''}">${mode==='replace'?`<div class="comparison-label">${t('oldLabel')}</div><div class="comparison-old">${esc(m.content)}</div>`:''}<div class="field"><label for="memory-content">${t(mode==='replace'?'newLabel':'content')}</label><textarea id="memory-content" required maxlength="2000">${mode==='replace'?'':esc(m.content)}</textarea><div class="form-error" id="form-error" hidden></div></div><div class="form-grid"><div class="field"><label for="memory-kind">${t('type')}</label><select id="memory-kind">${['preference','fact','decision','goal','constraint','procedure','learning','context'].map(k=>`<option value="${k}" ${k===m.kind?'selected':''}>${t(k)}</option>`).join('')}</select></div><div class="field"><label for="memory-scope">${t('scope')}</label><select id="memory-scope" ${!isNew?'disabled':''}><option value="global" ${m.scope==='global'?'selected':''}>${t('global')}</option><option value="Mira" ${m.scope==='Mira'?'selected':''}>Mira</option></select></div></div>${!isNew?`<p class="form-help">${t('fixedScope')}</p>`:''}<div style="margin-top:20px"><label class="toggle-row"><span>${t('sensitive')}<small>${t('sensitiveHelp')}</small></span><input id="memory-sensitive" type="checkbox" ${m.sensitive?'checked':''}></label><label class="toggle-row"><span>${t('remoteToggle')}<small>${t('remoteToggleHelp')}</small></span><input id="memory-remote" type="checkbox" ${m.remote?'checked':''}></label></div><div class="dialog-actions"><button class="button secondary" type="button" data-action="close">${t('cancel')}</button><button class="button primary" type="submit">${t(mode==='new'?'create':mode==='replace'?'confirmReplace':'save')}</button></div></form>`);
  $('memory-sensitive').addEventListener('change',event=>{if(event.target.checked)$('memory-remote').checked=false});
  $('memory-form').addEventListener('submit',event=>{
    event.preventDefault();const content=$('memory-content').value.trim();if(!content){$('form-error').textContent=t('contentRequired');$('form-error').hidden=false;return}
    const fields={content,kind:$('memory-kind').value,scope:$('memory-scope').value,sensitive:$('memory-sensitive').checked,remote:$('memory-remote').checked,date:'09-20',time:'11:00',rank:100+nextId};
    if(mode==='edit'){m.revisions=m.revisions||[{content:m.content,date:`2026-${m.date}`,label:'originalText'}];m.revisions.forEach(r=>{if(r.label==='currentText')r.label='revised'});m.revisions.unshift({content,date:'2026-09-20',label:'currentText'});Object.assign(m,fields);m.changes=['revised',...(m.changes||['saved'])];toast(t('updated'))}
    else{const created={...fields,id:nextId++,origin:'manual',status:'active',sourceTitle:'',quote:'',changes:['saved']};if(mode==='replace'){m.status='superseded';m.replacedBy=created.id;created.replaces=m.id;created.changes=['replaced','saved'];toast(t('replacedToast'))}else toast(t('created'));memories.unshift(created);selected=created.id;tab='current';query='';$('search').value='';emptyMode=false;$('empty').setAttribute('aria-pressed','false')}
    closeDialog();render();$('window').classList.add('detail-open');
  });
}
function forget(){
  const m=currentMemory();if(!m)return;
  showDialog(`${heading(t('forgetTitle'))}<div class="forget-excerpt">${esc(m.content)}</div><p class="dialog-intro">${t('forgetIntro')}</p><ul class="impact-list"><li>${t('forgetPreserve')}</li><li>${t('forgetIrreversible')}</li></ul><div class="dialog-actions"><button class="button secondary" data-action="close">${t('cancel')}</button><button class="button danger" id="confirm-forget">${t('confirmForget')}</button></div>`);
  $('confirm-forget').addEventListener('click',()=>{memories=memories.map(x=>x.id===m.id?{id:m.id,scope:m.scope,content:'',status:'forgottenStatus',date:'09-20',time:'11:00',rank:200+nextId++}:x);selected=null;closeDialog();render();$('window').classList.remove('detail-open');toast(t('forgotten'))});
}
function sourceDialog(){const m=currentMemory();if(!m)return;showDialog(`${heading(t('sourceTitle'))}<div class="source-dialog"><p class="dialog-intro">${esc(m.sourceTitle)}</p><div class="dialog-meta">${t('sourceContext')} · 2026-${m.sourceDate||m.date} ${m.sourceTime||m.time}</div><p class="source-quote">${esc(m.quote)}</p><p class="form-help">${t('sourcePreview')}</p></div><div class="dialog-actions"><button class="button secondary" data-action="close">${t('close')}</button></div>`)}
function revisions(){const m=currentMemory();if(!m)return;const old=memories.find(x=>x.id===m.replaces&&x.status!=='forgottenStatus');showDialog(`${heading(t('revisionTitle'))}<p class="dialog-intro">${t('revisionIntro')}</p>${(m.revisions||[{content:m.content,date:`2026-${m.date}`,label:'currentText'}]).map(r=>`<div class="revision-entry"><div class="dialog-meta">${t(r.label)} · ${r.date}</div><p>${esc(r.content)}</p></div>`).join('')}${old?`<div class="revision-entry"><div class="dialog-meta">${t('superseded')} · 2026-09-12</div><p>${esc(old.content)}</p></div>`:''}<div class="dialog-actions"><button class="button secondary" data-action="close">${t('close')}</button></div>`)}
function more(){
  const existing=document.querySelector('.more-menu');if(existing){existing.remove();return}const m=currentMemory();
  const menu=document.createElement('div');menu.className='more-menu';menu.setAttribute('role','menu');menu.innerHTML=`${m.status==='active'?`<button role="menuitem" data-action="archive">${icon('archivebox')}${t('archive')}</button>`:''}<button role="menuitem" data-action="revisions">${icon('clock')}${t('viewHistory')}</button><div class="menu-divider"></div><button role="menuitem" class="danger-text" data-action="forget">${icon('trash')}${t('forget')}</button>`;$('memory-detail').append(menu);$('memory-detail').querySelector('[data-action="more"]').setAttribute('aria-expanded','true');menu.querySelector('button').focus();
}
function action(name){
  if(name!=='more')document.querySelector('.more-menu')?.remove();
  if(name==='new'||name==='edit'||name==='replace')return editor(name);
  if(name==='forget')return forget();if(name==='source')return sourceDialog();if(name==='revisions')return revisions();if(name==='close')return closeDialog();if(name==='more')return more();
  if(name==='back'){$('window').classList.remove('detail-open');return}
  if(name==='clear-search'){query='';$('search').value='';render();return}
  if(name==='view-current'){const m=currentMemory();tab='current';scope='all';query='';$('search').value='';$('scope').value='all';selectMemory(m.replacedBy);return}
  if(name==='archive'||name==='restore'){const m=currentMemory();m.status=name==='archive'?'archived':'active';toast(t(name==='archive'?'archivedToast':'restoredToast'));selected=null;render()}
}
document.addEventListener('click',event=>{
  const row=event.target.closest('[data-memory]');if(row)return selectMemory(row.dataset.memory);
  const control=event.target.closest('[data-action]');if(control)return action(control.dataset.action);
  if(!event.target.closest('.more-menu'))document.querySelector('.more-menu')?.remove();
});
$('search').addEventListener('input',event=>{query=event.target.value;render()});
$('scope').addEventListener('change',event=>{scope=event.target.value;selected=null;$('window').classList.remove('detail-open');render()});
$('sort').addEventListener('change',event=>{sort=event.target.value;render()});
$('current-tab').addEventListener('click',()=>setTab('current'));$('history-tab').addEventListener('click',()=>setTab('history'));
$('add-memory').addEventListener('click',()=>editor('new'));
$('memories-nav').addEventListener('click',()=>{scope='all';$('scope').value='all';setTab('current')});
document.querySelectorAll('.scope-nav').forEach(el=>el.addEventListener('click',()=>{scope=el.dataset.scope;$('scope').value=scope;setTab('current')}));
$('theme').addEventListener('click',()=>{document.documentElement.dataset.theme=document.documentElement.dataset.theme==='light'?'dark':'light';localize()});
$('language').addEventListener('click',()=>{lang=lang==='zh'?'en':'zh';localize()});
$('size').addEventListener('click',()=>{$('window').classList.toggle('compact');$('window').classList.remove('detail-open');$('size').setAttribute('aria-pressed',String($('window').classList.contains('compact')));fitPreview()});
$('empty').addEventListener('click',()=>{emptyMode=!emptyMode;$('empty').setAttribute('aria-pressed',String(emptyMode));query='';$('search').value='';$('window').classList.remove('detail-open');render()});
$('reset').addEventListener('click',()=>{memories=structuredClone(initialMemories);selected=1;scope='all';tab='current';query='';sort='recent';emptyMode=false;nextId=10;$('search').value='';$('empty').setAttribute('aria-pressed','false');$('window').classList.remove('detail-open');$('toast').hidden=true;localize()});
$('notes').addEventListener('click',()=>{$('design-notes').hidden=!$('design-notes').hidden;$('notes').setAttribute('aria-expanded',String(!$('design-notes').hidden))});
['sidebar-toggle','show-sidebar'].forEach(id=>$(id).addEventListener('click',()=>{$('window').classList.toggle('sidebar-hidden')}));
$('modal').addEventListener('click',event=>{if(event.target===$('modal')){const rect=$('modal').getBoundingClientRect();if(event.clientX<rect.left||event.clientX>rect.right||event.clientY<rect.top||event.clientY>rect.bottom)closeDialog()}});
document.addEventListener('keydown',event=>{
  if(event.key==='Escape'){document.querySelector('.more-menu')?.remove();$('design-notes').hidden=true;$('notes').setAttribute('aria-expanded','false')}
  if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='f'&&!$('modal').open){event.preventDefault();$('search').focus()}
  if(['ArrowUp','ArrowDown'].includes(event.key)&&event.target.closest('.memory-row')){event.preventDefault();const rows=available();const index=rows.findIndex(m=>m.id===selected);selected=rows[Math.max(0,Math.min(rows.length-1,index+(event.key==='ArrowDown'?1:-1)))].id;render();document.querySelector(`[data-memory="${selected}"]`).focus()}
});
function fitPreview(){
  const compact=$('window').classList.contains('compact'),width=compact?850:1240,height=compact?620:780;
  const stage=document.querySelector('.stage'),availableWidth=stage.clientWidth-(window.innerWidth<=1000?24:48),scale=Math.min(1,availableWidth/width);
  $('window').style.transform=`scale(${scale})`;
  $('frame-slot').style.width=`${width*scale}px`;$('frame-slot').style.height=`${height*scale}px`;if($('modal').open)positionDialog();
}
window.addEventListener('resize',fitPreview);
localize();fitPreview();
