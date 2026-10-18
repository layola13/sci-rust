# SA-ASM 外部插件系统 (External Plugin System)

> 当前状态：插件作为 `/home/vscode/projects/sa_plugins/sa_plugin_*` 下的独立 Zig 工程交付，通过 C-ABI 和 Linux `.so` 与 SA 宿主协作。主线 `sci` 应只保留薄宿主层、descriptor ABI、动态库发现、链接辅助和最小 grant 解析；插件业务逻辑不应回绑到编译器源码树。

## 1. 定位

SA 插件是 native capability extension，不是普通源码包，也不是语言本体。典型插件包括 Deno 兼容层、HTTP client/server、数据库、SAX、包管理、bc2sa、Node facade、TS lowering、VM interpreter、WGPU 和 3D engine sidecar。插件面向两类入口：

- **CLI/Agent 能力**：通过 `saasm_plugin_descriptor_v1.skills_ptr` 暴露给 `sa skills`，供 Agent 发现当前真实能力。
- **SA 业务代码 ABI**：通过 `.sai` / `.sal` 暴露 `@extern`、布局常量和宏 facade，供 `.sa` 源码 import。

当前外部工作区 `/home/vscode/projects/sa_plugins/` 中，`pkg`、`db`、`sax`、`http-client`、`http-server`、`bc2sa`、`node`、`vm`、`wgpu` 已有当前测试通过证据；`deno` 可构建但没有 test step；`ts` 插件当前 Debug 测试有 benchmark 阈值失败；`3dengines` 已拆成 24 个模块并有结构验证/部分模块测试证据，但 Bevy parity 仍是逐模块推进中的目标。

## 2. 一个合格插件必须包含什么

推荐目录：

```text
sa_plugin_<name>/
  sap.json
  build.zig
  src/plugin.zig
  src/plugin_api.zig
  src/<name>_saasm_api.zig
  <name>.sa
  <name>.sai
  <name>.sal
  API_COVERAGE.md
  tests/*-smoke.sh
```

硬性规则：

- `sap.json` 是插件工程清单，声明 canonical plugin id、版本、动态库产物、`.sa/.sai/.sal`、skills、permissions、依赖和 ABI 约束。
- `src/plugin.zig` 必须导出 `saasm_plugin_descriptor_v1`，并填写 ABI version、descriptor size、canonical identity、skills。
- 所有 SA 可调用 C-ABI 函数必须在 `<name>.sai` 中声明；不得只存在于测试目录或文档示例。
- `<name>.sal` 负责宏、布局、常量和 slot 装配；复杂对象用 opaque handle、JSON/bytes record 或 `poll/take/free` 模式表达。
- 每个 `@extern sa_<name>_*` 必须能在 `nm -D zig-out/lib/lib<name>.so` 中找到同名导出符号。
- 若插件目标是替代 Deno/Bun 这类 runtime，不允许 shell out 到被替代的 runtime；必须用 Zig/std/POSIX/native library 实现 replacement surface。

## 3. `sa.mod` 与 `sap.json` 的共同点和区别

SA 生态分两类 manifest：

- `sa.mod`：正常工程包 manifest，类似 Rust `Cargo.toml`/crate 的角色，但格式更极简。它管理源码包、项目依赖、源码 hash、包权限。
- `sap.json`：编译器/宿主插件 manifest。它管理 native `.so` 插件、`.sa/.sai/.sal` facade、descriptor skills、插件依赖和插件权限。

共同点：

| 能力 | `sa.mod` | `sap.json` |
| --- | --- | --- |
| 身份 | 包 URL/name、ref/version | 插件 name 或 namespace/name、version/source |
| 依赖 | `require` 源码包；可声明 `require_plugin` | `dependencies` 插件依赖 |
| 完整性 | 源码 `sha256`，写入 `sa.lock/sa.sum` | artifact/interface `sha256`，写入 `sap.lock` |
| 权限 | `permissions`，同一套 fs/net/env/process 词汇 | `permissions`，同一套 fs/net/env/process 词汇 |
| 默认策略 | deny-all | deny-all |
| 安装/获取 | 项目局部 `sa_vendor/` 优先 | 全局 `$SA_PLUGINS_HOME/installed/` 优先 |
| 审计 | 源码透明，可扫 `@sys_*` 和 import | native 不透明，依赖 manifest、symbol smoke 和 sandbox |

关键区别：

| 维度 | `sa.mod` 正常工程包 | `sap.json` 编译器/宿主插件 |
| --- | --- | --- |
| 产物 | `.sa/.sai/.sal` 源码 | `.so/.dylib/.dll` + `.sa/.sai/.sal` facade |
| 作用域 | 每个 SA 项目自己的业务依赖 | 编译器宿主能力和 native capability |
| 是否允许 native artifact | 默认不允许；源码包应透明 | 必须声明 native artifact |
| 权限意义 | 业务包请求什么系统能力 | 插件安装和运行可能触碰什么宿主能力 |
| 失败时机 | `sa fetch`/`sa build` 审计失败 | `sa plugin install`/宿主加载失败 |
| Agent 能力 | 不直接提供 `sa skills` | 通过 descriptor 提供 `sa skills` |

正常工程包如果需要某个 native 插件，不把插件源码塞进自己包里，而是在 `sa.mod` 里声明插件需求。例如：

```text
require github.com/acme/http_helpers @v0.2.0 sha256:...
require_plugin http-client @0.1.0 abi 1
require_plugin github.com/layol13/http-client @0.1.0 abi 1
```

插件身份规则：`require_plugin` 里的身份是 canonical plugin id。裸名如 `http-client`、`deno` 只表示 SA 官方顶级插件；第三方或组织插件必须带作者/组织命名空间，例如 `github.com/layol13/http-client`。同一个短名可以被不同 namespace 复用，但不能在同一 canonical id 下多源并存。编译时规则：`require_plugin` 只检查插件是否已安装、ABI 是否匹配、接口 hash 是否匹配。真正安装插件仍走 `sap.json` 和 `sa plugin install`。

`permissions` 词汇必须一致：同样的 `fs/net/env/process` 规则用于 `sa.mod` 和 `sap.json`。区别是 `sa.mod` 的权限可以对透明源码做静态审计；`sap.json` 的权限还必须交给 native sandbox/runtime enforcement。

统一安装入口：`sa install` 类似 `npm install`。它先读取 `sa.mod`，下载 `require` 源码包；再处理 `require_plugin`，定位插件 `sap.json` 并调用插件安装器。用户也可以直接运行 `sa plugin install <path|sap.json>` 只安装插件。

Deno-like `--allow-env`、`--allow-net`、`--allow-read`、`--allow-write` 可以作为运行/构建命令的用户授权上限，但不能替代 manifest：

```text
effective_permission = sa.mod/sap.json 声明 ∩ CLI --allow-* 授权
```

插件安装确认也不能被 `--allow-*` 跳过；安装 privileged 插件仍需要手动确认，只有 `--dev` 本地开发模式可跳过。

大型工程不能每个依赖都弹一次确认。安装器必须先生成完整 review plan，然后只对新增权限差异、native 插件、高风险权限做汇总确认。已写入 `sa.lock/sap.lock/permissions.lock` 且 hash/权限未变的依赖不再提示；CI 中禁止交互，必须依赖已提交 lock 或组织级 `sa.policy`。

新增外部 URL 必须严格确认。这里的 URL 包括插件 `sap.json.source.url`、插件依赖 URL、项目 `require` 源码包 URL、以及 `permissions.net[].url`。黑客最常见的绕过方式就是偷偷新增上传地址或替换依赖源；因此任何未在 lock/policy 中出现过的外部 URL 都必须进入人工 review，不能被 `-y` 或默认 yes 跳过。

## 4. `sap.json` 插件清单

插件可以依赖其他插件，因此必须有一个类似 `package.json` 的机器可读入口。推荐命名为 `sap.json`，含义是 **SA Plugin manifest**。它只描述 native plugin，不替代业务包的 `sa.mod`。

最小示例：

```json
{
  "schema": "sa.plugin/1",
  "name": "deno",
  "version": "0.1.0",
  "source": {
    "type": "git",
    "url": "https://github.com/sa-plugins/sa_plugin_deno.git",
    "rev": "..."
  },
  "abi": {
    "plugin": 1,
    "saasm": ">=0.4.0",
    "symbols": "deno.sai"
  },
  "artifacts": {
    "linux-x86_64": {
      "path": "zig-out/lib/libsa_plugin_deno.so",
      "sha256": "..."
    }
  },
  "interfaces": {
    "sa": [
      {
        "path": "deno.sars",
        "sha256": "..."
      }
    ],
    "sai": {
      "path": "deno.sai",
      "sha256": "..."
    },
    "sal": {
      "path": "deno.sal",
      "sha256": "..."
    }
  },
  "skills": ["deno.sys", "deno.env", "deno.fs"],
  "permissions": {
    "fs": [
      {
        "op": "read",
        "path": "$HOME/.config/sa/**"
      },
      {
        "op": "write",
        "path": "$SA_CACHE/**"
      }
    ],
    "net": [
      {
        "url": "https://api.example.com"
      },
      {
        "url": "http://localhost:8787"
      }
    ],
    "env": ["HOME", "SA_CACHE"],
    "process": {
      "spawn": false
    }
  },
  "dependencies": {
    "http-client": {
      "version": ">=0.1.0",
      "abi": 1,
      "optional": true,
      "symbols": ["sa_http_client_new"]
    }
  }
}
```

字段规则：

- `schema` 必须固定为当前主版本，例如 `sa.plugin/1`。宿主不认识主版本时必须拒绝加载。
- `name` 是插件短名，只能在自己的 namespace 内唯一。裸短名身份保留给 SA 官方顶级插件；非官方插件必须声明 `namespace`，例如 `github.com/layol13`、`github.com/acme` 或组织内网域名。canonical plugin id 为 `name`（官方顶级）或 `namespace/name`（第三方/组织），例如 `deno`、`http-client`、`github.com/layol13/deno`。
- `namespace` 缺省时必须被视为 SA 官方顶级空间；安装器不得让远程第三方插件以缺省 namespace 安装。namespace 必须是可追溯作者空间，优先使用 Git host URL 前缀或组织域名，不能是普通 display name。
- descriptor name、`sap.json.name`、安装目录和导出符号前缀要交叉核验。对于带 namespace 的插件，descriptor 可以暴露 canonical id 或 `{namespace, name}`，但不能只用短名参与唯一性判断，避免两个作者都发布 `deno` 时冲突。
- canonical plugin id 可能包含 `/`，例如 `github.com/layol13/http-client`。锁文件和权限确认文本必须保存原始 canonical id；文件系统安装目录必须使用可逆的 `<plugin-id-path>` 表示，可以是转义后的单目录名，也可以是受控的嵌套目录，但不能退化成短名。
- `source` 记录插件来源，可以是本地路径、Git URL、GitHub shorthand 或 release archive；远程来源必须固定 tag/commit/release digest，不能只信浮动分支。
- `abi.plugin` 对应 `saasm_plugin_descriptor_v1` 的 ABI version；`abi.saasm` 表示需要的宿主能力范围。
- `artifacts` 按 target triple 指向构建产物路径，当前 Linux 路径先落地 `.so`。正式安装不得下载或接收预编译二进制；artifact 必须由安装器从文本源工程构建出来。
- `interfaces.sa/sai/sal` 是 SA-facing native 入口；`.sa` 是可选 facade，实现用户可 import 的薄封装；`.sai/.sal` 是 ABI 与布局合约；native `.sai` 会参与 symbol smoke。
- `interfaces.wasm_imports` 用于 SAX/WASM browser sidecar 这类接口：文件会被复制到插件 `sa/` 目录供编译期使用，但其中的 `@extern` 是浏览器/WASM import，不要求 native `.so` 导出同名符号。
- `assets.share` 用于声明插件运行所需的静态 sidecar 文件，例如 browser airlock JS、demo 源文件或其他 share 资源；安装器复制到 `installed/<plugin-id-path>/current/share/`。
- `dependencies` 只声明插件依赖插件，不声明普通源码包。依赖 key 同样使用 canonical plugin id；依赖第三方插件时必须写完整 namespace，例如 `github.com/layol13/http-client`。普通业务依赖仍归 `sa.mod` / `sa.lock`。
- `permissions` 是插件整体可能使用的宿主能力声明。缺少权限声明却需要文件、网络、环境或进程能力的插件，安装器必须拒绝安装；真实阻断仍依赖宿主 sandbox/syscall 层补齐。
- `sha256` 是 artifact 和 interface 的完整性字段。不要用 MD5 做安全判断；MD5 已不适合作为防篡改哈希。若未来需要更快校验，可额外支持 `blake3`，但 `sha256` 仍应作为默认兼容字段。

### 4.1 `permissions` 格式规范

`permissions` 是 `sap.json` 和 `sa.mod` 的必填权限对象。缺省语义是 deny-all；如果插件或包完全不需要外部能力，也必须显式写空权限对象：

```json
{
  "permissions": {
    "fs": [],
    "net": [],
    "env": [],
    "process": {
      "spawn": false,
      "exec": []
    }
  }
}
```

完整格式：

```json
{
  "permissions": {
    "fs": [
      {
        "op": "read",
        "path": "$HOME/.config/sa/**"
      }
    ],
    "net": [
      {
        "url": "https://api.example.com",
        "methods": ["GET", "POST"]
      },
      {
        "url": "http://localhost:8787",
        "methods": ["GET"]
      }
    ],
    "env": ["HOME", "SA_CACHE", "SA_*"],
    "process": {
      "spawn": false,
      "exec": [
        {
          "path": "/usr/bin/git",
          "args": ["clone", "--depth", "1", "*"]
        }
      ]
    }
  }
}
```

字段规范：

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `fs` | array | `[]` | 文件系统权限列表。每项必须有 `op` 和 `path`。 |
| `fs[].op` | string | 无 | 只能是 `read`、`write`、`create`、`delete`、`metadata` 之一。 |
| `fs[].path` | string | 无 | 路径范围。允许 `$PROJECT`、`$HOME`、`$SA_CACHE`、`$SA_PLUGINS_HOME` 前缀；`/**` 只允许出现在明确目录末尾。 |
| `net` | array | `[]` | 出站网络权限列表。每项必须有 `url`。 |
| `net[].url` | string | 无 | 远程只允许 `https://host[:port][/prefix]`；本地只允许 `http://localhost[:port]`、`http://127.0.0.1[:port]`、`http://[::1][:port]`。 |
| `net[].methods` | array | `["GET"]` | 可选 HTTP 方法白名单；只能包含 `GET`、`POST`、`PUT`、`PATCH`、`DELETE`、`HEAD`、`OPTIONS`。 |
| `env` | array | `[]` | 允许读取的环境变量名或受限前缀，例如 `SA_*`。禁止 `"*"`。 |
| `process.spawn` | bool | `false` | 是否允许启动子进程。默认禁止。 |
| `process.exec` | array | `[]` | 允许执行的二进制和参数策略。只有 `spawn: true` 时才允许非空。 |
| `process.exec[].path` | string | 无 | 必须是绝对路径，不能只写命令名。 |
| `process.exec[].args` | array | `[]` | 参数模式；普通字符串精确匹配，单独的 `"*"` 表示该位置允许任意单个参数。 |

- `fs` 必须声明 `op` 和路径范围。`read`、`write`、`create`、`delete` 分开声明；禁止默认全盘访问。`/**` 只允许挂在明确目录后面，例如 `$SA_CACHE/**`。
- `net` 必须声明 URL。远程地址只允许 `https://`；本地开发只允许 `localhost`、`127.0.0.1` 或 `[::1]`。普通 `http://example.com`、裸 IP 远程地址、无 scheme 地址必须拒绝安装。
- `env` 必须列出变量名或受限前缀，例如 `SA_*`；禁止默认读取全部环境。
- `process.spawn` 默认 `false`。若为 `true`，必须额外声明允许执行的二进制路径和参数策略。
- 插件依赖不能继承权限。A 依赖 B 时，A 和 B 各自声明自己的 `permissions`；最终安装计划向用户展示合并后的权限账本。
- `permissions` 在 `sap.json` 中表示插件安装/运行权限；在 `sa.mod` 中表示业务包请求权限。两者都必须通过时，插件能力才可被业务代码使用。

安装器必须拒绝以下权限配置：

- 缺少 `permissions` 字段。
- `fs[].path` 是 `/`、`/**`、`~/**` 或未归一化路径。
- `fs[].path` 包含 `..` 路径穿越。
- `net[].url` 是远程 `http://`、`ws://`、`ftp://`、裸 host、裸 IP，或通配所有 host。
- `env` 包含 `"*"`。
- `process.spawn: true` 但没有 `process.exec` 明细。
- `process.exec[].path` 不是绝对路径。
- 任一字段出现未知类型或未知权限 key。未知 key 默认拒绝，不能忽略。

### 4.2 防作弊边界：manifest 不是 sandbox

`sap.json.permissions` 只能说明“插件声称需要什么能力”，不能单独阻止恶意 native 插件。只要插件 `.so` 被同进程 `dlopen`，它仍可能直接调用 OS syscall，例如声明只访问：

```json
"net": [
  { "url": "http://localhost", "methods": ["GET", "POST"] },
  { "url": "http://127.0.0.1", "methods": ["GET", "POST"] }
]
```

但实际偷偷 `connect()` 到第三方公网地址。安装器无法可靠静态证明 native 二进制没有作弊；反汇编、符号扫描、字符串扫描都只能作为风险提示，不能作为安全边界。

真正的强制模型必须是：

1. **插件隔离运行**：高风险 native 插件不能长期与编译器同进程运行。宿主应把插件放进 worker process，并启用 seccomp-bpf、Landlock、namespace/chroot 或平台等价机制。
2. **默认禁 syscall**：worker 默认禁止 `connect/open/execve/getenv` 等直接能力。插件如果直接调用未授权 syscall，应被内核策略杀掉或返回权限错误。
3. **能力走 broker**：网络、文件、环境、进程启动都通过宿主 broker API。插件不能自己联网，只能请求 broker 访问 URL；broker 根据 `sap.json.permissions` 和项目 `sa.mod.permissions` 做最终判断。
4. **网络由宿主解析和连接**：URL、method、host、scheme、port 必须由宿主解析。远程只允许 `https://...`；本地只允许 localhost/loopback。DNS 解析和 socket connect 由宿主完成，插件只拿到响应 handle/bytes。
5. **路径由宿主归一化**：文件访问先 canonicalize，拒绝 `..`、符号链接逃逸和越权前缀。
6. **权限账本可审计**：安装时生成 `permissions.lock`，记录插件权限、依赖插件权限、项目权限合并结果和 sandbox enforcement 状态。

当前实现状态：`sci` 的本地插件安装器能解析 `sap.json` 并做基础 manifest/URL 校验，宿主 runtime 也会在正式模式下阻断带权限需求的已安装插件，除非显式 `SA_PLUGIN_DEV=1`。但 native sandbox/broker enforcement 仍未完成，因此这还不是 syscall 级隔离；`permissions` 不能被当作已经能防恶意 `.so` 的完整运行时安全边界。

### 4.3 安装前 verifier hooks

安装前必须检查，但这些 hook 必须是宿主内置的 verifier hooks，不能是插件仓库自带的任意脚本。禁止 `preinstall.sh`、`postinstall.sh`、`npm scripts` 这类插件作者可执行钩子成为安装链路的一部分。

推荐 hook pipeline：

| Hook | 输入 | 必须检查 |
| --- | --- | --- |
| `manifest_schema` | `sap.json` | schema、name/version、artifact、interfaces、permissions、dependencies 字段类型和未知 key。 |
| `source_layout` | 插件工程目录 | 必须是工程目录或 `sap.json`；拒绝直接安装 `.so/.dll/.dylib`。 |
| `text_source_required` | 插件工程目录 | 必须存在 `build.zig`、`src/plugin.zig` 和声明的接口文本；正式安装禁止二进制-only 插件。 |
| `permission_policy` | `permissions` | fs/net/env/process 是否符合格式；远程 URL 是否 `https://`；localhost 是否 loopback；privileged 插件是否有 sandbox/broker。 |
| `interface_files` | `.sa/.sai/.sal` | manifest 声明的接口文件必须存在，hash 匹配，路径不能逃逸工程目录。 |
| `share_assets` | `assets.share` | manifest 声明的静态 sidecar 文件必须存在，hash 匹配，安装到插件 share 目录。 |
| `symbol_smoke` | native `.sai` + artifact | native `.sai` 中每个 `@extern` 必须有 `.so` 导出符号；`interfaces.wasm_imports` 不参与 native symbol smoke。 |
| `artifact_static_scan` | artifact | 检查动态导入和字符串风险，如 `connect/socket/getaddrinfo/open/execve/system/dlopen`；发现未声明能力或无 sandbox 时拒绝。 |
| `dependency_dag` | `sap.json.dependencies` | 依赖存在、ABI 主版本匹配、无环、权限账本可合并。 |
| `lock_emit` | 安装计划 | 生成 `sap.lock` / `permissions.lock`，记录 hash、权限、hook 结果、sandbox enforcement 状态。 |

静态 hook 的边界：

- 它能发现明显作弊，例如无 `net` 权限却导入 `connect` / `getaddrinfo`。
- 它不能证明二进制安全，因为插件可以静态链接、手写 syscall、运行时解密代码、通过其它库间接联网。
- 因此结论分两级：hook 是安装准入门槛；sandbox/broker 是运行时强制边界。当前 `sci` 已做到“没有 sandbox_enforced 时，privileged 已安装插件在 formal runtime mode 下不加载”；但这仍不等于真正的 syscall/broker 隔离。

依赖解析规则：

- 宿主或 plugin-manager 先读取所有候选 `sap.json`，按 `dependencies` 做 DAG 拓扑排序，再加载动态库。
- 必需依赖缺失、ABI 主版本不匹配、环形依赖、同 canonical plugin id 多版本/多来源并存时必须报结构化错误并拒绝加载。短名相同但 namespace 不同的插件可以并存，前提是所有引用点都显式写 canonical plugin id。
- `optional: true` 的依赖缺失时允许加载，但插件必须在 descriptor skills 中降级暴露能力，不能把不可用能力继续广告给 Agent。
- 依赖插件之间的内存所有权不能跨插件释放：A 插件分配的 buffer/handle 必须由 A 的 `free/close` 释放，B 只能保存 opaque handle 或复制 bytes。
- 若两个插件导出同名 `@extern` 符号，宿主必须拒绝链接，除非未来在 `sap.json` 中引入显式 namespace/alias 机制。

推荐增加 `sap.lock`，由 plugin-manager 生成，记录解析后的 canonical plugin id、版本、artifact `sha256`、接口 `sha256`、依赖图 `sha256`。`sap.lock` 不手写，用于 CI 和部署复现。

## 5. 安装模型

用户下载 SA 编译器后，插件安装不应要求改编译器源码。推荐命令模型：

```sh
sa plugin install ./plugins/http-client
sa plugin install /opt/sa_plugins/github.com%2Flayol13%2Fhttp-client/sap.json
sa plugin install github:layol13/http-client#v0.1.0
sa plugin install https://github.com/sa-plugins/sa_plugin_deno.git#<commit>
sa plugin install https://github.com/sa-plugins/releases/download/deno-v0.1.0/sa_plugin_deno-linux-x86_64.tar.zst
```

命令参数是插件来源，不是最终身份。安装器必须读取 `sap.json.name` / `sap.json.namespace` 得到 canonical plugin id，并用它做权限确认、依赖解析、安装目录和锁文件记录。

安装流程：

1. **Fetch**：本地路径直接读取；GitHub/Git URL 克隆到下载缓存；release archive 下载到缓存。
2. **Manifest**：在根目录查找 `sap.json`。没有 `sap.json` 的目录不能作为正式插件安装，只能走 `SA_PLUGINS_PATH=<lib.so>` 的开发模式。
3. **Reject raw artifacts**：`sa plugin install ./libfoo.so`、`.dll`、`.dylib` 必须拒绝。正式安装只能接受插件工程目录或 `sap.json`，因为安装器必须看到源码布局、接口文件和权限声明。
4. **Verify source**：远程安装必须固定 tag、commit 或 archive `sha256`。浮动分支只允许 `--dev` 模式。
5. **Verify text project**：必须存在 `build.zig`、`src/plugin.zig` 和 manifest 声明的 `.sa/.sai/.sal`。缺少文本源工程时拒绝安装。
6. **Verify permissions**：检查 `permissions` 是否覆盖插件声明的文件、网络、环境、进程能力；网络 URL 只能是 `https://...` 或 localhost。缺失或越权时拒绝安装。
7. **Manual permission confirmation**：只要 `permissions.fs/net/env/process` 非空或允许 spawn，安装器必须展示权限账本并要求用户手动输入插件名确认。正式安装不能用 `-y`、默认 yes 或 CI 自动确认跳过；非 TTY 环境必须拒绝。只有显式 `--dev` / `SA_PLUGIN_DEV=1` 本地开发模式可以跳过。
8. **Verify interfaces/assets**：`sap.json.interfaces` 中声明的 `.sa/.sai/.sal` 和 `interfaces.wasm_imports` 必须存在并匹配 `sha256`；`assets.share` 必须存在并安装到 share 目录。缺少 `.sai` 的 native 插件不能给 SA 业务代码调用。
9. **Build from source**：安装器从文本源工程执行受控构建，产出 `sap.json.artifacts` 指向的 artifact。不能直接 unpack 远程预编译 `.so/.dll/.dylib` 当作正式安装。
10. **Symbol smoke**：用 `.sai` 中的 `@extern` 与 `.so` 导出符号做双向检查。
11. **Resolve deps**：递归安装 `sap.json.dependencies`，构建 DAG，拒绝环、ABI 不兼容和重复 extern symbol。
12. **Install**：复制或硬链接到 `$SA_PLUGINS_HOME/installed/<plugin-id-path>/<version>/`，更新 `current` 指向，并生成 `sap.lock`。`<plugin-id-path>` 必须由 canonical plugin id 可逆得到，不能只使用 `name`。

默认安装目录：

```text
$SA_PLUGINS_HOME/
  cache/
  installed/
    deno/
      0.1.0/
        sap.json
        sap.lock
        permissions.lock
        lib/libsa_plugin_deno.so
        sa/deno.sa
        sa/deno.sai
        sa/deno.sal
      current -> 0.1.0
    github.com%2Flayol13%2Fhttp-client/
      0.1.0/
        sap.json
        sap.lock
        permissions.lock
        lib/libsa_plugin_http_client.so
        sa/http_client.sa
        sa/http_client.sai
        sa/http_client.sal
      current -> 0.1.0
```

SA 侧 import 规则：

- 插件安装后，宿主应把已声明插件的 `installed/<plugin-id-path>/current/sa/` 加入 SA import search path。
- 用户业务代码只 import 插件声明过的 `.sa/.sai/.sal`，例如 `@import "deno.sai"` 或 `@import "deno.sars"`。
- `.sa` facade 可以依赖同插件的 `.sai/.sal`，但不能通过相对路径直接引用其他插件源码；跨插件依赖必须写进 `sap.json.dependencies`，调用方必须在 `sa.mod` 中用 `require_plugin <plugin-id>` 声明后，由宿主 resolver 加入对应 import search path。

当前实现状态：`sci` 已能通过 `SA_PLUGINS_PATH` 直接加载 `.so`，也会扫描 `$SA_PLUGINS_HOME/installed/<plugin-id-path>/current` 下的 `.so`。本地 `sa plugin install` 已支持目录或 `sap.json`、拒绝裸 `.so/.dll/.dylib`、要求文本工程、从源码构建、做基础 `sap.json`/权限/URL 校验、校验接口路径与可选 `sha256`、执行 `.sai` 到 `.so` 的 symbol smoke、做 artifact 轻量静态导入扫描、拒绝跨插件重复 extern symbol、生成版本目录、`sap.lock`、`permissions.lock` 和依赖图 hash，并能递归安装带 `path` 的本地插件依赖且检测本地依赖环。远程源方面，GitHub/Git clone 和带 `#sha256:` pin 的 release archive 文本源码安装都已支持。宿主 `sa skills` 也会在 optional 依赖缺失或关键符号不满足时自动隐藏对应插件技能。运行时 sandbox/broker enforcement 仍是需要补齐的 plugin-manager/宿主工作。

## 6. 生命周期

当前宿主支持的真实路径：

1. **Discover**：`SA_PLUGINS_PATH` 指向单个 `.so`、单个 `sap.json`、插件目录或冒号分隔路径；或 `SA_PLUGINS_HOME/installed/<plugin-id-path>/current` 由 plugin-manager 维护。
2. **Resolve**：若发现 `sap.json`，先解析依赖图、ABI 约束和 artifact 路径；直接传 `.so` 时退化为单库加载模式。
3. **Load**：宿主按依赖拓扑顺序用 `std.DynLib.open` 加载 `.so`。
4. **Handshake**：宿主查找 `saasm_plugin_descriptor_v1` 或 `saasm_plugin_descriptor_v1_fn`，校验 ABI version、descriptor size、name，并与 `sap.json` 交叉核验。
5. **Advertise**：`sa skills` 聚合 descriptor 中的 skills metadata；存在 optional 依赖缺口时只广告可用能力。
6. **Link support**：构建 native executable 时，宿主可根据 extern symbol 名称追加导出这些符号的 plugin library。

注意：`.sai` 当前主要是 SA 编译期契约；动态库发现不会替你自动生成 `.sai`。插件作者必须维护 `.sai`，并用 smoke test 防止 ABI 漂移。

## 7. SA 文件后缀与清单边界

| 文件 | 谁维护 | 作用 |
| --- | --- | --- |
| `.sa` | 应用、标准库或包作者 | SA-ASM 源码，包含函数实现、宏调用、`@import` 和可验证指令。 |
| `.sai` | 插件或标准库作者 | SA-facing interface，只放 `@extern` 等 ABI 声明，不放 native 实现。 |
| `.sal` | 插件或标准库作者 | SA-facing layout/facade，放 `#def` 常量、结构偏移、slot 装配和薄宏。 |
| `sa.mod` | 应用或源码包作者 | 普通 SA package 依赖清单，描述源码依赖、hash、permissions、插件需求。 |
| `sap.json` | 插件作者 | SA Plugin manifest，描述安装来源、native artifact、接口文件、skills、permissions、ABI 和插件依赖。 |

边界原则：`.sa/.sai/.sal` 是 SA 编译期可见文件；`sa.mod` 管源码包；`sap.json` 管 native 插件。插件如果同时发布 SA facade，也应在 `sap.json.interfaces` 中指向自己的 `.sai/.sal`。

## 8. 设计优点

- **核心小**：SA 编译器聚焦 Flattener、Referee、Emitter；HTTP、DB、Deno 等重能力独立演进。
- **语言无关**：任何能导出 C-ABI 的语言都能实现插件。
- **Referee 可检查调用边界**：`.sai` 中的 `@extern` 签名让 SA 在不知道函数体时仍能检查所有权前缀与指针逃逸。
- **Agent 友好**：descriptor skills 让 Agent 读取当前安装插件的真实能力，而不是依赖过期静态说明。
- **可渐进替代外部运行时**：Deno 兼容插件可以先实现 sys/env/fs/process，再扩展 file handles、net、DNS、permissions。
- **可组合**：`sap.json` 让 HTTP、TLS、DNS、DB、Deno 这类插件能声明依赖图，宿主按真实能力组合加载，而不是靠 README 约定顺序。
- **安装源灵活**：本地目录、`sap.json`、GitHub 仓库和 release 包都能收敛到同一套 manifest/hash/interface 校验流程。

## 9. 当前缺点与必须改进项

- **ABI 漂移**：实现和 `.sai` 容易不一致。所有插件都必须加入 `.sai` vs `.so` symbol smoke。
- **错误模型太粗**：`0/1/2` 不足以表达 OS errno、权限错误、NotFound、InvalidData、Unsupported。需要统一 `sa_plugin_status` 和可选错误 buffer ABI。
- **复杂对象缺标准**：File、Conn、Request、Response、Permission 等必须统一 handle ownership、drop/free、getter、reader 模式。
- **async 缺 ABI**：Promise、stream、event 不应直接暴露到 SA；应统一为 `start -> handle`、`poll -> status`、`take -> bytes/json/handle`、`free`。
- **插件安装器剩余缺口**：本地 `sap.json` 安装、基础权限校验、接口路径/hash 校验、`.sai` symbol smoke、artifact 静态导入扫描、`sap.lock` / `permissions.lock`、远程 Git/release archive 安装、本地依赖环检测和 optional 技能降级已落地；仍需补运行时 sandbox/broker enforcement。
- **权限隔离尚未完全落地**：文档中的 grant/syscall 阻断是目标设计；当前插件更多依赖 OS 调用和 SA FFI 规则。新文档必须明确区分现状和目标。
- **运行路径不一致**：部分 extern-heavy 插件 native `sa build` 可工作，但 `sa run` 解释路径仍可能不支持完整插件执行。这是宿主一致性问题。

## 10. 推荐 ABI 模式

### 10.1 值和 buffer

```sa
@extern sa_deno_plugin_hostname(&out_ptr: ptr, &out_len: ptr) -> u32
@extern sa_deno_plugin_free_buffer(ptr: ptr, len: u64) -> u32
```

规则：

- 返回 buffer 由插件分配，调用方必须通过同一插件的 `free_buffer` 释放。
- `out_ptr` / `out_len` 用 slot 承载，`.sal` 宏负责 `stack_alloc` 和 `load`。

### 10.2 Opaque handle

```sa
@extern sa_http_client_new(use_tls: u8, &out_client: ptr) -> u32
@extern sa_http_client_req_send(req: ptr, &out_resp: ptr) -> u32
@extern sa_http_client_resp_free(resp: ptr) -> u32
```

规则：

- handle 是插件私有指针，SA 只能保存和传回。
- 每个 `*_new` / `*_open` 必须有明确的 `*_free` / `*_close`。

### 10.3 Async/stream

```sa
@extern sa_task_start(&input: ptr, input_len: u64, &out_task: ptr) -> u32
@extern sa_task_poll(task: ptr, &out_state: ptr) -> u32
@extern sa_task_take(task: ptr, &out_ptr: ptr, &out_len: ptr) -> u32
@extern sa_task_free(task: ptr) -> u32
```

规则：

- `poll` 只返回状态，不转移大对象。
- `take` 才转移结果 buffer 或 child handle。
- `free` 必须在成功、失败、取消路径都合法。

## 11. 最低测试要求

每个插件至少提供：

- `zig build`
- `sap.json` validation：schema、descriptor name、artifact、permissions、`.sa/.sai/.sal`、dependency DAG 必须能被 plugin-manager 校验。
- install smoke：本地目录、`sap.json` 路径、GitHub/Git URL 和 release archive 至少覆盖一种远程安装路径。
- `nm -D` symbol smoke：`.sai` 中所有 `@extern` 都有导出符号。
- native SA smoke：`SA_PLUGINS_PATH=<lib.so> sa build tests/<plugin>.sa` 后执行生成的 native binary。
- plugin-manager smoke：`install/list/cache/uninstall/cache prune` 能识别插件。
- 对 replacement runtime 插件增加 `API_COVERAGE.md`，把 public API 标为 `implemented` / `planned_native` / `stub_unsupported` / `type_only`。

## 12. 结论

SA 插件系统的正确方向是“微内核编译器 + C-ABI native capability + `sap.json` 依赖/权限清单 + `.sa/.sai/.sal` 显式契约”。它已经适合承载 HTTP、DB、Deno sys/fs/env/process 这类能力；要声称完整替代 Deno/Bun 级 runtime，必须先补齐统一错误、handle、async、权限、依赖解析和覆盖账本。
