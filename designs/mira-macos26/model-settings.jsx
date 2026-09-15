/* Settings use synthetic credentials and connectivity; nothing is transmitted. */
function initialModelSettings() {
  return {
    providers: SUPPORTED_PROVIDERS.map(({ models, ...p }) => ({ ...p, key: ["openai", "anthropic"].includes(p.id), active: ["openai", "anthropic"].includes(p.id) })),
    models: MODEL_POOL.map(m => ({ ...m, providerId: m.provider === "Anthropic" ? "anthropic" : "openai",
      modelId: { sonnet5: "claude-sonnet-5", opus48: "claude-opus-4-8", gpt56: "gpt-5.6", haiku45: "claude-haiku-4-5" }[m.id],
      context: m.ctx === "200k" ? 200000 : 128000, output: 8192, text: true, tools: true,
      vision: true, extraction: m.id !== "opus48", thinking: m.caps.includes("思考"), effort: "high", stale: false })),
    defaults: { chat: "sonnet5", memory: "", title: "haiku45" },
  };
}
function isLocalEndpoint(endpoint) {
  try { return ["localhost", "127.0.0.1", "[::1]"].includes(new URL(endpoint).hostname); } catch { return false; }
}
function providerReady(p) { return !!p && p.active && (p.key || (p.auth === "none" && isLocalEndpoint(p.endpoint))); }
function modelReady(m, config, purpose = "chat") {
  return !!m && m.on && !m.stale && m.text && m.context > 0 && m.output > 0 && m.output <= m.context
    && providerReady(config.providers.find(p => p.id === m.providerId))
    && (purpose !== "memory" || m.extraction) && (purpose !== "tools" || m.tools);
}
function modelAvailability(m, config) {
  if (!config.providers.find(p => p.id === m.providerId)?.active) return "服务商未激活";
  if (!providerReady(config.providers.find(p => p.id === m.providerId))) return "服务商未配置凭据";
  if (!m.on) return "模型未激活";
  if (m.stale) return "配置变更，待确认";
  if (!m.text || !m.context || !m.output || m.output > m.context) return "配置待完善";
  return "可用";
}
function SettingToggle({ label, on, onChange, disabled = false }) {
  return <button type="button" className={"switch" + (on ? " on" : "")} role="switch" aria-label={label}
    aria-checked={on} disabled={disabled} onClick={() => onChange(!on)} />;
}
function ProviderLogo({ provider, large = false }) {
  return <span className={"provider-logo" + (large ? " large" : "")} aria-hidden="true">
    {provider.icon ? <span className="provider-mark" style={{ "--provider-mark": `url("assets/provider-icons/${provider.icon}.svg")` }} />
      : provider.id === "local" ? <I.cloud size={large ? "var(--icon-display)" : "var(--icon-lg)"} /> : <I.gear size={large ? "var(--icon-display)" : "var(--icon-lg)"} />}
  </span>;
}
function SettingsEmpty({ title, detail, action, onAction }) {
  return <div className="config-empty"><I.search size="var(--icon-display)" /><b>{title}</b><p>{detail}</p>
    {action && <button className="btn" onClick={onAction}>{action}</button>}</div>;
}
function ProviderSettings({ config, onSelect }) {
  const [query, setQuery] = React.useState("");
  const list = config.providers.filter(p => (p.name + p.endpoint).toLowerCase().includes(query.toLowerCase()));
  return <>
    <div className="config-intro"><h2>服务商</h2><p>选择服务商，激活后添加你要使用的模型。</p></div>
    <label className="config-search provider-search"><I.search size="var(--icon-md)" />
      <input aria-label="搜索服务商" placeholder="搜索服务商" value={query} onChange={e => setQuery(e.target.value)} /></label>
    <div className="panel provider-directory">
      {list.map(p => <button className="provider-directory-row" key={p.id} aria-label={"打开服务商 " + p.name} onClick={() => onSelect(p.id)}>
        <ProviderLogo provider={p} /><span className="provider-directory-name">{p.name}</span>
        <span className={"activation-label" + (p.active ? " active" : "")}>{p.active ? "已激活" : "未激活"}</span><I.chevRight size="var(--icon-sm)" />
      </button>)}
      {!list.length && <SettingsEmpty title="没有匹配的服务商" detail="试试其他名称，或选择自定义服务商。" />}
    </div>
  </>;
}
function ProviderEditor({ provider, config, onChange }) {
  const [draft, setDraft] = React.useState(provider);
  const [secret, setSecret] = React.useState("");
  const [error, setError] = React.useState("");
  const [notice, setNotice] = React.useState("");
  const [busy, setBusy] = React.useState("");
  const [credentialsOpen, setCredentialsOpen] = React.useState(!provider.active);
  const [advanced, setAdvanced] = React.useState(provider.id === "custom" || provider.id === "local");
  const [search, setSearch] = React.useState("");
  const [shown, setShown] = React.useState(20);
  const timer = React.useRef(null);
  React.useEffect(() => () => clearTimeout(timer.current), []);
  const dirty = ["endpoint", "protocol", "auth", "key"].some(k => draft[k] !== provider[k]) || !!secret;
  const patch = value => { clearTimeout(timer.current); setBusy(""); setDraft(d => ({ ...d, ...value })); setError(""); setNotice(""); };
  const validate = () => {
    try {
      const u = new URL(draft.endpoint);
      if (u.username || u.password || u.search || u.hash) return "API 地址不能包含凭据、查询参数或片段。";
      if (u.protocol !== "https:" && !(u.protocol === "http:" && isLocalEndpoint(draft.endpoint))) return "使用 HTTPS，或本机的 HTTP 地址。";
    } catch { return "请输入完整的 API 地址。"; }
    if (draft.auth === "none" && !isLocalEndpoint(draft.endpoint)) return "免密钥连接仅适用于本机端点。";
    if (draft.auth === "key" && !draft.key && !secret.trim()) return "请先填写 API Key。";
    return "";
  };
  const activate = () => {
    const problem = validate(); if (problem) { setError(problem); setCredentialsOpen(true); return; }
    const value = { ...draft, endpoint: draft.endpoint.trim().replace(/\/$/, ""), active: true, key: draft.auth === "key" && (draft.key || !!secret.trim()) };
    const changed = provider.active && (provider.endpoint !== value.endpoint || provider.protocol !== value.protocol || provider.auth !== value.auth || !!secret);
    onChange(c => ({ ...c, providers: c.providers.map(p => p.id === value.id ? value : p),
      models: changed ? c.models.map(m => m.providerId === value.id ? { ...m, stale: true } : m) : c.models }));
    setDraft(value); setSecret(""); setCredentialsOpen(false); setError("");
    setNotice(changed ? "连接已更新；已激活模型的配置需要重新确认。" : "服务商已激活，开启下方模型即可加入模型池。");
  };
  const simulate = () => {
    const problem = validate(); if (problem) { setError(problem); setCredentialsOpen(true); return; }
    setError(""); setNotice(""); setBusy("test");
    timer.current = setTimeout(() => { setBusy(""); setNotice("连接正常 · 模拟测试结果"); }, 650);
  };
  const template = SUPPORTED_PROVIDERS.find(p => p.id === provider.id);
  const ownModels = config.models.filter(m => m.providerId === provider.id);
  const models = [...template.models.map(m => ownModels.find(x => x.modelId === m.modelId) || m),
    ...ownModels.filter(m => !template.models.some(x => x.modelId === m.modelId))];
  const filtered = models.filter(m => (m.name + m.modelId).toLowerCase().includes(search.toLowerCase()));
  const toggleModel = (m, on) => onChange(c => ({ ...c, models: c.models.some(x => x.id === m.id)
    ? c.models.map(x => x.id === m.id ? { ...x, on } : x) : [...c.models, { ...m, on }] }));
  const toggleProvider = on => {
    if (on) { activate(); return; }
    clearTimeout(timer.current); setBusy("");
    onChange(c => ({ ...c, providers: c.providers.map(p => p.id === provider.id ? { ...p, active: false } : p) }));
    setDraft(d => ({ ...d, active: false })); setCredentialsOpen(true); setNotice(""); setError("");
  };
  return <>
    <div className="provider-detail-hero"><ProviderLogo provider={provider} large /><div><h2>{provider.name}</h2>
      <p>{provider.id === "local" ? "连接本机运行的模型" : provider.id === "custom" ? "连接兼容的模型服务" : new URL(provider.endpoint).hostname}</p></div>
      <span className="provider-activation"><span className={"activation-label" + (provider.active ? " active" : "")}>{provider.active ? "已激活" : "未激活"}</span>
        <SettingToggle label={"激活服务商 " + provider.name} on={provider.active} disabled={!!busy} onChange={toggleProvider} /></span></div>
    <div className="panel credentials-card">
      <button className="credentials-heading" aria-expanded={credentialsOpen} onClick={() => setCredentialsOpen(!credentialsOpen)}>
        <I.key size="var(--icon-md)" /><span>连接设置</span><span className="credential-summary">{provider.active ? provider.auth === "none" ? "本机免密钥" : "已配置 API Key" : "等待激活"}</span>
        <span className={"credential-caret" + (credentialsOpen ? " open" : "")}><I.chevRight size="var(--icon-sm)" /></span></button>
      {credentialsOpen && <div className="config-form credentials-body">
        {["local","custom"].includes(provider.id) && <label>认证方式<select className="select" value={draft.auth} onChange={e => patch({auth:e.target.value})}>
          <option value="key">API Key</option><option value="none">无需密钥 · 仅本机</option></select></label>}
        {draft.auth === "key" && <label>API Key<input className="input" type="password" aria-label="API Key" autoComplete="off" value={secret}
          placeholder={draft.key ? "已配置 · 输入以替换" : "输入示例密钥"} onChange={e => { clearTimeout(timer.current); setBusy(""); setSecret(e.target.value); setNotice(""); setError(""); }} /></label>}
        <button className="text-action" aria-expanded={advanced} onClick={() => setAdvanced(!advanced)}>API 地址与协议<I.chevDown size="var(--icon-sm)" /></button>
        {advanced && <div className="advanced-connection"><label>API 地址<input className="input" value={draft.endpoint} placeholder="https://api.example.com/v1" onChange={e => patch({endpoint:e.target.value})} /></label>
          <label>接口协议<select className="select" value={draft.protocol} onChange={e => patch({protocol:e.target.value})}><option value="openai">OpenAI 兼容 · Chat Completions</option><option value="anthropic">Anthropic · Messages</option></select></label></div>}
        <div className="config-actions"><button className="btn" disabled={!!busy} onClick={simulate}>{busy ? "测试中…" : "测试连通性"}</button><span className="grow" />
          <button className="btn primary" disabled={!!busy || (provider.active && !dirty)} onClick={activate}>{provider.active ? "保存更改" : "激活服务商"}</button></div>
      </div>}
    </div>
    {error && <p className="config-feedback error" role="alert">{error}</p>}
    {notice && <p className="config-feedback" role="status">{notice}</p>}
    {providerReady(provider) ? <>
      <div className="config-section provider-model-heading"><h3>支持的模型 <span className="model-provider">{models.length}</span></h3><span className="model-provider">已激活 {ownModels.filter(m => m.on).length} 个</span></div>
      <label className="config-search"><I.search size="var(--icon-md)" /><input aria-label="搜索服务商模型" placeholder="搜索名称或 Model ID" value={search} onChange={e => { setSearch(e.target.value); setShown(20); }} /></label>
      <div className="panel config-panel model-source-list">{filtered.slice(0,shown).map(m => <div className="model-source-row" key={m.id}>
        <div className="connection-copy"><b>{m.modelId}</b><small>{[m.tools && "工具", m.thinking && "思考", m.vision && "识图"].filter(Boolean).join(" · ") || "文本"}</small></div>
        <SettingToggle label={"激活模型 " + m.name} on={m.on} onChange={on => toggleModel(m,on)} /></div>)}
        {!filtered.length && <SettingsEmpty title={search ? "没有匹配的模型" : "尚无模型"} detail={search ? "试试其他名称或 Model ID。" : "此服务商暂无可用的模型。"} />}
        {filtered.length > shown && <button className="load-models text-action" onClick={() => setShown(n => n + 20)}>显示更多模型 · 剩余 {filtered.length - shown}</button>}
      </div>

    </> : <p className="activation-hint"><I.shield size="var(--icon-md)" />激活后将显示支持的模型，开启模型即可加入模型池。</p>}
  </>;
}
function ModelSettings({ config, onChange, onProviders, onEdit, tab = "defaults", onTabChange }) {
  const [query, setQuery] = React.useState("");
  const [filter, setFilter] = React.useState("all");
  React.useLayoutEffect(() => { document.querySelector(".settings-scroll")?.scrollTo(0, 0); }, [tab]);
  const pool = config.models.filter(m => m.on && config.providers.find(p => p.id === m.providerId)?.active);
  const list = pool.filter(m => (m.name + m.modelId + config.providers.find(p => p.id === m.providerId)?.name).toLowerCase().includes(query.toLowerCase()))
    .filter(m => filter === "all" || modelReady(m, config, filter));
  return <>
    <div className="config-intro"><h2>为每件事选择合适的模型</h2><p>管理模型与参数，设置不同用途的默认选择。</p></div>
    <Seg value={tab} onChange={onTabChange} options={[{value:"defaults",label:"用途默认"}, {value:"pool",label:"模型池",count:pool.length}]} />
    {tab === "pool" ? <>
      <div className="config-actions pool-tools"><label className="config-search"><I.search size="var(--icon-md)" /><input aria-label="搜索模型" placeholder="搜索模型或服务商" value={query} onChange={e => setQuery(e.target.value)} /></label>
        <select className="select" aria-label="模型能力筛选" value={filter} onChange={e => setFilter(e.target.value)}><option value="all">全部模型</option><option value="chat">可用于对话</option><option value="tools">可调用工具</option><option value="memory">可提取记忆</option></select></div>
      <div className="panel config-panel">{list.map(m => <div className="pool-row" key={m.id}>
        <button className="pool-main" aria-label={"配置模型 " + m.name} onClick={() => onEdit(m.id)}>
          <span className="pool-name">{m.name}<span className="model-provider">{config.providers.find(p => p.id === m.providerId)?.name}</span></span>
          <span className="model-meta">{m.context ? (m.context / 1000) + "k 上下文" : "上下文待设置"}<span>·</span>{modelAvailability(m, config)}</span>
          <span className="capabilities">{m.tools && <span>工具</span>}{m.thinking && <span>思考</span>}{m.extraction && <span>记忆提取</span>}</span>
        </button>
        <IconBtn icon={I.chevRight} title={"编辑模型 " + m.name} size="var(--icon-md)" onClick={() => onEdit(m.id)} />
      </div>)}{!list.length && <SettingsEmpty title="没有匹配的模型" detail="调整筛选条件，或到服务商中添加模型。" />}</div>
      <button className="text-action" onClick={onProviders}><I.plus size="var(--icon-sm)" />前往服务商激活模型</button>
    </> : <>
      <div className="panel purpose-panel">{[{id:"chat",label:"对话",desc:"新对话使用的默认模型"}, {id:"memory",label:"记忆提取",desc:"需支持 JSON 提取；仍需单独开启自动捕获"}, {id:"title",label:"对话标题",desc:"为新对话生成简洁标题"}].map(p => {
        const selected = config.models.find(m => m.id === config.defaults[p.id]);
        const ready = modelReady(selected, config, p.id);
        return <div className="purpose-row" key={p.id}><div><b>{p.label}</b><p>{p.desc}</p></div>
          <select className="select" aria-label={p.label + "默认模型"} value={config.defaults[p.id]} onChange={e => onChange(c => ({ ...c, defaults:{...c.defaults,[p.id]:e.target.value} }))}>
            <option value="">未设置</option>{selected && !ready && <option value={selected.id} disabled>{selected.name} · 不可用</option>}
            {config.models.filter(m => modelReady(m, config, p.id)).map(m => <option value={m.id} key={m.id}>{m.name} · {config.providers.find(v => v.id === m.providerId)?.name}</option>)}</select>
          {selected && !ready && <span className="purpose-warning">{modelAvailability(selected, config) === "可用" ? "不支持此用途" : modelAvailability(selected, config)}，请选择可用模型。</span>}
        </div>;
      })}</div>
      <p className="config-note"><I.info size="var(--icon-md)" />默认选择只影响后续执行。模型不可用时会提示你重新选择。</p>
    </>}
  </>;
}
function ModelEditor({ model, config, onChange }) {
  const [editing, setEditing] = React.useState(false);
  const [draft, setDraft] = React.useState(model);
  const [error, setError] = React.useState("");
  const [confirmed, setConfirmed] = React.useState(!model.stale);
  const patch = value => { setDraft(d => ({ ...d, ...value })); setError(""); };
  const provider = config.providers.find(p => p.id === draft.providerId);
  const save = () => {
    if (!draft.name.trim() || !draft.modelId.trim()) { setError("请填写显示名称和 Model ID。"); return; }
    if (config.models.some(m => m.id !== draft.id && m.providerId === draft.providerId && m.modelId === draft.modelId.trim())) { setError("此服务商已存在相同的 Model ID。"); return; }
    if (!Number.isInteger(+draft.context) || +draft.context <= 0 || !Number.isInteger(+draft.output) || +draft.output <= 0 || +draft.output > +draft.context) { setError("请填写有效的 Token 上限，最大输出不能超过上下文窗口。"); return; }
    if (draft.stale && !confirmed) { setError("请确认更新后的连接仍支持这些模型配置。"); return; }
    onChange(c => ({ ...c, models: c.models.map(m => m.id === draft.id ? {...draft, name:draft.name.trim(), modelId:draft.modelId.trim(), context:+draft.context, output:+draft.output, ctx:(+draft.context / 1000) + "k", on:m.on, stale:false} : m) })); setEditing(false);
  };
  return <>
    <div className="config-intro"><h2>{model.name}</h2><p className="model-detail-subtitle"><span className={"activation-label" + (model.on && provider?.active ? " active" : "")}>{model.on && provider?.active ? "已激活" : "未激活"}</span><span>· {provider?.name} · 模型配置</span></p></div>
    <div className="config-section model-edit-heading"><h3>模型信息</h3><button className={"btn tiny" + (editing ? " primary" : "")} onClick={editing ? save : () => { setDraft(model); setError(""); setConfirmed(!model.stale); setEditing(true); }}>{editing ? "保存" : "编辑"}</button></div>
    <div className={"panel config-form model-info" + (editing ? " editing" : " viewing")}>
    {editing ? <><label>显示名称<input className="input" value={draft.name} onChange={e => patch({name:e.target.value})} /></label>
      <label>Model ID<input className="input" value={draft.modelId} onChange={e => patch({modelId:e.target.value})} /></label>
      <div className="config-two"><label>上下文窗口 · Tokens<input className="input" type="number" min="1" value={draft.context || ""} onChange={e => patch({context:e.target.value})} /></label>
        <label>最大输出 · Tokens<input className="input" type="number" min="1" value={draft.output || ""} onChange={e => patch({output:e.target.value})} /></label></div>
    </> : <dl className="model-info-values"><div><dt>显示名称</dt><dd>{model.name}</dd></div><div><dt>Model ID</dt><dd>{model.modelId}</dd></div><div className="config-two"><div><dt>上下文窗口 · Tokens</dt><dd>{model.context.toLocaleString()}</dd></div><div><dt>最大输出 · Tokens</dt><dd>{model.output.toLocaleString()}</dd></div></div></dl>}
    </div>
    {error && <p className="config-feedback error" role="alert">{error}</p>}
    <div className="panel model-pool-toggle"><FieldRow title="加入模型池" desc={provider?.active ? "加入后，可在符合条件的用途中选择" : "服务商已停用，启用后才可使用"}><SettingToggle label="加入模型池" on={model.on} onChange={on => onChange(c => ({...c, models:c.models.map(m => m.id === model.id ? {...m,on} : m)}))} /></FieldRow></div>
    <div className="config-section"><h3>能力与思考</h3><span className="model-provider">手动声明</span></div>
    <div className="panel">{[{key:"text",label:"流式文本",desc:"用于普通对话"},{key:"tools",label:"工具调用",desc:"允许 Agent 使用工具"},{key:"vision",label:"识图",desc:"理解图片内容"},{key:"extraction",label:"JSON 提取",desc:"用于结构化记忆提取"},{key:"thinking",label:"思考",desc:"按服务商支持情况配置"}].map(c => <FieldRow key={c.key} title={c.label} desc={c.desc}>
      {editing ? <SettingToggle label={c.label} on={draft[c.key]} onChange={v => patch({[c.key]:v})} /> : <span className="model-capability-value">{model[c.key] ? "支持" : "不支持"}</span>}</FieldRow>)}
      {draft.thinking && <FieldRow title="思考强度">{editing ? <select className="select" aria-label="思考强度" value={draft.effort} onChange={e => patch({effort:e.target.value})}><option value="default">服务商默认</option><option value="low">低</option><option value="medium">中</option><option value="high">高</option></select> : <span className="model-capability-value">{{default:"服务商默认",low:"低",medium:"中",high:"高"}[model.effort]}</span>}</FieldRow>}
    </div>
    {editing && model.stale && <label className="confirm-capabilities"><input type="checkbox" checked={confirmed} onChange={e => setConfirmed(e.target.checked)} />我已确认新连接支持以上参数与能力</label>}

  </>;
}
Object.assign(window, { initialModelSettings, modelReady, ProviderSettings, ProviderEditor, ModelSettings, ModelEditor });
