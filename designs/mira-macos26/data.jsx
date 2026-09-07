/* Mock content for the Mira prototype. Chinese primary (zh-CN). */

const WORKSPACES = [
  {
    id: "mira",
    name: "Mira 开发",
    hint: "产品设计与工程上下文",
    conversations: [
      { id: "c-arch", title: "梳理 Runtime 的并发所有权", meta: "今天 · 14 条", active: true },
      { id: "c-mem", title: "记忆提取的边界与默认关闭", meta: "今天 · 9 条" },
      { id: "c-stream", title: "流式响应中断后的恢复", meta: "昨天 · 22 条" },
    ],
  },
  {
    id: "writing",
    name: "写作与研究",
    hint: "长期研究、随笔与资料归档",
    conversations: [
      { id: "c-local", title: "本地优先产品的护城河", meta: "昨天 · 6 条" },
      { id: "c-notes", title: "把读书笔记整理成提纲", meta: "9 月 4 日 · 11 条" },
    ],
  },
  {
    id: "life",
    name: "个人事务",
    hint: "计划、清单与日常安排",
    conversations: [
      { id: "c-trip", title: "十月初的旅行行程草稿", meta: "9 月 3 日 · 5 条" },
    ],
  },
];

const INBOX = [
  { id: "i-1", title: "关于订阅制定价的随手记录", meta: "今天 · 3 条", unassigned: true },
  { id: "i-2", title: "想到的一个命令面板交互", meta: "昨天 · 2 条", unassigned: true },
  { id: "i-3", title: "还没归类的几个灵感", meta: "9 月 2 日 · 4 条", unassigned: true },
];

/* One rich conversation demonstrating the full execution pipeline. */
const THREAD = [
  {
    role: "user",
    text: "帮我梳理一下 Mira Runtime 的并发所有权：哪些状态归 MainActor，哪些属于后台执行？给出一条清晰的边界。",
    time: "14:31",
  },
  {
    role: "assistant",
    time: "14:31",
    context: {
      sources: [
        { label: "架构总览 · RUNTIME.md", kind: "knowledge" },
        { label: "记忆：核心继续使用 Swift 6 严格并发", kind: "memory" },
        { label: "当前对话 · 前 6 轮", kind: "conversation" },
      ],
      tokens: "3,120 / 32k",
      model: "Claude Sonnet 5",
    },
    thinking:
      "先区分 UI 呈现状态与长时执行。呈现模型应在 MainActor；执行（provider 请求、工具循环、流式解析）属于应用运行时，不应绑定视图生命周期。需要强调一个对话至多一个活跃执行，并在 SQLite 层用终态唯一性约束保证原子性。",
    tools: [
      { name: "search_knowledge", arg: "并发 所有权 runtime", result: "命中 RUNTIME.md 的 3 个片段", state: "done" },
      { name: "read_memory", arg: "scope:Mira 开发", result: "1 条相关决策", state: "done" },
    ],
    blocks: [
      { type: "p", text: "可以用一条边界来记：**呈现归 MainActor，执行归运行时**。" },
      {
        type: "list",
        items: [
          "**MainActor（呈现层）**：`@MainActor` 的 presentation model 持有 UI 状态——选中项、草稿、流式增量的渲染缓冲、可见的执行状态标签。视图只读这些值。",
          "**应用运行时（后台）**：provider 请求、工具循环、流式解析、记忆提取都属于运行时；它们的生命周期独立于任何视图 task。",
          "**持久化边界**：用户消息与排队的执行必须原子写入；在 SQLite 用「每个对话至多一个活跃执行」的唯一约束兜底。",
        ],
      },
      { type: "p", text: "换句话说，视图被销毁不能中断一次执行；执行只把结果发布回 MainActor 的呈现模型。相关依据见 RUNTIME.md 的所有权小节 [1] 与并发约束 [2]。" },
    ],
    citations: [
      { n: 1, source: "RUNTIME.md · 所有权", quote: "长时执行属于应用运行时，不属于视图 task。" },
      { n: 2, source: "RUNTIME.md · 约束", quote: "每个对话在 SQLite 中至多存在一个活跃执行。" },
    ],
    memory: { kind: "决策", title: "呈现归 MainActor，执行归运行时", scope: "Mira 开发", state: "candidate" },
  },
];

const MEMORIES = [
  {
    id: "m1", status: "active", kind: "决策",
    title: "呈现归 MainActor，执行归运行时",
    body: "UI 呈现状态由 @MainActor 的 presentation model 持有；provider 请求、工具循环与流式解析属于应用运行时，生命周期独立于视图。",
    scope: "Mira 开发", updated: "今天 14:32",
    origin: "对话：梳理 Runtime 的并发所有权",
    evidence: "长时执行属于应用运行时，不属于视图 task。",
    revisions: 1, allowRemote: true,
  },
  {
    id: "m2", status: "active", kind: "偏好",
    title: "界面保持克制的原生质感",
    body: "以黑白灰与细线建立层级，采用 macOS 原生材质与微弱半透明，不使用大面积强调色与装饰。",
    scope: "全局", updated: "昨天 19:08",
    origin: "对话：设计极简项目原型",
    evidence: "克制、原生、黑白灰为主。",
    revisions: 2, allowRemote: true,
  },
  {
    id: "m3", status: "candidate", kind: "约束",
    title: "MVP 暂不加入云端同步后端",
    body: "首个版本优先验证本地工作流，云同步与后台服务不进入当前里程碑。",
    scope: "Mira 开发", updated: "今天 11:20",
    origin: "自动提取：流式响应恢复",
    evidence: "当前阶段不要扩大到同步和后台服务。",
    revisions: 1, allowRemote: false,
  },
  {
    id: "m4", status: "candidate", kind: "偏好",
    title: "自动记忆默认需要确认",
    body: "新的长期记忆先进入候选列表，用户确认后再生效；敏感条目默认仅本地。",
    scope: "全局", updated: "今天 09:15",
    origin: "自动提取：记忆边界讨论",
    evidence: "不要悄悄记住，最好先让我确认。",
    revisions: 1, allowRemote: false,
  },
  {
    id: "m5", status: "active", kind: "事实",
    title: "本机验证环境为 Apple Silicon / Xcode 26.6",
    body: "本地开发在 Apple Silicon 上验证；CI 固定 Xcode 26.3，目标 macOS 15+。",
    scope: "Mira 开发", updated: "9 月 5 日",
    origin: "对话：本机开发包验证",
    evidence: "本机已验证 Xcode 26.6 / Apple Silicon。",
    revisions: 3, allowRemote: true,
  },
  {
    id: "m6", status: "archived", kind: "偏好",
    title: "旧：优先支持插件系统",
    body: "早期设想优先做插件扩展，后续调整为先打磨核心工作流。",
    scope: "Mira 开发", updated: "8 月 28 日",
    origin: "对话：早期路线讨论",
    evidence: "先把核心跑通，再谈扩展。",
    revisions: 1, allowRemote: false,
  },
];

const KNOWLEDGE = [
  {
    id: "k1", title: "ARCHITECTURE.md", kind: "架构总览",
    meta: "12 个片段 · v4", size: "31 KB", allowRemote: true, updated: "今天 10:40",
    versions: 4, chunks: 12,
    preview: "系统结构、模块依赖、架构不变量与并发所有权。MiraCore 仅依赖 Foundation，拥有领域值、用例、运行时与 ports……",
  },
  {
    id: "k2", title: "RUNTIME.md", kind: "技术设计",
    meta: "9 个片段 · v2", size: "18 KB", allowRemote: true, updated: "今天 10:41",
    versions: 2, chunks: 9,
    preview: "对话运行时、执行状态机、流式解析与工具循环。长时执行属于应用运行时，不属于视图 task……",
  },
  {
    id: "k3", title: "MEMORY_AND_KNOWLEDGE.md", kind: "领域模型",
    meta: "14 个片段 · v3", size: "26 KB", allowRemote: false, updated: "昨天 21:03",
    versions: 3, chunks: 14,
    preview: "记忆与知识的领域模型与处理管线：候选、审阅、纠正、遗忘；检索、摘要与索引的派生关系……",
  },
  {
    id: "k4", title: "本地优先产品调研.md", kind: "研究笔记",
    meta: "导入中 · 62%", size: "44 KB", importing: 0.62, allowRemote: false, updated: "刚刚",
    versions: 1, chunks: 0,
    preview: "",
  },
];

const TASKS = [
  {
    id: "t1", title: "为 Runtime 契约补一份并发所有权图", done: false,
    workspace: "Mira 开发", note: "把 MainActor / 运行时边界画成一张图，附到 RUNTIME.md。",
    reminder: { at: "今天 18:00", state: "scheduled" }, origin: "对话：梳理 Runtime 的并发所有权",
  },
  {
    id: "t2", title: "回顾候选记忆并清理过期项", done: false,
    workspace: "Mira 开发", note: "确认 2 条候选，归档 1 条过期偏好。",
    reminder: { at: "明天 09:30", state: "scheduled" }, origin: "手动创建",
  },
  {
    id: "t3", title: "整理十月旅行的备选行程", done: false,
    workspace: "个人事务", note: "对比两条路线，确定订票时间。",
    reminder: { at: "9 月 12 日 20:00", state: "pending" }, origin: "对话：旅行行程草稿",
  },
  {
    id: "t4", title: "导出上周的知识库备份", done: true,
    workspace: "Mira 开发", note: "已生成目录 bundle 与校验清单。",
    reminder: { at: "9 月 5 日 22:00", state: "delivered" }, origin: "手动创建",
  },
  {
    id: "t5", title: "给命令面板写一版交互稿", done: false,
    workspace: "收件箱", note: "⌘K 全局搜索 + 快捷动作的草图。",
    reminder: null, origin: "收件箱：命令面板交互",
  },
];

const PROVIDERS = [
  { id: "anthropic", name: "Anthropic", endpoint: "api.anthropic.com", active: true, models: 3, key: true },
  { id: "openai", name: "OpenAI", endpoint: "api.openai.com/v1", active: true, models: 2, key: true },
  { id: "local", name: "本地兼容端点", endpoint: "127.0.0.1:1234/v1", active: false, models: 4, key: false },
];

const MODEL_POOL = [
  { id: "sonnet5", name: "Claude Sonnet 5", provider: "Anthropic", ctx: "200k", caps: ["工具", "思考"], on: true },
  { id: "opus48", name: "Claude Opus 4.8", provider: "Anthropic", ctx: "200k", caps: ["工具", "思考"], on: true },
  { id: "gpt56", name: "GPT-5.6", provider: "OpenAI", ctx: "128k", caps: ["工具"], on: true },
  { id: "haiku45", name: "Claude Haiku 4.5", provider: "Anthropic", ctx: "200k", caps: ["工具"], on: false },
];

const PURPOSES = [
  { id: "chat", label: "对话默认", model: "Claude Sonnet 5" },
  { id: "memory", label: "记忆提取", model: "未设置", warn: true },
  { id: "title", label: "对话标题", model: "Claude Haiku 4.5" },
];

Object.assign(window, {
  WORKSPACES, INBOX, THREAD, MEMORIES, KNOWLEDGE, TASKS,
  PROVIDERS, MODEL_POOL, PURPOSES,
});
