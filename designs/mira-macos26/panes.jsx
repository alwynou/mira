/* Sidebar + content surfaces (presentational; state lives in App). */
const { useState: uS, useEffect: uE, useRef: uR } = React;

/* ============================ SIDEBAR ============================ */
const PRIMARY_NAV = [
  { id: "memory", label: "记忆", icon: I.memory, count: () => MEMORIES.filter((m) => m.status === "active").length },
  { id: "knowledge", label: "知识", icon: I.knowledge, count: () => KNOWLEDGE.length },
  { id: "tasks", label: "任务与提醒", icon: I.tasks, count: () => TASKS.filter((t) => !t.done).length },
];

function Sidebar({ nav, selConv, onNav, onSelConv, onNewChat, onSettings, onToggleSidebar, theme, onToggleTheme }) {
  const [open, setOpen] = uS({ mira: true, writing: false, life: false });
  return (
    <aside className="sidebar" aria-label="侧栏">
      {/* traffic lights + sidebar toggle (top) */}
      <div className="sb-head" style={{ WebkitAppRegion: "drag" }}>
        <div className="traffic" aria-hidden="true">
          <span className="light red" /><span className="light amber" /><span className="light green" />
        </div>
        <div className="grow" />
        <div style={{ WebkitAppRegion: "no-drag" }}>
          <IconBtn icon={I.sidebar} title="收起侧栏" onClick={onToggleSidebar} />
        </div>
      </div>

      {/* brand title at the top of the panel body */}
      <div className="sb-brandbar" style={{ WebkitAppRegion: "drag" }}>
        <span className="brand-name">Mira</span>
      </div>

      {/* first-class destinations — upper, plain icons (no frame) */}
      <div className="sb-upper">
        {PRIMARY_NAV.map((n) => (
          <div key={n.id} className={"sb-item" + (nav === n.id ? " sel" : "")} onClick={() => onNav(n.id)}>
            <n.icon size={16} className="ico" />
            <span className="label">{n.label}</span>
            <span className="count">{n.count()}</span>
          </div>
        ))}
      </div>

      <div className="sb-div" />

      <div className="sb-scroll scroll">
        {/* workspaces — folders (above conversations) */}
        <div className="sb-group">
          <div className="sb-group-h">
            <span>工作区</span>
            <button className="add" title="新建工作区"><I.plus size={13} /></button>
          </div>
          {WORKSPACES.map((w) => (
            <div key={w.id}>
              <div className="sb-item" onClick={() => setOpen((o) => ({ ...o, [w.id]: !o[w.id] }))}>
                <I.caret size={13} className={"twist" + (open[w.id] ? " open" : "")} />
                <I.folder size={16} className="ico" />
                <span className="label">{w.name}</span>
                <span className="count">{w.conversations.length}</span>
              </div>
              {open[w.id] &&
                w.conversations.map((c) => (
                  <div key={c.id}
                       className={"sb-conv" + (nav === "chat" && selConv === c.id ? " sel" : "")}
                       onClick={() => onSelConv(c.id)}>
                    <span className="dotmark" />
                    <span className="t">{c.title}</span>
                  </div>
                ))}
            </div>
          ))}
        </div>

        {/* temporary conversations — flat, with add button like workspaces */}
        <div className="sb-group">
          <div className="sb-group-h">
            <span>对话</span>
            <button className="add" title="新建对话 ⌘N" onClick={onNewChat}><I.plus size={13} /></button>
          </div>
          {INBOX.map((c) => (
            <div key={c.id}
                 className={"sb-conv flat" + (nav === "chat" && selConv === c.id ? " sel" : "")}
                 onClick={() => onSelConv(c.id)}>
              <I.chat size={14} className="glyph" />
              <span className="t">{c.title}</span>
            </div>
          ))}
        </div>
      </div>

      <div className="sb-foot">
        <div className="sb-item" onClick={onSettings}>
          <I.gear size={16} className="ico" />
          <span className="label">设置</span>
        </div>
        <IconBtn icon={theme === "dark" ? I.sun : I.moon} title="切换外观" onClick={onToggleTheme} />
      </div>
    </aside>
  );
}

/* ============================ CHAT ============================ */
function ContextRow({ ctx, live }) {
  return (
    <div className="stage-row">
      <div className="lead">
        {live ? <I.refresh size={15} className="spin" /> : <I.check size={15} style={{ color: "var(--tint-green)" }} />}
        <span>{live ? "准备上下文…" : "上下文已冻结"}</span>
        <span className="muted">· {ctx.sources.length} 个来源 · {ctx.tokens}</span>
      </div>
    </div>
  );
}

function Disclosure({ label, icon: Icon, defaultOpen, spinning, children }) {
  const [o, setO] = uS(!!defaultOpen);
  return (
    <div className="disclosure">
      <div className="stage-row click" onClick={() => setO(!o)}>
        <div className="lead">
          {spinning ? <I.sparkle size={15} className="spin" /> : <Icon size={15} />}
          <span>{label}</span>
        </div>
        <I.caret size={13} className={"twist" + (o ? " open" : "")} style={{ color: "var(--text-3)" }} />
      </div>
      {o && <div className="disclosure-body cjk">{children}</div>}
    </div>
  );
}

function AssistantMessage({ m, phase, onOpenInspector, onOpenMemory, onCite }) {
  const done = phase == null || phase >= 4;
  const showCtx = true;
  const showThinking = phase == null || phase >= 1;
  const showTools = phase == null || phase >= 2;
  const showAnswer = phase == null || phase >= 3;
  return (
    <div className="msg assistant">
      <div className="assistant-head">
        <span className="avatar"><I.sparkle size={14} /></span>
        <span className="who">Mira</span>
        <span className="model">{m.context.model}</span>
        <div className="grow" />
        <IconBtn icon={I.info} title="上下文与执行" size={16} onClick={onOpenInspector} />
      </div>

      {showCtx && <ContextRow ctx={m.context} live={phase === 0} />}

      {showThinking && (
        <Disclosure label="思考" icon={I.sparkle} spinning={phase === 1} defaultOpen={phase === 1}>
          {m.thinking}
        </Disclosure>
      )}

      {showTools && (
        <Disclosure label={`工具执行 · ${m.tools.length} 次`} icon={I.wrench} spinning={phase === 2} defaultOpen={phase === 2}>
          {m.tools.map((t, i) => (
            <div className="tool-line" key={i}>
              <I.wrench size={13} style={{ color: "var(--text-3)" }} />
              <span className="name">{t.name}</span>
              <span className="arg">{t.arg}</span>
              <span className="ok"><I.check size={14} /></span>
            </div>
          ))}
        </Disclosure>
      )}

      {showAnswer && (
        <div className="answer cjk" style={{ animation: "fade .3s var(--ease)" }}>
          {m.blocks.map((b, i) =>
            b.type === "p" ? (
              <p key={i} dangerouslySetInnerHTML={{ __html: renderInline(b.text, onCite) }} />
            ) : (
              <ul key={i}>
                {b.items.map((it, j) => (
                  <li key={j} dangerouslySetInnerHTML={{ __html: renderInline(it) }} />
                ))}
              </ul>
            )
          )}
          {phase === 3 && <span className="caret" style={{ borderRight: "2px solid var(--text)", marginLeft: 1, animation: "blink 1s step-end infinite" }}>&nbsp;</span>}
        </div>
      )}

      {done && m.citations && (
        <div className="citations">
          {m.citations.map((c) => (
            <div className="cite-card" key={c.n} onClick={onOpenInspector}>
              <span className="n">{c.n}</span>
              <div>
                <div className="src">{c.source}</div>
                <div className="q">“{c.quote}”</div>
              </div>
            </div>
          ))}
        </div>
      )}

      {done && m.memory && (
        <div className="receipt">
          <span className="glow"><I.memory size={17} /></span>
          <div className="txt">
            <div><b>已记为候选记忆</b> <span className="tag cand">候选</span></div>
            <div className="sub">{m.memory.title} · 范围 {m.memory.scope}</div>
          </div>
          <button className="btn tiny" onClick={onOpenMemory}>查看</button>
        </div>
      )}
    </div>
  );
}

function renderInline(text, onCite) {
  let html = text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\[(\d+)\]/g, '<a class="cite" href="#cite-$1">$1</a>');
  return html;
}

function ChatView({ conv, messages, livePhase, model, onSend, onModelClick, onOpenInspector, onOpenMemory, inspectorOpen }) {
  const scrollRef = uR(null);
  const fieldRef = uR(null);
  const wrapRef = uR(null);
  const [padBottom, setPadBottom] = uS(150);
  uE(() => {
    if (scrollRef.current) scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [messages.length, livePhase]);
  // keep the last message clear of the floating glass composer
  uE(() => {
    const measure = () => { if (wrapRef.current) setPadBottom(wrapRef.current.offsetHeight + 28); };
    measure();
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, []);

  const isDraft = conv === "draft";
  const found = findConv(conv);
  const title = isDraft ? "新对话" : (found?.title || "对话");
  const sub = isDraft ? "临时对话 · 未归入工作区"
    : (found?.workspace === "临时对话" ? "临时对话 · 未归入工作区" : (found?.workspace || "Mira 开发"));

  const submit = () => {
    const el = fieldRef.current;
    const text = (el?.innerText || "").trim();
    if (!text) return;
    el.innerText = "";
    onSend(text);
  };

  return (
    <>
      <div className="toolbar" style={{ WebkitAppRegion: "drag" }}>
        <div className="tb-title">
          <span className="h">{title}</span>
          <span className="s">{sub} · {model}</span>
        </div>
        <div className="tb-spacer" />
        <div className="tb-actions">
          <IconBtn icon={I.panelRight} title="上下文与执行" on={inspectorOpen} onClick={onOpenInspector} />
          <IconBtn icon={I.dots} title="更多" />
        </div>
      </div>

      <div className="chat-area">
        <div className="chat-scroll scroll" ref={scrollRef}>
        {messages.length === 0 ? (
          <div className="empty">
            <span className="mark"><I.chat size={26} /></span>
            <div className="h">{isDraft ? "开始一段新对话" : "临时对话"}</div>
            <div className="p cjk">对话默认是临时的，不归入任何工作区。需要长期整理时，可以把它移动到某个工作区的文件夹中。</div>
          </div>
        ) : (
          <div className="thread" style={{ paddingBottom: padBottom }}>
            {messages.map((m, i) =>
              m.role === "user" ? (
                <div className="msg user" key={i}>
                  <div className="bubble-user cjk">{m.text}</div>
                </div>
              ) : (
                <AssistantMessage
                  key={i}
                  m={m}
                  phase={i === messages.length - 1 ? livePhase : null}
                  onOpenInspector={onOpenInspector}
                  onOpenMemory={onOpenMemory}
                />
              )
            )}
          </div>
        )}
        </div>

        <div className="composer-wrap" ref={wrapRef}>
          <div className="composer">
            <div
              className="field cjk"
              ref={fieldRef}
              contentEditable
              suppressContentEditableWarning
              role="textbox"
              aria-label="输入消息"
              data-ph="给 Mira 发送消息…"
              onKeyDown={(e) => {
                if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); submit(); }
              }}
            />
            <div className="composer-bar">
              <button className="cicon" title="附加知识 / 文件"><I.plus size={19} /></button>
              <button className="caccess" title="Agent 工具访问">
                <I.wrench size={14} /><span>工具 · 自动</span>
              </button>
              <div className="grow" />
              <button className="model-pick" onClick={onModelClick} title="选择模型与思考强度">
                <span className="mname">{model}</span>
                <span className="meffort">思考 · 高</span>
                <I.chevDown size={13} />
              </button>
              <button className="cicon" title="语音输入"><I.mic size={18} /></button>
              <button
                className={"send" + (livePhase != null && livePhase < 4 ? " stop" : "")}
                title={livePhase != null && livePhase < 4 ? "停止 ⌘." : "发送 ⌘⏎"}
                onClick={livePhase != null && livePhase < 4 ? null : submit}
              >
                {livePhase != null && livePhase < 4 ? <I.stop size={16} /> : <I.arrowUp size={17} />}
              </button>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}

/* ============================ MEMORY ============================ */
function MemoryView({ memories, filter, onFilter, onSelect, selId, onAction, onNew }) {
  const counts = {
    active: memories.filter((m) => m.status === "active").length,
    candidate: memories.filter((m) => m.status === "candidate").length,
    archived: memories.filter((m) => m.status === "archived").length,
  };
  const list = memories.filter((m) => m.status === filter);
  return (
    <>
      <div className="toolbar" style={{ WebkitAppRegion: "drag" }}>
        <div className="tb-title"><span className="h">记忆</span><span className="s">可纠正的长期记忆 · 自动提取默认关闭</span></div>
        <div className="tb-spacer" />
        <div className="tb-actions" style={{ WebkitAppRegion: "no-drag" }}>
          <button className="btn tiny" onClick={onNew}><I.plus size={13} />新建</button>
        </div>
      </div>
      <div className="list-scroll scroll">
        <div className="list-wrap">
          <div className="filter-row">
            <Seg value={filter} onChange={onFilter} options={[
              { value: "active", label: "生效中", count: counts.active },
              { value: "candidate", label: "候选", count: counts.candidate },
              { value: "archived", label: "已归档", count: counts.archived },
            ]} />
            <div className="grow" />
            <div className="search-field" style={{ width: 200 }}><I.search size={14} /><span>搜索记忆</span></div>
          </div>

          {list.map((m) => (
            <div key={m.id} className={"card" + (selId === m.id ? " sel" : "")} onClick={() => onSelect(m)}>
              <div className="card-head">
                <span className="tag">{m.kind}</span>
                <span className="h">{m.title}</span>
                <span className={"tag " + m.status}>{statusLabel(m.status)}</span>
              </div>
              <div className="card-body cjk">{m.body}</div>
              <div className="card-foot">
                <span className="mi"><I.scope size={12} />{m.scope}</span>
                <span className="mi"><I.clock size={12} />{m.updated}</span>
                <span className="mi">{m.allowRemote ? "允许模型使用" : <><I.shield size={12} />仅本地</>}</span>
                <div className="card-actions" onClick={(e) => e.stopPropagation()}>
                  {m.status === "candidate" && <>
                    <button className="btn tiny primary" onClick={() => onAction("approve", m)}><I.check size={13} />确认</button>
                    <button className="btn tiny ghost" onClick={() => onAction("ignore", m)}>忽略</button>
                  </>}
                  {m.status === "active" && <>
                    <IconBtn icon={I.pencil} title="编辑" size={15} onClick={() => onAction("edit", m)} />
                    <IconBtn icon={I.archive} title="归档" size={15} onClick={() => onAction("archive", m)} />
                  </>}
                  {m.status === "archived" &&
                    <button className="btn tiny ghost" onClick={() => onAction("restore", m)}><I.restore size={13} />恢复</button>}
                </div>
              </div>
            </div>
          ))}
          {list.length === 0 && <div className="empty" style={{ minHeight: 240 }}>
            <span className="mark"><I.memory size={24} /></span>
            <div className="p cjk">这个分类下暂时没有记忆。</div>
          </div>}
        </div>
      </div>
    </>
  );
}

/* ============================ KNOWLEDGE ============================ */
function KnowledgeView({ sources, onSelect, selId, onImport, onToggleRemote }) {
  return (
    <>
      <div className="toolbar" style={{ WebkitAppRegion: "drag" }}>
        <div className="tb-title"><span className="h">知识</span><span className="s">Markdown 资料 · 导入即建立不可变版本</span></div>
        <div className="tb-spacer" />
        <div className="tb-actions" style={{ WebkitAppRegion: "no-drag" }}>
          <button className="btn tiny" onClick={onImport}><I.upload size={13} />导入 Markdown</button>
        </div>
      </div>
      <div className="list-scroll scroll">
        <div className="list-wrap">
          {sources.map((k) => (
            <div key={k.id} className={"card" + (selId === k.id ? " sel" : "")} onClick={() => k.importing == null && onSelect(k)}>
              <div className="card-head">
                <span className="avatar" style={{ width: 26, height: 26 }}><I.doc size={15} /></span>
                <span className="h">{k.title}</span>
                {k.importing != null
                  ? <span className="tag" style={{ color: "var(--tint-blue)" }}>导入中</span>
                  : <span className="tag local">{k.kind}</span>}
              </div>
              {k.importing != null ? (
                <div style={{ marginTop: 4 }}>
                  <div className="card-body cjk">正在解析与分片 · {Math.round(k.importing * 100)}%</div>
                  <div className="meter"><i style={{ width: (k.importing * 100) + "%" }} /></div>
                </div>
              ) : (
                <div className="card-body cjk">{k.preview}</div>
              )}
              <div className="card-foot">
                <span className="mi"><I.doc size={12} />{k.chunks} 个片段</span>
                <span className="mi">v{k.versions}</span>
                <span className="mi">{k.size}</span>
                <span className="mi"><I.clock size={12} />{k.updated}</span>
                {k.importing == null && (
                  <div className="card-actions" onClick={(e) => e.stopPropagation()}>
                    <span className="hstack" style={{ fontSize: 11.5, color: "var(--text-3)" }}>
                      允许模型使用
                      <Switch on={k.allowRemote} onChange={() => onToggleRemote(k)} />
                    </span>
                  </div>
                )}
              </div>
            </div>
          ))}
        </div>
      </div>
    </>
  );
}

/* ============================ TASKS ============================ */
function TasksView({ tasks, filter, onFilter, onToggle, onSelect, selId, onNew }) {
  const list = tasks.filter((t) => (filter === "open" ? !t.done : filter === "done" ? t.done : true));
  return (
    <>
      <div className="toolbar" style={{ WebkitAppRegion: "drag" }}>
        <div className="tb-title"><span className="h">任务与提醒</span><span className="s">本地一次性提醒 · 由 Mira 的通知调度器管理</span></div>
        <div className="tb-spacer" />
        <div className="tb-actions" style={{ WebkitAppRegion: "no-drag" }}>
          <button className="btn tiny" onClick={onNew}><I.plus size={13} />新建任务</button>
        </div>
      </div>
      <div className="list-scroll scroll">
        <div className="list-wrap">
          <div className="filter-row">
            <Seg value={filter} onChange={onFilter} options={[
              { value: "all", label: "全部" },
              { value: "open", label: "进行中", count: tasks.filter((t) => !t.done).length },
              { value: "done", label: "已完成", count: tasks.filter((t) => t.done).length },
            ]} />
          </div>
          {list.map((t) => (
            <div key={t.id} className={"task" + (t.done ? " checked" : "") + (selId === t.id ? " sel" : "")} onClick={() => onSelect(t)}>
              <div className={"checkbox" + (t.done ? " done" : "")} onClick={(e) => { e.stopPropagation(); onToggle(t); }}>
                {t.done && <I.check size={13} />}
              </div>
              <div className="tmain">
                <div className="tt">{t.title}</div>
                <div className="tn cjk">{t.note}</div>
                <div className="tmeta">
                  <span className="mi"><I.folder size={12} />{t.workspace}</span>
                  {t.reminder ? (
                    <span className={"reminder-chip " + t.reminder.state}>
                      <I.bell size={12} />{t.reminder.at} · {reminderLabel(t.reminder.state)}
                    </span>
                  ) : <span className="mi muted">无提醒</span>}
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>
    </>
  );
}

/* helpers */
function findConv(id) {
  for (const w of WORKSPACES) { const c = w.conversations.find((x) => x.id === id); if (c) return { ...c, workspace: w.name }; }
  const t = INBOX.find((x) => x.id === id); if (t) return { ...t, workspace: "临时对话" };
  return null;
}
function statusLabel(s) { return s === "active" ? "生效中" : s === "candidate" ? "候选" : "已归档"; }
function reminderLabel(s) {
  return { scheduled: "已排程", pending: "待确认", delivered: "已送达", failed: "失败", cancelled: "已取消" }[s] || s;
}

Object.assign(window, {
  Sidebar, ChatView, MemoryView, KnowledgeView, TasksView,
  AssistantMessage, findConv, statusLabel,
});
