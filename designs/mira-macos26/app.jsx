/* App shell: window chrome, two-column layout, on-demand third pane, state. */
const { useState: aU, useEffect: aE, useRef: aR, useCallback: aC } = React;

function makeReply(userText) {
  return {
    role: "assistant",
    time: "现在",
    context: {
      sources: [
        { label: "记忆：呈现归 MainActor，执行归运行时", kind: "memory" },
        { label: "架构总览 · ARCHITECTURE.md", kind: "knowledge" },
        { label: "当前对话 · 全部轮次", kind: "conversation" },
      ],
      tokens: "2,480 / 32k",
      model: "Claude Sonnet 5",
    },
    thinking:
      "先确认用户意图，从冻结的上下文里取相关记忆与知识片段，再组织一个结构清晰、可追溯的回答，并在结尾判断是否值得记为候选记忆。",
    tools: [{ name: "search_knowledge", arg: userText.slice(0, 18), result: "命中 2 个片段", state: "done" }],
    blocks: [
      { type: "p", text: "明白了。基于当前工作区已冻结的上下文，我的建议如下：" },
      {
        type: "list",
        items: [
          "先确认这条信息属于**可复用的认知**，再决定保存范围（本工作区 / 全局）。",
          "回答只引用冻结上下文中的来源，保证可追溯 [1]。",
          "若形成新的决策或偏好，会作为**候选记忆**提交给你确认，不会悄悄记住。",
        ],
      },
      { type: "p", text: "需要的话，我可以把结论整理成一条任务并设置本地提醒。" },
    ],
    citations: [{ n: 1, source: "ARCHITECTURE.md · 派生关系", quote: "检索、摘要与索引对原始记录具有明确的派生关系。" }],
    memory: { kind: "偏好", title: "回答需引用冻结上下文并保持可追溯", scope: "Mira 开发", state: "candidate" },
  };
}

function App() {
  const winRef = aR(null);
  const timers = aR([]);

  const [theme, setTheme] = aU("auto");
  const [collapsed, setCollapsed] = aU(false);
  const [nav, setNav] = aU("chat");
  const [selConv, setSelConv] = aU("c-arch");
  const [threads, setThreads] = aU({ "c-arch": THREAD });
  const [livePhase, setLivePhase] = aU(null);
  const [model, setModel] = aU("Claude Sonnet 5");

  const [insp, setInsp] = aU({ open: false, kind: null, item: null });
  const [memories, setMemories] = aU(MEMORIES);
  const [memFilter, setMemFilter] = aU("active");
  const [sources, setSources] = aU(KNOWLEDGE);
  const [tasks, setTasks] = aU(TASKS);
  const [taskFilter, setTaskFilter] = aU("all");

  const [palette, setPalette] = aU(false);
  const [settings, setSettings] = aU(false);
  const [pop, setPop] = aU(null);
  const [toast, setToast] = aU(null);

  /* theme */
  aE(() => {
    const root = document.documentElement;
    if (theme === "auto") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", theme);
  }, [theme]);

  const flashToast = (t) => { setToast(t); setTimeout(() => setToast(null), 2200); };
  const clearTimers = () => { timers.current.forEach(clearTimeout); timers.current = []; };
  aE(() => clearTimers, []);

  const messages = threads[selConv] || [];

  /* send + simulate pipeline */
  const send = (text) => {
    if (livePhase != null) return;
    const reply = makeReply(text);
    const userMsg = { role: "user", text, time: "现在" };
    setThreads((th) => ({ ...th, [selConv]: [...(th[selConv] || []), userMsg, reply] }));
    setLivePhase(0);
    const steps = [[700, 1], [1400, 2], [2200, 3], [3600, 4]];
    steps.forEach(([ms, p]) => timers.current.push(setTimeout(() => {
      setLivePhase(p);
      if (p === 4) { clearTimers(); flashToast("已记为候选记忆"); }
    }, ms)));
  };
  const stop = () => { clearTimers(); setLivePhase(4); };

  const openChatInspector = () => {
    const list = threads[selConv] || [];
    const lastA = [...list].reverse().find((m) => m.role === "assistant") || THREAD[1];
    setInsp({ open: true, kind: "chat", item: lastA });
  };

  const navTo = (n) => { setNav(n); setInsp({ open: false, kind: null, item: null }); };
  const selectConv = (id) => { setNav("chat"); setSelConv(id); setInsp({ open: false }); };

  const newChat = () => {
    setNav("chat"); setSelConv("draft");
    setThreads((th) => ({ ...th, draft: [] }));
    setInsp({ open: false });
  };

  const toggleTheme = () => {
    const eff = theme === "dark" ? "dark" : theme === "light" ? "light"
      : (matchMedia && matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    setTheme(eff === "dark" ? "light" : "dark");
  };

  /* memory actions */
  const memAction = (action, m) => {
    if (action === "approve") { setMemories((xs) => xs.map((x) => x.id === m.id ? { ...x, status: "active" } : x)); flashToast("已确认为生效记忆"); setInsp({ open: false }); }
    else if (action === "ignore") { setMemories((xs) => xs.filter((x) => x.id !== m.id)); flashToast("已忽略候选记忆"); setInsp({ open: false }); }
    else if (action === "archive") { setMemories((xs) => xs.map((x) => x.id === m.id ? { ...x, status: "archived" } : x)); flashToast("已归档"); setInsp({ open: false }); }
    else if (action === "restore") { setMemories((xs) => xs.map((x) => x.id === m.id ? { ...x, status: "active" } : x)); flashToast("已恢复到生效中"); setInsp({ open: false }); }
    else if (action === "remote") { setMemories((xs) => xs.map((x) => x.id === m.id ? { ...x, allowRemote: !x.allowRemote } : x)); }
    else if (action === "edit") { flashToast("打开记忆编辑器（示意）"); }
  };
  aE(() => {
    if (insp.open && insp.kind === "memory") {
      const cur = memories.find((x) => x.id === insp.item.id);
      if (cur && cur !== insp.item) setInsp((s) => ({ ...s, item: cur }));
    }
  }, [memories]);

  const toggleKnowRemote = (k) => {
    setSources((xs) => xs.map((x) => x.id === k.id ? { ...x, allowRemote: !x.allowRemote } : x));
    flashToast(k.allowRemote ? "已设为仅本地" : "已允许模型使用");
  };
  const importKnow = () => flashToast("选择 Markdown 文件导入（示意）");

  const toggleTask = (t) => setTasks((xs) => xs.map((x) => x.id === t.id ? { ...x, done: !x.done } : x));

  /* command palette */
  const palettePick = (kind, id) => {
    setPalette(false);
    if (kind === "chat") selectConv(id);
    else if (kind === "memory") { navTo("memory"); const m = memories.find((x) => x.id === id); if (m) { setMemFilter(m.status); setTimeout(() => setInsp({ open: true, kind: "memory", item: m }), 60); } }
    else if (kind === "knowledge") { navTo("knowledge"); const k = sources.find((x) => x.id === id); if (k) setTimeout(() => setInsp({ open: true, kind: "knowledge", item: k }), 60); }
    else if (kind === "tasks") navTo("tasks");
    else if (kind === "settings") setSettings(true);
    else if (kind === "new") newChat();
  };

  /* model popover position */
  const openModelPop = (e) => {
    e.stopPropagation();
    const wr = winRef.current.getBoundingClientRect();
    const br = e.currentTarget.getBoundingClientRect();
    setPop({ x: br.left - wr.left, y: wr.bottom - br.top + 8 });
  };

  /* keyboard */
  aE(() => {
    const onKey = (e) => {
      const meta = e.metaKey || e.ctrlKey;
      if (meta && e.key.toLowerCase() === "k") { e.preventDefault(); setPalette((v) => !v); }
      else if (meta && e.key.toLowerCase() === "n") { e.preventDefault(); newChat(); }
      else if (meta && e.key === ",") { e.preventDefault(); setSettings(true); }
      else if (meta && e.key === ".") { if (livePhase != null && livePhase < 4) { e.preventDefault(); stop(); } }
      else if (e.key === "Escape") { setPalette(false); setSettings(false); setPop(null); setInsp((s) => ({ ...s, open: false })); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [livePhase]);

  return (
    <div className="stage">
      <div className="window" ref={winRef} style={{ "--sidebar-w": "262px" }}>
        <div className="body">
          {!collapsed && (
            <Sidebar
              nav={nav} selConv={selConv}
              onNav={navTo} onSelConv={selectConv}
              onNewChat={newChat}
              onSettings={() => setSettings(true)}
              onToggleSidebar={() => setCollapsed(true)}
              theme={theme} onToggleTheme={toggleTheme}
            />
          )}

          <div className="content">
            {collapsed && (
              <div style={{ position: "absolute", top: 12, left: 14, zIndex: 20 }}>
                <IconBtn icon={I.sidebar} title="展开侧栏" onClick={() => setCollapsed(false)} />
              </div>
            )}

            {nav === "chat" && (
              <ChatView
                conv={selConv} messages={messages} livePhase={livePhase} model={model}
                onSend={send} onModelClick={openModelPop}
                onOpenInspector={() => insp.open && insp.kind === "chat" ? setInsp({ open: false }) : openChatInspector()}
                onOpenMemory={() => { navTo("memory"); setMemFilter("candidate"); }}
                inspectorOpen={insp.open && insp.kind === "chat"}
              />
            )}
            {nav === "memory" && (
              <MemoryView
                memories={memories} filter={memFilter} onFilter={setMemFilter}
                selId={insp.kind === "memory" && insp.open ? insp.item.id : null}
                onSelect={(m) => setInsp({ open: true, kind: "memory", item: m })}
                onAction={memAction} onNew={() => flashToast("新建记忆（示意）")}
              />
            )}
            {nav === "knowledge" && (
              <KnowledgeView
                sources={sources}
                selId={insp.kind === "knowledge" && insp.open ? insp.item.id : null}
                onSelect={(k) => setInsp({ open: true, kind: "knowledge", item: k })}
                onImport={importKnow} onToggleRemote={toggleKnowRemote}
              />
            )}
            {nav === "tasks" && (
              <TasksView
                tasks={tasks} filter={taskFilter} onFilter={setTaskFilter}
                selId={insp.kind === "task" && insp.open ? insp.item.id : null}
                onToggle={toggleTask}
                onSelect={(t) => setInsp({ open: true, kind: "task", item: t })}
                onNew={() => flashToast("新建任务（示意）")}
              />
            )}
          </div>

          {insp.open && insp.item && (
            <Inspector
              kind={insp.kind} item={insp.item}
              onClose={() => setInsp({ open: false })}
              onAction={memAction} onToggleRemote={toggleKnowRemote}
            />
          )}
        </div>

        {pop && (
          <ModelPopover x={pop.x} y={pop.y} current={model}
                        onPick={(name) => { setModel(name); flashToast("已切换模型：" + name); }}
                        onClose={() => setPop(null)} />
        )}
        {palette && <CommandPalette onClose={() => setPalette(false)} onPick={palettePick} />}
        {settings && <SettingsSheet onClose={() => setSettings(false)} theme={theme} onTheme={setTheme} />}
        {toast && <Toast text={toast} />}
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
