/* Inspector (3rd pane), Settings sheet, command palette, model popover, toast. */
const { useState: sU, useEffect: sE, useRef: sR } = React;

/* ===================== INSPECTOR (third pane) ===================== */
function Inspector({ kind, item, onClose, onAction, onToggleRemote }) {
  let title = "详情";
  if (kind === "chat") title = "上下文与执行";
  else if (kind === "memory") title = "记忆详情";
  else if (kind === "knowledge") title = "来源详情";
  else if (kind === "task") title = "任务详情";

  return (
    <aside className="inspector" aria-label={title}>
      <div className="insp-head">
        <span className="h">{title}</span>
        <div className="grow" />
        <IconBtn icon={I.x} title="关闭" size={16} onClick={onClose} />
      </div>
      <div className="insp-scroll scroll">
        {kind === "chat" && <ChatInspector m={item} />}
        {kind === "memory" && <MemoryInspector m={item} onAction={onAction} />}
        {kind === "knowledge" && <KnowledgeInspector k={item} onToggleRemote={onToggleRemote} />}
        {kind === "task" && <TaskInspector t={item} />}
      </div>
    </aside>
  );
}

function ChatInspector({ m }) {
  const c = m.context;
  return (
    <>
      <div className="insp-sec">
        <div className="lbl">冻结的上下文来源</div>
        {c.sources.map((s, i) => (
          <div className="src-item" key={i}>
            {s.kind === "knowledge" ? <I.doc size={14} className="k" /> :
             s.kind === "memory" ? <I.memory size={14} className="k" /> : <I.chat size={14} className="k" />}
            <span>{s.label}</span>
          </div>
        ))}
      </div>
      <div className="insp-sec">
        <div className="lbl">Token 预算</div>
        <div className="kv"><span className="k">已用 / 上限</span><span className="v mono">{c.tokens}</span></div>
        <div className="meter"><i style={{ width: "10%" }} /></div>
      </div>
      <div className="insp-sec">
        <div className="lbl">执行</div>
        <div className="kv"><span className="k">模型</span><span className="v">{c.model}</span></div>
        <div className="kv"><span className="k">路由</span><span className="v">对话默认</span></div>
        <div className="kv"><span className="k">首字延迟</span><span className="v mono">0.82s</span></div>
        <div className="kv"><span className="k">总耗时</span><span className="v mono">4.13s</span></div>
        <div className="kv"><span className="k">工具调用</span><span className="v">{m.tools.length} 次</span></div>
        <div className="kv"><span className="k">估算成本</span><span className="v mono">$0.021</span></div>
      </div>
      <div className="insp-sec">
        <div className="lbl">工具时间线</div>
        {m.tools.map((t, i) => (
          <div className="src-item" key={i}>
            <I.wrench size={13} className="k" />
            <span style={{ fontFamily: "var(--font-mono)", fontSize: 11.5 }}>{t.name}</span>
            <span className="grow" /><I.check size={14} style={{ color: "var(--tint-green)" }} />
          </div>
        ))}
      </div>
    </>
  );
}

function MemoryInspector({ m, onAction }) {
  return (
    <>
      <div className="insp-sec">
        <div className="hstack" style={{ marginBottom: 8 }}>
          <span className="tag">{m.kind}</span>
          <span className={"tag " + m.status}>{statusLabel(m.status)}</span>
        </div>
        <div style={{ fontSize: 14.5, fontWeight: 600, color: "var(--ink)", marginBottom: 8 }}>{m.title}</div>
        <div className="cjk" style={{ fontSize: 13, color: "var(--text-2)", lineHeight: 1.7 }}>{m.body}</div>
      </div>
      <div className="insp-sec">
        <div className="lbl">来源证据</div>
        <div className="evidence cjk">“{m.evidence}”</div>
        <div className="src-item" style={{ marginTop: 6 }}><I.chat size={14} className="k" /><span>{m.origin}</span></div>
      </div>
      <div className="insp-sec">
        <div className="kv"><span className="k">范围</span><span className="v">{m.scope}</span></div>
        <div className="kv"><span className="k">更新</span><span className="v">{m.updated}</span></div>
        <div className="kv"><span className="k">修订次数</span><span className="v">{m.revisions}</span></div>
        <div className="field-row" style={{ borderBottom: "none", padding: "10px 0 0" }}>
          <div className="fl"><div className="t">允许模型使用</div><div className="d">关闭时该记忆仅保存在本机</div></div>
          <Switch on={m.allowRemote} onChange={() => onAction("remote", m)} />
        </div>
      </div>
      <div className="insp-sec hstack">
        {m.status === "candidate" && <>
          <button className="btn primary" style={{ flex: 1 }} onClick={() => onAction("approve", m)}><I.check size={14} />确认记住</button>
          <button className="btn ghost" onClick={() => onAction("ignore", m)}>忽略</button>
        </>}
        {m.status === "active" && <>
          <button className="btn" style={{ flex: 1 }} onClick={() => onAction("edit", m)}><I.pencil size={14} />编辑</button>
          <button className="btn ghost" onClick={() => onAction("archive", m)}><I.archive size={14} />归档</button>
        </>}
        {m.status === "archived" &&
          <button className="btn" style={{ flex: 1 }} onClick={() => onAction("restore", m)}><I.restore size={14} />恢复</button>}
      </div>
    </>
  );
}

function KnowledgeInspector({ k, onToggleRemote }) {
  return (
    <>
      <div className="insp-sec">
        <div className="hstack" style={{ marginBottom: 8 }}>
          <span className="avatar" style={{ width: 26, height: 26 }}><I.doc size={15} /></span>
          <div><div style={{ fontSize: 14, fontWeight: 600, color: "var(--ink)" }}>{k.title}</div>
            <div style={{ fontSize: 11.5, color: "var(--text-3)" }}>{k.kind}</div></div>
        </div>
      </div>
      <div className="insp-sec">
        <div className="kv"><span className="k">当前版本</span><span className="v">v{k.versions}（不可变）</span></div>
        <div className="kv"><span className="k">片段</span><span className="v">{k.chunks} 个</span></div>
        <div className="kv"><span className="k">大小</span><span className="v mono">{k.size}</span></div>
        <div className="kv"><span className="k">更新</span><span className="v">{k.updated}</span></div>
        <div className="field-row" style={{ borderBottom: "none", padding: "10px 0 0" }}>
          <div className="fl"><div className="t">允许模型使用</div><div className="d">开启后其片段可供所配置的服务商检索</div></div>
          <Switch on={k.allowRemote} onChange={() => onToggleRemote(k)} />
        </div>
      </div>
      <div className="insp-sec">
        <div className="lbl">来源预览</div>
        <div className="evidence cjk">{k.preview}</div>
        <button className="btn tiny" style={{ marginTop: 10 }}><I.eye size={13} />打开完整来源</button>
      </div>
      <div className="insp-sec">
        <div className="lbl">片段（前 3）</div>
        {[1, 2, 3].map((n) => (
          <div className="src-item" key={n}><I.doc size={13} className="k" /><span>片段 #{n} · 命中于最近回复</span></div>
        ))}
      </div>
    </>
  );
}

function TaskInspector({ t }) {
  return (
    <>
      <div className="insp-sec">
        <div style={{ fontSize: 14.5, fontWeight: 600, color: "var(--ink)", marginBottom: 6 }}>{t.title}</div>
        <div className="cjk" style={{ fontSize: 13, color: "var(--text-2)", lineHeight: 1.7 }}>{t.note}</div>
      </div>
      <div className="insp-sec">
        <div className="lbl">提醒</div>
        {t.reminder ? (
          <>
            <div className="kv"><span className="k">时间</span><span className="v">{t.reminder.at}</span></div>
            <div className="kv"><span className="k">状态</span><span className="v">{reminderLabel(t.reminder.state)}</span></div>
            <div className="hstack" style={{ marginTop: 4, fontSize: 11.5, color: "var(--text-3)" }}>
              <I.bell size={13} /><span>由 Mira 本地通知调度器管理，不发布到系统日历</span>
            </div>
          </>
        ) : <div className="muted" style={{ fontSize: 12.5 }}>尚未设置提醒时间</div>}
      </div>
      <div className="insp-sec">
        <div className="kv"><span className="k">工作区</span><span className="v">{t.workspace}</span></div>
        <div className="kv"><span className="k">来源</span><span className="v">{t.origin}</span></div>
      </div>
      <div className="insp-sec">
        <div className="lbl">修订历史</div>
        <div className="src-item"><I.clock size={13} className="k" /><span>创建 · 保留来源证据</span></div>
        <div className="src-item"><I.pencil size={13} className="k" /><span>设置提醒时间</span></div>
      </div>
    </>
  );
}

/* ===================== SETTINGS SHEET ===================== */
const SETTINGS_TABS = [
  { id: "general", label: "通用", icon: I.gear },
  { id: "providers", label: "服务商", icon: I.cloud },
  { id: "models", label: "默认模型", icon: I.sparkle },
  { id: "memory", label: "记忆", icon: I.memory },
  { id: "data", label: "数据与隐私", icon: I.shield },
];

function SettingsSheet({ onClose, theme, onTheme }) {
  const [tab, setTab] = sU("providers");
  const [lang, setLang] = sU("zh");
  const [capture, setCapture] = sU("off");
  const active = SETTINGS_TABS.find((t) => t.id === tab);
  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="settings-window" role="dialog" aria-label="设置">
        <div className="settings-rail">
        <div className="sb-head" style={{ WebkitAppRegion: "drag" }}>
          <div className="traffic">
            <button className="light red" title="关闭设置" aria-label="关闭设置"
                    onClick={onClose} style={{ WebkitAppRegion: "no-drag", border: "none", padding: 0, cursor: "pointer" }} />
            <span className="light amber" /><span className="light green" />
          </div>
        </div>
        <div className="settings-rail-title">设置</div>
        <div className="settings-rail-nav scroll">
          {SETTINGS_TABS.map((t) => (
            <div key={t.id} className={"sb-item" + (tab === t.id ? " sel" : "")} onClick={() => setTab(t.id)}>
              <t.icon size={16} className="ico" /><span className="label">{t.label}</span>
            </div>
          ))}
        </div>
      </div>
      <div className="settings-content">
        <div className="settings-topbar" style={{ WebkitAppRegion: "drag" }}>
          <span className="h">{active.label}</span>
          <div className="grow" />
          <div style={{ WebkitAppRegion: "no-drag" }}><button className="btn" onClick={onClose}>完成</button></div>
        </div>
        <div className="settings-scroll scroll">
            {tab === "general" && (
              <>
                <div className="sec-title">外观</div>
                <div className="panel">
                  <FieldRow title="外观模式" desc="随系统或手动切换浅色 / 深色">
                    <Seg value={theme} onChange={onTheme} options={[
                      { value: "light", label: "浅色" }, { value: "dark", label: "深色" }, { value: "auto", label: "跟随系统" },
                    ]} />
                  </FieldRow>
                  <FieldRow title="显示语言" desc="仅切换界面语言，不影响用户内容与模型回复语言">
                    <Seg value={lang} onChange={setLang} options={[{ value: "zh", label: "简体中文" }, { value: "en", label: "English" }]} />
                  </FieldRow>
                </div>
                <div className="sec-title">快捷键</div>
                <div className="panel">
                  <FieldRow title="新建对话"><span className="kbd">⌘N</span></FieldRow>
                  <FieldRow title="发送消息"><span className="kbd">⌘⏎</span></FieldRow>
                  <FieldRow title="停止执行"><span className="kbd">⌘.</span></FieldRow>
                  <FieldRow title="全局搜索"><span className="kbd">⌘K</span></FieldRow>
                </div>
              </>
            )}

            {tab === "providers" && (
              <>
                <div className="sec-title">已配置的服务商</div>
                <div className="panel">
                  {PROVIDERS.map((p) => (
                    <div className="prov-row" key={p.id}>
                      <div className="prov-logo">{p.name[0]}</div>
                      <div className="prov-info">
                        <div className="n">{p.name}</div>
                        <div className="e">{p.endpoint}</div>
                      </div>
                      <span className="hstack" style={{ fontSize: 11.5, color: "var(--text-3)", gap: 6 }}>
                        {p.key ? <><I.key size={13} />已保存密钥</> : <span className="muted">未配置密钥</span>}
                      </span>
                      <span className="tag" style={{ marginLeft: 4 }}>{p.models} 个模型</span>
                      <Switch on={p.active} onChange={() => {}} />
                    </div>
                  ))}
                </div>
                <button className="btn"><I.plus size={14} />添加服务商</button>
                <div className="hstack cjk" style={{ marginTop: 14, fontSize: 12, color: "var(--text-3)", gap: 7 }}>
                  <I.shield size={14} /><span>API Key 仅保存在本机 Keychain；获取模型只查询目录，不发送对话。</span>
                </div>
              </>
            )}

            {tab === "models" && (
              <>
                <div className="sec-title">用途级默认模型</div>
                <div className="panel">
                  {PURPOSES.map((p) => (
                    <FieldRow key={p.id} title={p.label} desc={p.id === "memory" ? "后台记忆提取须单独选择模型并显式开启" : null}>
                      <button className="select">
                        {p.warn && <span className="status-dot warn" />}
                        <span style={{ color: p.warn ? "var(--tint-amber)" : "var(--text)" }}>{p.model}</span>
                        <I.chevDown size={13} />
                      </button>
                    </FieldRow>
                  ))}
                </div>
                <div className="sec-title">模型池</div>
                <div className="panel">
                  {MODEL_POOL.map((m) => (
                    <div className="field-row" key={m.id}>
                      <div className="fl">
                        <div className="t">{m.name}</div>
                        <div className="d">{m.provider} · {m.ctx} 上下文 · {m.caps.join(" / ")}</div>
                      </div>
                      <Switch on={m.on} onChange={() => {}} />
                    </div>
                  ))}
                </div>
              </>
            )}

            {tab === "memory" && (
              <>
                <div className="sec-title">自动捕获</div>
                <div className="panel">
                  <FieldRow title="捕获模式" desc="默认关闭。开启后新消息在成功回复后处理，历史不回填">
                    <Seg value={capture} onChange={setCapture} options={[
                      { value: "off", label: "关闭" }, { value: "review", label: "仅候选" }, { value: "auto", label: "自动" },
                    ]} />
                  </FieldRow>
                  <FieldRow title="每日 Token 预算" desc="超出预算后暂停当天的自动提取">
                    <input className="input" defaultValue="20,000" style={{ minWidth: 120, textAlign: "right" }} />
                  </FieldRow>
                  <FieldRow title="敏感候选默认仅本地" desc="敏感记忆需在编辑器中显式开启远程使用">
                    <Switch on={true} onChange={() => {}} />
                  </FieldRow>
                </div>
                <div className="hstack cjk" style={{ fontSize: 12, color: "var(--tint-amber)", gap: 7 }}>
                  <I.info size={14} /><span>记忆提取用途尚未绑定模型，请先在「默认模型」中设置。</span>
                </div>
              </>
            )}

            {tab === "data" && (
              <>
                <div className="sec-title">本地资料库</div>
                <div className="panel">
                  <FieldRow title="资料库位置" desc="~/Library/Application Support/Mira">
                    <button className="btn tiny">在访达中显示</button>
                  </FieldRow>
                  <FieldRow title="Schema 版本"><span className="kbd">v12</span></FieldRow>
                  <FieldRow title="完整备份" desc="导出数据库、引用文件与校验清单的目录 bundle">
                    <button className="btn tiny"><I.upload size={13} />立即备份</button>
                  </FieldRow>
                  <FieldRow title="清理未引用文件" desc="七天宽限期后回收文件副本；引用的历史版本保留">
                    <button className="btn tiny"><I.trash size={13} />清理</button>
                  </FieldRow>
                </div>
                <div className="sec-title">隐私</div>
                <div className="panel">
                  <FieldRow title="仅本地模式" desc="停用所有远程模型调用，仅保留本机能力">
                    <Switch on={false} onChange={() => {}} />
                  </FieldRow>
                  <FieldRow title="日志中排除个人内容" desc="不在普通日志/错误中记录请求体、响应或密钥">
                    <Switch on={true} onChange={() => {}} />
                  </FieldRow>
                </div>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

/* ===================== COMMAND PALETTE ===================== */
function CommandPalette({ onClose, onPick }) {
  const [q, setQ] = sU("");
  const [cur, setCur] = sU(0);
  const inputRef = sR(null);
  sE(() => { inputRef.current && inputRef.current.focus(); }, []);

  const groups = [
    { h: "对话", items: WORKSPACES.flatMap((w) => w.conversations).slice(0, 3).map((c) => ({ icon: I.chat, label: c.title, meta: "对话", go: () => onPick("chat", c.id) })) },
    { h: "记忆", items: MEMORIES.slice(0, 2).map((m) => ({ icon: I.memory, label: m.title, meta: statusLabel(m.status), go: () => onPick("memory", m.id) })) },
    { h: "知识", items: KNOWLEDGE.slice(0, 2).map((k) => ({ icon: I.doc, label: k.title, meta: "来源", go: () => onPick("knowledge", k.id) })) },
    { h: "动作", items: [
      { icon: I.compose, label: "新建对话", meta: "⌘N", go: () => onPick("new") },
      { icon: I.tasks, label: "打开任务与提醒", meta: "", go: () => onPick("tasks") },
      { icon: I.gear, label: "打开设置", meta: "⌘,", go: () => onPick("settings") },
    ] },
  ];
  const flat = [];
  groups.forEach((g) => g.items.forEach((it) => flat.push(it)));
  const filtered = q ? flat.filter((it) => it.label.toLowerCase().includes(q.toLowerCase())) : flat;

  sE(() => { setCur(0); }, [q]);

  const onKey = (e) => {
    if (e.key === "ArrowDown") { e.preventDefault(); setCur((c) => Math.min(c + 1, filtered.length - 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setCur((c) => Math.max(c - 1, 0)); }
    else if (e.key === "Enter") { e.preventDefault(); filtered[cur] && filtered[cur].go(); }
    else if (e.key === "Escape") { onClose(); }
  };

  let idx = -1;
  return (
    <div className="scrim top" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="palette" role="dialog" aria-label="全局搜索">
        <div className="palette-input">
          <I.search size={18} style={{ color: "var(--text-3)" }} />
          <input ref={inputRef} value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={onKey}
                 placeholder="搜索对话、记忆、知识，或执行动作…" />
          <span className="kbd">Esc</span>
        </div>
        <div className="palette-scroll scroll">
          {q ? (
            filtered.length ? filtered.map((it) => { idx++; const my = idx;
              return (
                <div key={my} className={"pal-item" + (cur === my ? " cur" : "")}
                     onMouseEnter={() => setCur(my)} onClick={it.go}>
                  <it.icon size={16} className="ico" /><span>{it.label}</span><span className="meta">{it.meta}</span>
                </div>
              );
            }) : <div className="pal-item muted">没有匹配结果</div>
          ) : (
            groups.map((g) => (
              <div key={g.h}>
                <div className="pal-group-h">{g.h}</div>
                {g.items.map((it) => { idx++; const my = idx;
                  return (
                    <div key={my} className={"pal-item" + (cur === my ? " cur" : "")}
                         onMouseEnter={() => setCur(my)} onClick={it.go}>
                      <it.icon size={16} className="ico" /><span>{it.label}</span><span className="meta">{it.meta}</span>
                    </div>
                  );
                })}
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}

/* ===================== MODEL POPOVER ===================== */
function ModelPopover({ x, y, current, onPick, onClose }) {
  sE(() => {
    const h = () => onClose();
    window.addEventListener("mousedown", h);
    return () => window.removeEventListener("mousedown", h);
  }, []);
  const on = MODEL_POOL.filter((m) => m.on);
  return (
    <div className="popover" style={{ left: x, bottom: y }} onMouseDown={(e) => e.stopPropagation()}>
      {on.map((m) => (
        <div className="pop-item" key={m.id} onClick={() => { onPick(m.name); onClose(); }}>
          <I.sparkle size={15} className="ico" />
          <div><div>{m.name}</div><div className="sub">{m.provider} · {m.ctx}</div></div>
          {current === m.name && <span className="chk"><I.check size={15} /></span>}
        </div>
      ))}
      <div className="pop-sep" />
      <div className="pop-item" style={{ color: "var(--text-2)" }}><I.gear size={15} className="ico" /><span>管理模型池…</span></div>
    </div>
  );
}

/* ===================== TOAST ===================== */
function Toast({ text }) {
  return <div className="toast"><span className="ok"><I.check size={16} /></span><span className="cjk">{text}</span></div>;
}

Object.assign(window, { Inspector, SettingsSheet, CommandPalette, ModelPopover, Toast, reminderLabel });
