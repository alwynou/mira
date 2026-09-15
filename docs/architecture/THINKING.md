# Thinking 与协议续接

<!-- Chinese documentation follows the user's explicit language preference. -->

Thinking 是模型输出的一等内容。用户可见的思考文本和协议必需的隐藏续接分别保存，不互相推导。相关契约：[模型配置](AGENT_MODEL_CONFIGURATION.md)、[HTTP 适配器](AGENT_HTTP_ADAPTER.md)。

## 通用输出

`AgentModelMessage`、`AgentModelOutput` 使用有序 `AgentModelBlock`：text、thinking、toolCall、toolResult。每块具有稳定 ID；流事件依次启动、追加和结束指定块，终态前必须完成所有块。核心验证有界大小、唯一块／工具 ID、角色和工具配对，不将输出压成单个 text + thinking 对象。

`AgentModelContinuation` 独立于可见块，包含适配器身份、格式、不透明 payload 和完整性。它可以与零可见 thinking 甚至零可见块共存。加密状态、签名和 redacted 内容不显示成思考文本，也不据此编造模型推理。

目录未声明 thinking 不妨碍保留服务商实际返回的 thinking。能力资料用于配置和用途选择，不能用关闭思考或丢弃输出来掩盖未完成的协议支持。工具提案仍受能力、schema、来源和副作用权限校验。

## 参数与协议

模式、effort、budget 位于 MiraProviders；核心只冻结模块配置。协议与差异规则分离，Anthropic manual／adaptive 属于参数模式。effort 是有界开放值，来自具体模型资料；客户端只展示并编码当前已实现的语义控制，互斥或无效组合在请求前失败。

| 协议／差异规则 | 隐藏续接格式与边界 |
|---|---|
| Chat 的 DeepSeek／Kimi | `openai.content`，完整 `reasoning_content` 和工具往返；不能遗漏中间 assistant 推理 |
| Chat 的 OpenRouter | `openrouter.details`，原始有序 reasoning_details；加密片段保留原值 |
| Anthropic Messages | `anthropic.blocks`，完整有序 assistant content，包括签名、redacted、text 和 tool_use |
| OpenAI Responses | `openai.responses.items`，有序 output items 与加密 reasoning；`store:false`，本地历史负责续接 |

普通 Chat 文本、协议错误、usage、EOF 和取消同样受独立适配器测试。新增协议必须同时实现请求、流、工具往返和历史回放，不能只添加一个下拉项。

## 历史与来源

Live presentation carries an explicit `SessionOutputPhase` independently of retained thinking text. The most recently updated visible block selects thinking, answering, or tool-call preparation; finishing that block can return to waiting before the execution settles. Starting an answer therefore stops the thinking indicator even when a provider keeps its earlier thinking block open. These process-local observations do not change provider replay data or durable message bodies.

取消或进程中断的执行可以把仍获来源授权的可见回答正文带入后续回合（包括用户发送“继续”）；即使只中断在 thinking 阶段且没有可见回答，也保留原始用户消息和中性的“前一回复被中断且不完整”提示。该历史交换在核心读取结果中标记为 `isIncomplete`，持久的 assistant 消息正文保持原文。它不是成功 Assistant 输出，也不能携带 thinking、opaque continuation、tool call 或 tool result。读取器仍以执行日志和正文保留组为权威，重开后重新检查正文可用性、执行来源授权和隐私失效；任何撤权或清理都排除该交换。

同一执行中的工具循环使用完整冻结路线和请求前缀。每次派发仍检查路线授权、记忆与来源政策；失效就停止，不能修改签名前缀继续发送。

跨执行仅在准确协议／差异规则、模型配置实例、调用规格、连接、模型和端点匹配且历史仍合格时携带隐藏续接。换模型、连接或不兼容规格时保留可移植正文及完整工具配对，剥离 thinking 和隐藏材料。不同协议不尝试解码对方的 payload。

Anthropic 新用户回合会重新构建检索上下文，因此剥离已完成旧回合的 thinking；当前回合原始 signed assistant content 必须保持完整和原顺序，不能从可见文本重建。Responses 使用本地 output items 及准确 function_call_output 配对，隐藏状态不依赖远端保存的 response ID。

不完整和失败回合不成为成功历史。隐私或来源政策失效的历史及其依赖后代不再进入模型上下文；有可见文字不代表续接材料仍可发送。

## 持久化与隐私

请求、流草稿、输出和终态通过日志正文引用保存。可见正文／thinking 与隐藏重放使用不同保留组；thinking-only 中断可恢复。重启后只核对既有意图和结算，不擅自再次调用模型。

记忆遗忘清除相关请求／输出快照、隐藏工具数据、重放和草稿中的派生材料；已经提交的可见回答和思考可以保留本地展示及无正文的失效标签。知识来源撤销遵循其独立的生成正文清理契约。普通日志与错误不包含模型正文、密钥或隐藏续接。

Thinking 不是用户证据，记忆提取只验证最终回答中的严格 JSON，并记录整个调用的用量。显式合成探测保留真实配置和预算，不能通过关闭 thinking 获得虚假的通过结果。

## 协议资料与验收

- [DeepSeek Thinking](https://api-docs.deepseek.com/guides/thinking_mode/)
- [Kimi Chat](https://platform.kimi.ai/docs/api/chat)
- [Anthropic thinking tool workflows](https://platform.claude.com/docs/en/build-with-claude/thinking-tool-workflows)
- [OpenRouter reasoning](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)
- [OpenAI Responses reasoning](https://developers.openai.com/api/docs/guides/reasoning)

合成、原生及在线验证分别记录在[BYOK 实施记录](../engineering/BYOK_MODEL_LAYER_VERIFICATION.md)，不以编译通过或目录声明替代真实服务商验收。
