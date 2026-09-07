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
        <IconBtn icon={I.x} title="关闭" size="var(--icon-md)" onClick={onClose} />
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
            {s.kind === "knowledge" ? <I.doc size="var(--icon-md)" className="k" /> :
             s.kind === "memory" ? <I.memory size="var(--icon-md)" className="k" /> : <I.chat size="var(--icon-md)" className="k" />}
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
            <I.wrench size="var(--icon-sm)" className="k" />
            <span style={{ fontFamily: "var(--font-mono)", fontSize: "var(--font-small)" }}>{t.name}</span>
            <span className="grow" /><I.check size="var(--icon-md)" style={{ color: "var(--tint-green)" }} />
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
        <div className="hstack" style={{ marginBottom: "var(--space-3)" }}>
          <span className="tag">{m.kind}</span>
          <span className={"tag " + m.status}>{statusLabel(m.status)}</span>
        </div>
        <div style={{ fontSize: "var(--font-body)", fontWeight: "var(--weight-strong)", color: "var(--text)", marginBottom: "var(--space-3)" }}>{m.title}</div>
        <div className="cjk" style={{ fontSize: "var(--font-body)", color: "var(--text-2)", lineHeight: "var(--line-reading)" }}>{m.body}</div>
      </div>
      <div className="insp-sec">
        <div className="lbl">来源证据</div>
        <div className="evidence cjk">“{m.evidence}”</div>
        <div className="src-item" style={{ marginTop: "var(--space-2)" }}><I.chat size="var(--icon-md)" className="k" /><span>{m.origin}</span></div>
      </div>
      <div className="insp-sec">
        <div className="kv"><span className="k">范围</span><span className="v">{m.scope}</span></div>
        <div className="kv"><span className="k">更新</span><span className="v">{m.updated}</span></div>
        <div className="kv"><span className="k">修订次数</span><span className="v">{m.revisions}</span></div>
        <div className="field-row" style={{ borderBottom: "none", padding: "var(--space-3) 0 0" }}>
          <div className="fl"><div className="t">允许模型使用</div><div className="d">关闭时该记忆仅保存在本机</div></div>
          <Switch on={m.allowRemote} onChange={() => onAction("remote", m)} />
        </div>
      </div>
      <div className="insp-sec hstack">
        {m.status === "candidate" && <>
          <button className="btn primary" style={{ flex: 1 }} onClick={() => onAction("approve", m)}><I.check size="var(--icon-md)" />确认记住</button>
          <button className="btn ghost" onClick={() => onAction("ignore", m)}>忽略</button>
        </>}
        {m.status === "active" && <>
          <button className="btn" style={{ flex: 1 }} onClick={() => onAction("edit", m)}><I.pencil size="var(--icon-md)" />编辑</button>
          <button className="btn ghost" onClick={() => onAction("archive", m)}><I.archive size="var(--icon-md)" />归档</button>
        </>}
        {m.status === "archived" &&
          <button className="btn" style={{ flex: 1 }} onClick={() => onAction("restore", m)}><I.restore size="var(--icon-md)" />恢复</button>}
      </div>
    </>
  );
}

function KnowledgeInspector({ k, onToggleRemote }) {
  return (
    <>
      <div className="insp-sec">
        <div className="hstack" style={{ marginBottom: "var(--space-3)" }}>
          <span className="avatar" style={{ width: 26, height: 26 }}><I.doc size="var(--icon-md)" /></span>
          <div><div style={{ fontSize: "var(--font-body)", fontWeight: "var(--weight-strong)", color: "var(--text)" }}>{k.title}</div>
            <div style={{ fontSize: "var(--font-small)", color: "var(--text-3)" }}>{k.kind}</div></div>
        </div>
      </div>
      <div className="insp-sec">
        <div className="kv"><span className="k">当前版本</span><span className="v">v{k.versions}（不可变）</span></div>
        <div className="kv"><span className="k">片段</span><span className="v">{k.chunks} 个</span></div>
        <div className="kv"><span className="k">大小</span><span className="v mono">{k.size}</span></div>
        <div className="kv"><span className="k">更新</span><span className="v">{k.updated}</span></div>
        <div className="field-row" style={{ borderBottom: "none", padding: "var(--space-3) 0 0" }}>
          <div className="fl"><div className="t">允许模型使用</div><div className="d">开启后其片段可供所配置的服务商检索</div></div>
          <Switch on={k.allowRemote} onChange={() => onToggleRemote(k)} />
        </div>
      </div>
      <div className="insp-sec">
        <div className="lbl">来源预览</div>
        <div className="evidence cjk">{k.preview}</div>
        <button className="btn tiny" style={{ marginTop: "var(--space-3)" }}><I.eye size="var(--icon-sm)" />打开完整来源</button>
      </div>
      <div className="insp-sec">
        <div className="lbl">片段（前 3）</div>
        {[1, 2, 3].map((n) => (
          <div className="src-item" key={n}><I.doc size="var(--icon-sm)" className="k" /><span>片段 #{n} · 命中于最近回复</span></div>
        ))}
      </div>
    </>
  );
}

function TaskInspector({ t }) {
  return (
    <>
      <div className="insp-sec">
        <div style={{ fontSize: "var(--font-body)", fontWeight: "var(--weight-strong)", color: "var(--text)", marginBottom: "var(--space-2)" }}>{t.title}</div>
        <div className="cjk" style={{ fontSize: "var(--font-body)", color: "var(--text-2)", lineHeight: "var(--line-reading)" }}>{t.note}</div>
      </div>
      <div className="insp-sec">
        <div className="lbl">提醒</div>
        {t.reminder ? (
          <>
            <div className="kv"><span className="k">时间</span><span className="v">{t.reminder.at}</span></div>
            <div className="kv"><span className="k">状态</span><span className="v">{reminderLabel(t.reminder.state)}</span></div>
            <div className="hstack" style={{ marginTop: "var(--space-2)", fontSize: "var(--font-small)", color: "var(--text-3)" }}>
              <I.bell size="var(--icon-sm)" /><span>由 Mira 本地通知调度器管理，不发布到系统日历</span>
            </div>
          </>
        ) : <div className="muted" style={{ fontSize: "var(--font-small)" }}>尚未设置提醒时间</div>}
      </div>
      <div className="insp-sec">
        <div className="kv"><span className="k">工作区</span><span className="v">{t.workspace}</span></div>
        <div className="kv"><span className="k">来源</span><span className="v">{t.origin}</span></div>
      </div>
      <div className="insp-sec">
        <div className="lbl">修订历史</div>
        <div className="src-item"><I.clock size="var(--icon-sm)" className="k" /><span>创建 · 保留来源证据</span></div>
        <div className="src-item"><I.pencil size="var(--icon-sm)" className="k" /><span>设置提醒时间</span></div>
      </div>
    </>
  );
}

/* ===================== SETTINGS SHEET ===================== */
const SETTINGS_TABS = [
  { id: "general", label: "通用", icon: I.gear },
  { id: "providers", label: "服务商", icon: I.cloud },
  { id: "models", label: "模型", icon: I.sparkle },
  { id: "memory", label: "记忆", icon: I.memory },
  { id: "data", label: "数据与隐私", icon: I.shield },
];

function SettingsSheet({ onClose, theme, onTheme, config, onConfig, initialTab = "providers" }) {
  const [history, setHistory] = sU({ entries: [{ tab: initialTab, detail: null, modelTab: "defaults" }], index: 0 });
  const route = history.entries[history.index];
  const { tab, detail } = route;
  const pushRoute = next => setHistory(h => {
    if (JSON.stringify(h.entries[h.index]) === JSON.stringify(next)) return h;
    return { entries: [...h.entries.slice(0, h.index + 1), next], index: h.index + 1 };
  });
  const navigate = destination => pushRoute({ tab: destination, detail: null, modelTab: "defaults" });
  const openDetail = detail => pushRoute({ ...route, detail });
  const stepHistory = offset => setHistory(h => ({ ...h, index: Math.max(0, Math.min(h.entries.length - 1, h.index + offset)) }));
  const detailItem = detail?.kind === "provider" ? config.providers.find(p => p.id === detail.id)
    : detail?.kind === "model" ? config.models.find(m => m.id === detail.id) : null;
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
            <button type="button" key={t.id} className={"sb-item" + (tab === t.id ? " sel" : "")} onClick={() => navigate(t.id)}>
              <t.icon size="var(--icon-lg)" className="ico" /><span className="label">{t.label}</span>
            </button>
          ))}
        </div>
      </div>
      <div className="settings-content">
        <div className="settings-topbar" style={{ WebkitAppRegion: "drag" }}>
          <div className="settings-history" style={{ WebkitAppRegion: "no-drag" }}>
            <button className="icon-btn" aria-label="后退" title="后退" disabled={history.index === 0} onClick={() => stepHistory(-1)}><span className="back-icon"><I.chevRight size="var(--icon-md)" /></span></button>
            <button className="icon-btn" aria-label="前进" title="前进" disabled={history.index === history.entries.length - 1} onClick={() => stepHistory(1)}><I.chevRight size="var(--icon-md)" /></button>
          </div>
          <span className="h">{detailItem?.name || active.label}</span>
        </div>
        <div className="settings-scroll scroll" key={tab + (detail?.id || "")}>
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

            {tab === "providers" && (detailItem && detail?.kind === "provider"
              ? <ProviderEditor provider={detailItem} config={config} onChange={onConfig} />
              : <ProviderSettings config={config} onSelect={id => openDetail({kind:"provider",id})} />)}
            {tab === "models" && (detailItem && detail?.kind === "model"
              ? <ModelEditor model={detailItem} config={config} onChange={onConfig} />
              : <ModelSettings tab={route.modelTab} onTabChange={modelTab => pushRoute({...route, modelTab})} config={config} onChange={onConfig} onProviders={() => navigate("providers")} onEdit={id => openDetail({kind:"model",id})} />)}

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
                {!modelReady(config.models.find(m => m.id === config.defaults.memory), config, "memory") &&
                  <div className="hstack cjk" style={{ fontSize: "var(--font-small)", color: "var(--tint-amber)", gap: "var(--space-3)" }}>
                    <I.info size="var(--icon-md)" /><span>记忆提取尚未选择可用模型，请先在「模型」中设置。</span>
                  </div>}
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
                    <button className="btn tiny"><I.upload size="var(--icon-sm)" />立即备份</button>
                  </FieldRow>
                  <FieldRow title="清理未引用文件" desc="七天宽限期后回收文件副本；引用的历史版本保留">
                    <button className="btn tiny"><I.trash size="var(--icon-sm)" />清理</button>
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
          {["providers", "models"].includes(tab) && <div className="config-preview-note">交互预览 · 示例数据，不发起真实请求</div>}
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
          <I.search size="var(--icon-lg)" style={{ color: "var(--text-3)" }} />
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
                  <it.icon size="var(--icon-md)" className="ico" /><span>{it.label}</span><span className="meta">{it.meta}</span>
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
                      <it.icon size="var(--icon-md)" className="ico" /><span>{it.label}</span><span className="meta">{it.meta}</span>
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
function ModelPopover({ x, y, current, onPick, onClose, models, onManage }) {
  sE(() => {
    const h = () => onClose();
    window.addEventListener("mousedown", h);
    return () => window.removeEventListener("mousedown", h);
  }, []);
  const on = models;
  return (
    <div className="popover" style={{ left: x, bottom: y }} onMouseDown={(e) => e.stopPropagation()}>
      {on.map((m) => (
        <div className="pop-item" key={m.id} onClick={() => { onPick(m.id); onClose(); }}>
          <I.sparkle size="var(--icon-md)" className="ico" />
          <div><div>{m.name}</div><div className="sub">{m.provider} · {m.ctx}</div></div>
          {current === m.id && <span className="chk"><I.check size="var(--icon-md)" /></span>}
        </div>
      ))}
      {!on.length && <div className="config-note" style={{ padding: "var(--space-3)" }}>暂无可用模型，请先完成配置。</div>}
      <div className="pop-sep" />
      <button className="pop-item manage-models" onClick={() => { onClose(); onManage(); }}><I.gear size="var(--icon-md)" className="ico" /><span>管理模型池…</span></button>
    </div>
  );
}

/* ===================== TOAST ===================== */
function Toast({ text }) {
  return <div className="toast"><span className="ok"><I.check size="var(--icon-md)" /></span><span className="cjk">{text}</span></div>;
}

Object.assign(window, { Inspector, SettingsSheet, CommandPalette, ModelPopover, Toast, reminderLabel });
