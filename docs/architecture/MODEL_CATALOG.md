# 模型资料目录

<!-- Chinese documentation follows the user's explicit language preference. -->

目录是来源明确的建议资料。实际连接、模型启用、会话选择及探测证据有自己的权威记录。目录缺项不能成为禁止使用官方新 ID 的理由。

## 来源与边界

Mira 使用 [models.dev](https://github.com/anomalyco/models.dev) 的受检子集。当前内置资料来自提交 `06501753deb2f85a4913efbc8b0b7837108bdacc`，包含 7 个区域／服务目录、445 个模型；每条记录保存 sourceURL、输入 SHA-256 和实际取得时间。展示分组为 OpenAI、Anthropic、Moonshot、Kimi Code、DeepSeek、OpenRouter；Moonshot 区域资料仍分别匹配。

`scripts/update_model_catalog.py` 从公共 API 形状的 JSON 生成内置资源；运行时 `ModelsDevCatalogNormalizer` 按同一边界规范化显式下载。上游 `api`、`npm`、header、body 或代码字段不成为请求目的地或执行权限。已审阅的服务端点、发现方式、协议实现和差异规则由模块提供。

`ProviderModelCatalog` 按选中调用规格的准确规范端点与 model ID 匹配。规范化只接受明确的主机／默认端口／路径规则，保留 DeepSeek `/v1` 别名。自定义代理、不同路径、同名模型或显示名不继承官方能力与价格。不同区域及 Kimi Code 分开；不共享凭据，不自动改区域。

## 数据内容与使用

`CatalogModelMetadata` 包含任务类型、上下文／最大输入／最大输出、模态、工具／结构化输出／推理声明、reasoning_options、可选基础模型关联、生命周期、来源与价格。没有通用模型描述或系统提示注入。推理 effort 是来源给出的开放值，未知语义控制必须等待实现，不能直接透传任意 JSON。

模型 ID 不参与前缀规则或型号枚举。比如 OpenAI 的协议建议取决于服务商定义及来源 `provider.shape`，不会通过 `gpt-*` 名称猜测。现有模型已选规格保持不变，目录的协议建议只帮助新配置。

来源中的零上限表示未知；embedding 的向量维数不能变为输出 token 限制。文字 Agent 要求有效文本调用规格，图片／音频／embedding 条目仍可见但不会凭名称变成文本模型。未知 ID 可以保存，缺少上下文窗口时在发送前明确提示。

新建配置先采用连接默认规格和准确目录资料，用户保存后形成独立模型配置。显式“更新模型资料”以整批事务刷新资料和缓存，保留用户 `.user` 覆盖，后续执行重新解析。来源优先级和冲突规则见[模型配置](AGENT_MODEL_CONFIGURATION.md)。未更新的内置目录、完整发现缓存和已保存配置都可离线读取。

## 参数、价格与探测

目录的 reasoning_options 只描述已实现的 toggle／effort／budget 控制，并与协议硬约束相交；空交集不扩大能力。用户预设保存部分覆盖，未选择的字段使用调用规格默认值。适配器再次验证协议语义，不能把无法编码的参数静默忽略。

价格只在准确模型和端点下使用，随执行路线冻结。当前估算支持美元每百万文本 token 的输入、输出和可确认缓存读取费率；不支持的计费维度、阶梯范围以外、缺失用量或缓存写入费率均返回未知。Kimi Code 会员配额不记录为零美元单价。目录更新不重算历史价格。

文本、工具和 JSON 探测由用户显式运行，使用准确冻结参数，不为了短测试关闭 thinking。探测保存带配置 fingerprint 的观察事实，网络错误不能证明模型不支持；通过某个合成请求也不代表所有用途均已验证。探测不覆盖目录／服务商声明或用户上限。

## 缓存与扩展

公共源请求最大 16 MiB，规范文档最大 8 MiB；目录最大 32 个服务、每个服务 2000 个模型。缓存含准确 schema 和修订，与所有模型资料更新一起 CAS 提交。失败不清空旧资料；远程文档不能携带用户密钥或私有模型 ID。

同一协议的新服务可复用协议实现并增加明确服务定义、差异配置及资料；不同协议通过独立适配器接入。Google 原生和 iOS 尚未实现，不以空模块宣称支持。执行证据见[实施记录](../engineering/BYOK_MODEL_LAYER_VERIFICATION.md)。
