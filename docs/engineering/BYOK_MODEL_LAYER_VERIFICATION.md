# BYOK 模型层重设计验收

<!-- Chinese documentation follows the user's explicit language preference. -->

日期：2026-09-14。分支：`codex/agent-core`。状态：**批准实现范围完成，完整回归和本机原生检查通过**。依据：[批准方案](../architecture/BYOK_MODEL_LAYER_PROPOSAL.md)与[实施计划](BYOK_MODEL_LAYER_PLAN.md)。这不是所有真实服务商、所有参数组合或发布质量的完成声明。

## 交付与架构边界

- `MiraCore` 保持仅依赖 Foundation。连接端点、模型引用、多调用规格、字段事实、授权修订、执行快照与会话选择属于核心；凭据、HTTP 和界面由外层提供。
- 模型逻辑身份为 `connectionID + modelID`。不增加独立 Offering 层；本地配置 UUID 表示一次配置的生命周期，防止删除后同名重建使旧选择重新有效。
- `/models` 返回的新 ID 可直接展示、保存和加入模型池，不要求内置目录认识该 ID，也不要求付费探测。缺少上下文上限时允许保存，派发前指出具体缺项；不能执行的媒体类型不伪装为文字 Agent。
- 协议、服务商差异、模型控制和预设分开；已接入 Chat Completions、Anthropic Messages、OpenAI Responses 的当前文字／工具范围。已知服务商自动采用定义中的协议，自定义连接只配置必要格式。
- 元数据保留字段来源和修订，精确关联实际端点。优先级为用户、服务商、公共目录、模块默认；资料不会重写目的地址、认证或协议。更新资料不撤销正在执行的冻结路线，删除／禁用及端点授权变化仍阻止后续派发。
- 会话显式选择和恢复继承写入日志；首次选择、消息及接纳遵守原子批次。失效选择保持失效，不隐式改用默认模型。
- 输出为有序 text／thinking／tool 块，隐藏续接独立存在；流、草稿、历史、工具往返、归档和隐私清理共同使用新契约。Thinking 不因目录缺少标记而被丢弃。
- 发现完整快照、公共资料缓存、CAS 更新、取消排空和库租约已接通。旧格式直接移除，没有迁移、旧解码器或兼容 API。

[核心架构与执行流程图](../architecture/BYOK_MODEL_LAYER_PROPOSAL.md)及[模型配置流程](../architecture/AGENT_MODEL_CONFIGURATION.md)均为中文 Mermaid 图，随契约维护。其余契约见[发现](../architecture/AGENT_MODEL_DISCOVERY.md)、[协议](../architecture/AGENT_HTTP_ADAPTER.md)、[Thinking](../architecture/THINKING.md)和[模型资料](../architecture/MODEL_CATALOG.md)。

## 最终自动化证据

环境为 macOS **26.6.2（25G83）**，Swift 6 严格并发；应用部署目标仍为 macOS 15。最终源码完成后运行以下检查：

| 检查 | 结果 | 本机证据 |
|---|---|---|
| `swift test --package-path Packages/MiraKit` | **1,040 项、147 套件通过** | `/tmp/mira-byok-package-final.log` |
| `MiraHostTests` scheme | **267 项通过，1 项跳过，0 失败** | `/tmp/mira-byok-host-final.log` 与下述 xcresult |
| 最终 Debug App 构建 | **BUILD SUCCEEDED** | `/tmp/mira-byok-app-final.log` |
| `xcodegen generate` | 成功，生成工程与配置一致 | 本次执行记录；生成工程无差异 |
| `python3 -m unittest discover -s scripts/tests -p test_model_catalog.py` | **11 项通过** | 本次执行记录 |
| `python3 scripts/check_language_policy.py` | **2,008 条双语资源通过** | 本次执行记录 |
| `git diff --check` | 通过 | 本次执行记录 |

宿主总数由四部分组成：MiraHostTests 的 Swift Testing 87 项、XCTest 20 项（含 1 项跳过），以及 MiraCompositionTests 的 Swift Testing 156 项、XCTest 5 项。唯一跳过项为未开启 `MIRA_RUN_LIVE_MEMORY_EVAL=1` 的真实账号评估，没有把它算为通过。

最终宿主结果：`.build/xcode/Logs/Test/Test-MiraHostTests-2026.09.14_12-54-03-+0800.xcresult`。构建和宿主命令均使用 `-configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO`，分别运行 `Mira` scheme 的 `build` 和 `MiraHostTests` scheme 的 `test`。

测试使用隔离临时库、合成传输和假凭据读取器，未调用付费模型端点。旧架构耦合用例直接改写，保留并验证以下行为：

- 多端点凭据隔离、密钥替换和清理、并发保存冲突、已接纳写入排空、关闭后的迟到结果不更新界面。
- 未知 ID、资料缺项、用户覆盖、同名不同连接、多个调用规格、部分预设、参数和预算硬边界。
- 显式选择失效不回退、删除后重建身份、选择与接纳原子性、日志重开和当前格式归档往返。
- 多 Thinking／正文块、隐藏续接、工具配对、截断／取消／恢复／隐私路径，以及 16 个真实子进程终止场景。
- Responses 工具输出顺序、延后的有序内容、refusal、加密 reasoning、incomplete、重复／非法终态、用量整数溢出、请求与流大小边界；Chat 和 Anthropic 的实际流与续接行为。
- 元数据完整快照与事务回滚、来源冲突、目标端点保护、超时／取消后资源关闭、非合作子操作排空，以及历史路线保持冻结。

整合中修复了探测错误包装丢失网络分类、用途筛选被单个不满足能力的模型中断、连接编辑混用发现协议与调用协议、预设错误复制整个默认参数、资料取消排空死锁和 Responses 有序流边界等真实问题。最终证据来自实际完整目标，未用删掉关键断言或仅测试构造函数代替行为验收。

## 原生界面检查

使用最终及本次整合构建，通过原生辅助功能和截图检查；截图工具最初的 ScreenCaptureKit 失败随后恢复，以下视觉结果均有实际画面观察，不以编译替代。

| 范围 | 实际结果 |
|---|---|
| 正常启动 | 最终构建从同路径空开发库创建当前格式，无旧 schema 错误；正常模式显示“先连接你自己的模型服务” |
| 服务商配置 | 内置服务商使用一个固定协议；自定义服务商可选协议。连接启用保存无需发送请求，手动测试独立 |
| 未知模型 | 使用 `.invalid` 合成连接保存陌生 ID，未填上下文仍可保存并加入模型池；填非法数字禁止保存，填 8,192 可保存 |
| 中文／英文、浅色／深色 | 原生检查文字、控件、换行和对比；发现的遗漏标签与错误文案已加入双语资源。最终中文服务商页截图复核通过 |
| 最小设置窗口 | 拖到最小窗口约 760 × 612（内容最小值 760 × 560 加系统窗口区），无控件重叠，纵向滚动可达；服务商卡片横向滚动 |
| 最终本机对话 | 显式 `--demo --demo-stress`，无网络、无凭据；观察 Thinking 展开、正文、代码、表格和第 24 节结束标记 |
| 取消与重开 | 第二回合点击“停止”，显示“已停止”和“未完成”正文；退出后以同演示库重开，停止状态与部分内容仍在，没有重复生成 |
| 清洁交付 | 演示库与本次合成凭据已清除，语言恢复简体中文、外观随系统；最终正常 App 已启动到模型服务设置 |

合成 `.invalid` 连接曾暴露探测错误被误报为存储失败；源码修复后，完整宿主中的真实服务回归已证明网络错误分类和临时资源清理正确。最终界面没有再次调用该地址，不将此修复描述为最终 UI 网络请求复验。发现取消、目录刷新与库切换的所有原生交叉组合未逐一执行；其服务和展示模型边界已有自动化覆盖。长回复“回到最新内容”按钮的一次观察未能确认跳转效果，手动滚动可达结尾；该阅读位置交互仍列为单独的原生验收项。

## 数据切换与清理

按用户既有授权，先停止 Mira，确认默认开发库只有本项目运行文件后，删除旧库并在 `~/Library/Application Support/Mira` 同路径重建，无备份、无旧格式读取桥。用户原有 Keychain 凭据没有清理。

本次原生设置检查创建的唯一合成连接和凭据经连接 UUID、`.invalid` 地址和凭据引用精确核对后删除；未读取或打印密钥值。开发库再次在原路径重建，最终正常应用已创建当前格式。最终对话检查使用 `/tmp/mira-byok-final-native-20260914` 独立演示库，退出进程并核对文件后删除，演示模块未读取或创建 Keychain 项。源码、设计资源和个人 Xcode 状态没有纳入清理。

## 资料来源与未验证范围

内置目录由 `models.dev` 固定源提交 `06501753deb2f85a4913efbc8b0b7837108bdacc` 生成，包含 **7 个服务商、445 个模型**，记录源 URL、获取时间 `2026-09-14T03:04:38Z` 和内容摘要。运行时资料只使用已审核服务商定义，远端地址、header 或 body 字段不是请求授权。

公共 `models.dev/api.json` 在本机获取曾返回 403；运行时在线刷新**尚无成功证据**。正常响应发布、失败保留缓存、原子更新和安全边界有合成测试。真实模型账号可用性、计费、所有部署参数及所有 Thinking 组合未在线验收；不能由固定资料或合成流推导这些结论。

macOS 15 实际运行、完整原生交互矩阵和发布性能验收仍待独立执行。Google 原生与 iOS 不在本次实现范围，也没有为它们添加空模块。以上未验证项不阻止本次批准的本机实现交付，但不得省略为“全部能力已实测”。
