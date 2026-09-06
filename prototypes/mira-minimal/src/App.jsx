import { useEffect, useRef, useState } from "react";
import {
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  BookOpen,
  Brain,
  CaretDown,
  ChatCircle,
  ChatCircleDots,
  Check,
  Circle,
  Cloud,
  FileText,
  Folder,
  GearSix,
  GitBranch,
  MagnifyingGlass,
  Microphone,
  NotePencil,
  Plus,
  ShieldCheck,
  SidebarSimple,
  Sparkle,
  Tray,
  X,
} from "@phosphor-icons/react";

const workspaces = ["个人项目", "Mira 开发", "研究与笔记"];

const conversations = [
  "完善知识库导入流程",
  "自动记忆边界策略复核",
  "本地模型接入方案评估",
];

const inboxConversations = [
  "本周计划与待办",
  "模型服务配置想法",
  "整理零散产品笔记",
];

const screenCopy = {
  home: {
    title: "想从哪里继续？",
    suggestions: ["继续完善知识库导入", "复核自动记忆边界"],
  },
  inbox: {
    title: "收件箱里有什么？",
    suggestions: ["整理未归类对话", "开始一次快速记录"],
  },
  memories: {
    title: "哪些记忆值得保留？",
    suggestions: ["查看需要审核的记忆", "新建一条项目记忆"],
  },
  knowledge: {
    title: "想从资料里找什么？",
    suggestions: ["搜索本地知识库", "导入 Markdown 资料"],
  },
  settings: {
    title: "设置 Mira",
    suggestions: ["配置模型路线", "检查本地数据与隐私"],
  },
};

function IconButton({ label, children, className = "", ...props }) {
  return (
    <button className={`icon-button ${className}`} aria-label={label} title={label} {...props}>
      {children}
    </button>
  );
}

function MiraMark() {
  return (
    <div className="mira-mark" aria-hidden="true">
      <Cloud size={48} weight="light" />
    </div>
  );
}

function Menu({ label, icon, value, options, open, onToggle, onSelect, align = "left" }) {
  return (
    <div className={`menu-wrap menu-${align}`}>
      <button className="menu-trigger" onClick={onToggle} aria-expanded={open}>
        {icon}
        <span>{value || label}</span>
        <CaretDown size={13} weight="bold" />
      </button>
      {open ? (
        <div className="popover" role="menu">
          {options.map((option) => (
            <button
              key={option}
              className="popover-item"
              role="menuitem"
              onClick={() => onSelect(option)}
            >
              <span>{option}</span>
              {option === value ? <Check size={15} weight="bold" /> : null}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

export function App() {
  const [screen, setScreen] = useState("home");
  const [workspace, setWorkspace] = useState("Mira 开发");
  const [conversation, setConversation] = useState(null);
  const [input, setInput] = useState("");
  const [permission, setPermission] = useState("每次询问");
  const [authorization, setAuthorization] = useState("仅发送已授权内容");
  const [route, setRoute] = useState("GPT-5.6 Sol");
  const [openMenu, setOpenMenu] = useState(null);
  const [attachment, setAttachment] = useState(null);
  const [searchOpen, setSearchOpen] = useState(false);
  const [sentMessage, setSentMessage] = useState("");
  const [isThinking, setIsThinking] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const textareaRef = useRef(null);

  const currentCopy = screenCopy[screen] || screenCopy.home;
  const activeScope = screen === "inbox" ? "收件箱" : workspace;

  useEffect(() => {
    const closeMenus = (event) => {
      if (!event.target.closest(".menu-wrap") && !event.target.closest(".attachment-wrap")) {
        setOpenMenu(null);
      }
    };
    window.addEventListener("pointerdown", closeMenus);
    return () => window.removeEventListener("pointerdown", closeMenus);
  }, []);

  const startNewConversation = () => {
    setScreen("home");
    setConversation(null);
    setSentMessage("");
    setInput("");
    setIsThinking(false);
    requestAnimationFrame(() => textareaRef.current?.focus());
  };

  const chooseScreen = (nextScreen) => {
    setScreen(nextScreen);
    setConversation(null);
    setSentMessage("");
  };

  const chooseSuggestion = (suggestion) => {
    setInput(suggestion);
    requestAnimationFrame(() => textareaRef.current?.focus());
  };

  const sendMessage = () => {
    const message = input.trim();
    if (!message) return;
    setConversation(message);
    setSentMessage(message);
    setInput("");
    setIsThinking(true);
    setOpenMenu(null);
    window.setTimeout(() => setIsThinking(false), 700);
  };

  const handleComposerKeyDown = (event) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      sendMessage();
    }
  };

  const navItems = [
    { id: "memories", label: "记忆", icon: <Brain size={18} /> },
    { id: "knowledge", label: "知识库", icon: <BookOpen size={18} /> },
  ];

  return (
    <main
      className={`app-shell ${sidebarCollapsed ? "sidebar-collapsed" : ""}`}
      onClick={() => searchOpen && setSearchOpen(false)}
    >
      <aside className="sidebar" aria-label="Mira 导航">
        <div className="window-toolbar">
          <div className="traffic-lights" aria-label="窗口控制">
            <Circle className="traffic red" size={13} weight="fill" />
            <Circle className="traffic yellow" size={13} weight="fill" />
            <Circle className="traffic green" size={13} weight="fill" />
          </div>
          <IconButton
            label="收起侧边栏"
            className="sidebar-toggle"
            onClick={() => setSidebarCollapsed(true)}
          >
            <SidebarSimple size={18} />
          </IconButton>
          <div className="history-controls">
            <ArrowLeft size={17} />
            <ArrowRight size={17} />
          </div>
        </div>

        <div className="brand-row">
          <button className="brand-button">
            <span>Mira</span>
            <CaretDown size={13} weight="bold" />
          </button>
          <div className="brand-actions">
            <IconButton label="搜索" onClick={(event) => { event.stopPropagation(); setSearchOpen(true); }}>
              <MagnifyingGlass size={19} />
            </IconButton>
          </div>
        </div>

        <nav className="primary-nav">
          <button className="nav-row new-chat" onClick={startNewConversation}>
            <NotePencil size={19} />
            <span>新对话</span>
          </button>
          <button
            className={`nav-row ${screen === "inbox" ? "active" : ""}`}
            onClick={() => chooseScreen("inbox")}
          >
            <Tray size={18} />
            <span>收件箱</span>
          </button>
          {screen === "inbox" ? (
            <div className="conversation-list inbox-conversation-list" aria-label="未归类对话">
              {inboxConversations.map((title) => (
                <button
                  key={title}
                  className={`conversation-row ${conversation === title ? "active" : ""}`}
                  onClick={() => {
                    setConversation(title);
                    setSentMessage(title);
                    setIsThinking(false);
                  }}
                >
                  <ChatCircleDots size={16} />
                  <span>{title}</span>
                </button>
              ))}
            </div>
          ) : null}
          {navItems.map((item) => (
            <button
              key={item.id}
              className={`nav-row ${screen === item.id && !conversation ? "active" : ""}`}
              onClick={() => chooseScreen(item.id)}
            >
              {item.icon}
              <span>{item.label}</span>
            </button>
          ))}
        </nav>

        <div className="sidebar-section">
          <div className="section-label">工作区</div>
          <div className="workspace-list">
            {workspaces.map((name) => (
              <div key={name}>
                <button
                  className={`workspace-row ${screen !== "inbox" && workspace === name ? "active" : ""}`}
                  onClick={() => {
                    setWorkspace(name);
                    setScreen("home");
                    setConversation(null);
                    setSentMessage("");
                  }}
                >
                  <Folder size={18} />
                  <span>{name}</span>
                </button>
                {screen !== "inbox" && name === workspace && name === "Mira 开发" ? (
                  <div className="conversation-list">
                    {conversations.slice(0, 2).map((title) => (
                      <button
                        key={title}
                        className={`conversation-row ${conversation === title ? "active" : ""}`}
                        onClick={() => {
                          setConversation(title);
                          setSentMessage(title);
                          setScreen("home");
                          setIsThinking(false);
                        }}
                      >
                        <ChatCircleDots size={16} />
                        <span>{title}</span>
                      </button>
                    ))}
                    <button className="show-more" onClick={() => { setConversation(conversations[2]); setSentMessage(conversations[2]); }}>
                      显示更多
                    </button>
                  </div>
                ) : null}
              </div>
            ))}
          </div>
        </div>

        <div className="sidebar-footer">
          <button className={`nav-row ${screen === "settings" ? "active" : ""}`} onClick={() => chooseScreen("settings")}>
            <GearSix size={18} />
            <span>设置</span>
          </button>
        </div>
      </aside>

      <section className="main-canvas" aria-live="polite">
        {sidebarCollapsed ? (
          <IconButton
            label="展开侧边栏"
            className="reopen-sidebar"
            onClick={() => setSidebarCollapsed(false)}
          >
            <SidebarSimple size={19} />
          </IconButton>
        ) : null}
        {conversation ? (
          <div className="conversation-view">
            <div className="conversation-header">
              <span>{conversation}</span>
            </div>
            <div className="message-stack">
              <div className="user-message">{sentMessage}</div>
              <div className="assistant-message">
                <div className="assistant-label"><Sparkle size={18} /> Mira</div>
                {isThinking ? (
                  <div className="thinking">正在结合 {activeScope} 的上下文…</div>
                ) : (
                  <p>我会先结合当前工作区、已确认记忆与本地资料梳理这件事，然后给出一个可以直接继续推进的答案。</p>
                )}
              </div>
            </div>
          </div>
        ) : (
          <div className="hero-state">
            <MiraMark />
            <h1>{currentCopy.title}</h1>
            <div className="suggestion-links">
              {currentCopy.suggestions.map((suggestion) => (
                <button key={suggestion} onClick={() => chooseSuggestion(suggestion)}>{suggestion}</button>
              ))}
            </div>
          </div>
        )}

        <div className="composer-zone">
          {attachment ? (
            <div className="context-hint">
              <FileText size={15} />
              <span>已附加 {attachment}</span>
              <button aria-label="移除附件" onClick={() => setAttachment(null)}><X size={13} /></button>
            </div>
          ) : (
            <div className="context-hint">
              {screen === "inbox" ? <Tray size={15} /> : <Folder size={15} />}
              <span>{screen === "inbox" ? "当前为未归类对话" : `已使用 ${workspace} 的项目上下文`}</span>
            </div>
          )}

          <div className="composer" data-testid="composer">
            <div className="composer-meta">
              <button className="meta-project" onClick={() => setOpenMenu(openMenu === "workspace" ? null : "workspace")}>
                {screen === "inbox" ? <Tray size={17} /> : <Folder size={17} />}
                <span>{activeScope}</span>
              </button>
              <div className="meta-divider" />
              <Menu
                label="授权范围"
                icon={<ShieldCheck size={17} />}
                value={authorization}
                options={["仅发送已授权内容", "仅使用本地内容", "发送前再次确认"]}
                open={openMenu === "authorization"}
                onToggle={(event) => { event.stopPropagation(); setOpenMenu(openMenu === "authorization" ? null : "authorization"); }}
                onSelect={(value) => { setAuthorization(value); setOpenMenu(null); }}
              />
              {openMenu === "workspace" ? (
                <div className="workspace-popover popover" role="menu">
                  {workspaces.map((name) => (
                    <button key={name} className="popover-item" onClick={() => {
                      setWorkspace(name);
                      setScreen("home");
                      setConversation(null);
                      setSentMessage("");
                      setOpenMenu(null);
                    }}>
                      <span>{name}</span>{name === workspace ? <Check size={15} weight="bold" /> : null}
                    </button>
                  ))}
                </div>
              ) : null}
            </div>

            <textarea
              ref={textareaRef}
              value={input}
              onChange={(event) => setInput(event.target.value)}
              onKeyDown={handleComposerKeyDown}
              placeholder="告诉 Mira 你想做什么…"
              aria-label="输入消息"
              rows={2}
            />

            <div className="composer-actions">
              <div className="action-group">
                <div className="attachment-wrap">
                  <IconButton
                    label="添加资料"
                    className="composer-icon"
                    onClick={(event) => { event.stopPropagation(); setOpenMenu(openMenu === "attachment" ? null : "attachment"); }}
                  >
                    <Plus size={22} />
                  </IconButton>
                  {openMenu === "attachment" ? (
                    <div className="popover attachment-popover" role="menu">
                      {["MVP.md", "产品需求总纲.md", "选择本地文件…"].map((item) => (
                        <button key={item} className="popover-item" role="menuitem" onClick={() => { setAttachment(item); setOpenMenu(null); }}>
                          <FileText size={15} /><span>{item}</span>
                        </button>
                      ))}
                    </div>
                  ) : null}
                </div>
                <Menu
                  label="授权策略"
                  icon={<ChatCircle size={17} />}
                  value={permission}
                  options={["每次询问", "始终询问", "本次允许"]}
                  open={openMenu === "permission"}
                  onToggle={(event) => { event.stopPropagation(); setOpenMenu(openMenu === "permission" ? null : "permission"); }}
                  onSelect={(value) => { setPermission(value); setOpenMenu(null); }}
                />
              </div>
              <div className="action-group action-group-right">
                <Menu
                  label="模型路线"
                  icon={<GitBranch size={17} />}
                  value={route}
                  options={["GPT-5.6 Sol", "GPT-5.6 Luna", "Qwen3 32B · 本地"]}
                  open={openMenu === "route"}
                  onToggle={(event) => { event.stopPropagation(); setOpenMenu(openMenu === "route" ? null : "route"); }}
                  onSelect={(value) => { setRoute(value); setOpenMenu(null); }}
                  align="right"
                />
                <IconButton label="语音输入" className="composer-icon" onClick={() => setInput((value) => value || "记录一段语音想法") }>
                  <Microphone size={20} />
                </IconButton>
                <button className="send-button" onClick={sendMessage} disabled={!input.trim()} aria-label="发送消息">
                  <ArrowUp size={20} weight="bold" />
                </button>
              </div>
            </div>
          </div>
        </div>

        {searchOpen ? (
          <div className="search-overlay" onClick={(event) => event.stopPropagation()}>
            <div className="search-box">
              <MagnifyingGlass size={20} />
              <input autoFocus placeholder="搜索对话、记忆与资料" aria-label="搜索 Mira" />
              <button onClick={() => setSearchOpen(false)} aria-label="关闭搜索"><X size={18} /></button>
            </div>
            <div className="search-results">
              <button onClick={() => { setConversation(conversations[0]); setSentMessage(conversations[0]); setSearchOpen(false); }}>完善知识库导入流程</button>
              <button onClick={() => { chooseScreen("memories"); setSearchOpen(false); }}>已确认的项目记忆</button>
            </div>
          </div>
        ) : null}
      </section>
    </main>
  );
}
