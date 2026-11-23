# StylePolish 邀请码中转

邀请码额度中转服务，和 macOS 客户端独立安装。Python 3.11+，uv 管理；运行依赖只有 Starlette、httpx、uvicorn（及其传递依赖），SQLite 和测试使用标准库。入口使用 `/v1/chat/completions`。

本次只交付代码和假上游测试。部署、反向代理与对外开端口需要部署者自行配置；上线前请先核对上游账户额度。以下启动命令供之后的部署使用。

## 配置与启动

在 Linux 安装 Python 3.11+ 和 [uv](https://docs.astral.sh/uv/getting-started/installation/)，进入仓库的 `relay/`：

```sh
uv sync --frozen
cp config.example.toml config.toml
# 编辑 config.toml，填入实际账单单价、模型、tier 和密钥来源
uv run --frozen stylepolish-relay --config config.toml serve
```

默认只监听 `127.0.0.1:8787`。监听地址和端口由 `host`、`port` 配置；没有启动时的公网默认值。请用上面的 CLI 启动以保留日志隐私设置；不直接用 `uvicorn` 导入模块或开 debug/access 日志。无自动重试，不会因网络错误再发一次收费请求。

`database` 相对**运行时工作目录**解析（建议部署时改为绝对路径）。数据目录默认新建为 700，数据库为 600。所有实例必须使用同一个本地 SQLite 文件和一致的额度/单价配置；不要放在网络共享文件系统。配置修改后重启生效，不自动追改历史金额。

Key 优先从 `key_env` 指定的环境变量读取；未设置时，从 `vault_path` 指定的 ai-vault JSON 里寻找唯一的 `vault_key`，读取该项的 `value`。例如结构为 `{"personal-infra":{"openai":{"YOUR_KEY_NAME":{"value":"…"}}}}`，`vault_key` 填 `YOUR_KEY_NAME`。路径、环境变量名和 Key 名均可改。实际 vault 文件请设为 600；不要把 Key 写进配置、命令参数或仓库。服务启动时才加载 Key；发码、看账等管理操作完全不读 Key。测试只用临时 fake Key，不读本机 vault。

`[prices]` 的 `input`、`cached_input`、`output` 分别是**每百万输入、缓存输入、输出 token 的美元价**，最多六位小数。**必须按所选模型、实际使用的 service tier 和实际账单填写**；示例故意使用不可启动的占位字符串，程序没有隐藏的默认价格。输入/输出单价必须大于零，缓存输入可为零。未配置有效单价时服务拒绝启动。上游实际 tier、模型计价或额外收费变化时，先核对账单再调整，不能把本地账本当作上游账户的总账。

| 配置 | 默认值 | 含义 |
| --- | --- | --- |
| `invite_usd` | `"3"` | 新码的终身美元额度（不会每月恢复） |
| `monthly_usd` | `"30"` | 全部码在一个 UTC 月份的合计上限 |
| `requests_per_minute` | `20` | 每码滚动 60 秒内最多接纳次数，跨设备共用 |
| `input_chars` | `2000` | 所有 user 消息的原文字符数合计（Unicode code point） |
| `body_bytes` | `65536` | 整个 JSON 请求的字节上限，覆盖系统提示词等 |
| `output_tokens` | `2048` | 单次最大输出 token；客户端更小的值优先 |
| `response_bytes` | `2097152` | 单次上游响应字节上限 |
| `upstream_timeout` | `90` | 上游请求总时限，含客户端断开后的读取 |

服务会覆盖客户端 `model`、`service_tier`，强制 `store: false`、流式 `include_usage: true`，并约束输出上限。保持普通文本 chat/completions 的消息结构及 `response_format`、`reasoning_effort`、采样参数等选项。只支持 text 消息、`n=1`；不支持工具、图片、音频、文件、远端 URL、客户端 metadata/user 等扩展，避免额外计费和持久化渠道。完整支持字段见 `protocol.py` 的 `allowed`。`max_tokens` 兼容输入后转换成 `max_completion_tokens`，两者不能同时传。

## 发码、作废、看用量

以下命令都在 `relay/` 内执行，使用同一配置和数据库：

```sh
uv run --frozen stylepolish-relay --config config.toml create --note '发给测试朋友'
# 可覆盖这个码的终身额度：create --budget-usd 3 --note '测试'
uv run --frozen stylepolish-relay --config config.toml revoke SP-XXXX-XXXX
uv run --frozen stylepolish-relay --config config.toml usage
uv run --frozen stylepolish-relay --config config.toml month
```

`create` 返回形如 `{"code":"SP-ABCD-EFGH"}` 的随机码，去掉 0/O/1/I。邀请码就是访问凭据，请私下发放。备注可选，勿填正文、Key 或不必要的个人资料。`revoke` 立即阻止该码的新请求，正在执行的请求仍须结算。输出为 JSON，方便人工查看或脚本处理，不做网页后台。

`usage` 显示每码备注、预算、累计美元花费、prompt/cached/output token、次数及 `pending` / `estimated`。`month` 显示当前 UTC 月份、总额、封顶值及未完成/估算笔数。金额包含预留和估算额，token 总数也可能含保守上界；不能把估算当成上游实际 usage。缓存 token 是 prompt 的子集，不重复加价：

```
花费 = (prompt - cached) × 输入价 / 1,000,000
     + cached × 缓存输入价 / 1,000,000
     + completion × 输出价 / 1,000,000
```

金额用整数 picodollar（10^-12 美元）存储，避免浮点累积。单价支持六位小数，美元预算支持十二位小数。

## 接口

两个接口都要求：

```
Authorization: Bearer SP-XXXX-XXXX
X-StylePolish-Device: <本地持久保存的 UUID>
```

- `POST /v1/chat/completions`：成功时透传上游 JSON 字节或 SSE 事件字节（含 usage），响应不缓存；不透传上游身份、Cookie 等响应头。流正常结束于 `[DONE]`，不等待上游继续保持的连接。
- `GET /v1/invite`：`200 {"status":"active","remaining_percent":92}`，只返回状态和整数百分比，不返回金额。状态含 `active` / `exhausted` / `revoked`。已知作废码在这个查询返回 `revoked`，发请求则返回 `invite_invalid`；不存在的码返回 401。

| HTTP | `error.code` |
| --- | --- |
| 401 | `invite_invalid`（含缺失凭据、缺失/无效设备 UUID） |
| 403 | `invite_exhausted` |
| 403 | `monthly_cap_reached` |
| 429 | `rate_limited` |
| 413 | `input_too_long` |
| 502 | `upstream_error` |
| 400 | `invalid_request`（补充：坏 JSON、不支持的输入结构/扩展参数） |

错误统一为 `{"error":{"code":"…","message":"固定安全文案"}}`。校验顺序为有效码 → 码余额 → 月余额 → 限速 → 请求结构/长度；发出请求前在同一写事务内再次检查余额与限速并预留。流式 HTTP 200 已发出后无法改状态码；之后的上游失败以 `data: {"error":…}` SSE 事件报告，不转发含私密信息的原始异常，不伪造成功 `[DONE]`。

## 额度、断开与月初的口径

SQLite `BEGIN IMMEDIATE` 将校验和预留作为一个原子操作；正在执行的请求也占用额度，多个进程不能同时花掉同一份余额。预留使用“出站 JSON UTF-8 字节数 + 4096 + 每条消息 64”的保守输入 token 上界，以及允许的最大输出 token；输入按输入/缓存价的较高者预留。这个上界针对普通字节分词的文本接口，不是实际 tokenizer 或供应商账单保证；更换 provider/模型或引入额外收费能力前必须重新确认。

- 收到实际 usage 后，按真实 prompt/cached/completion token 和配置单价结算，多余预留释放。恰好用尽额度的最后一次请求正常返回，下一次被拒绝。
- 有余额但不足一整次保守预留时，也会返回 `invite_exhausted` / `monthly_cap_reached`。此时 GET 仍可能显示 `active` 和剩余百分比；低于 1% 的正余额向下取整可能显示 0%。缩小客户端输出上限可减少预留。服务不会越过额度“试一下”。
- 客户端断开时继续读取已经发出的上游请求，直到拿到 usage/结束或达到总时限。断开不会触发第二次请求。正常关闭服务会等待这类读取结束。
- 上游 HTTP 明确拒绝（非 2xx）按零 token/零费用结算；连接异常、缺失 usage、进程崩溃等无法确认最终花费时，不自动退还预留。已处理的不确定请求标 `estimated`；崩溃时未结算的保留 `reserved`，CLI 显示为 `pending`。必须结合账单人工核实，**不提供自动释放或重试命令**。
- [OpenAI 官方说明](https://developers.openai.com/api/reference/resources/chat)指出，流中断时可能收不到最后的 usage。因此不能声称每种断网都能获得精确 token，估算会偏保守。
- 月封顶按**请求接纳时间所属的 UTC 月份**记账，跨月流仍记原月，月初新请求自动用新月额度；每码终身额度不重置。这是服务账本口径，可能和供应商账单时区/入账时间不同。
- 只控制经过本服务的调用。其他程序共用 Key 的费用、税费、供应商附加费和错误定价不在此封顶内。首次上线前应在上游设置独立硬额度，并核对模型/tier 的真实账单。

## 隐私

文字会经过部署者配置的中转服务器，再发送到所配置的上游。请求和响应只在有大小/时间上限的内存里经过，**中转不把正文落盘**，不写正文日志，不存 IP 明文，不读取客户端本地文件。

SQLite 仅保存生成的邀请码、可选管理备注和额度/作废设置，以及每次已接纳调用的设备 UUID SHA-256 哈希、UTC 时间/月、token 数、美元花费、固定状态码和记账状态。设备 UUID 规范化后再哈希，不保存原 UUID。服务日志只有固定的结算状态，不包含 Key、请求/响应体、设备标识、IP 或原始上游错误。启动 CLI 关闭 access 和 httpx/httpcore 日志。

这些保证覆盖本服务；部署者还需避免反向代理、系统请求体调试、崩溃转储或 swap 把正文写盘。`store: false` 不能替代上游自身的数据政策。备份 SQLite 也包含邀请码和管理备注，应按私密文件保护。

## 离线验证

```sh
uv run --frozen python -m unittest discover -s tests -v
uv build
```

测试使用临时数据库、fake Key、httpx 假上游和本机 `127.0.0.1` 假上游；不读取真实 Key、不调用真实 OpenAI。其中一个测试启动两个临时 loopback uvicorn 实例，验证真实 HTTP/SSE 客户端断开后仍能结算，结束后全部关闭。并发用多个独立 SQLite 连接测试；内存 HTTP 测试还阻止 socket connect，防止意外绕过假 transport。

覆盖六种约定错误、结构错误、输入/输出限制、缓存定价、最后一次额度恰好用完、并发每码/月封顶、UTC 月初与跨月结算、限速、重启保留预留、流式字节转发/断开/超时/usage 缺失，以及日志/数据库里不含正文、Key、原设备 UUID 或 IP。实测范围和结果见对应 PR。
