# 本地源码复核与验证

日期：2026-09-08。对象：Codex Island 0.1.22 原始源码包。

## 结论

源码可编译、自动测试通过，本机 Codex 连接和额度读取已实测成功，适合先存入私有仓库继续验证。不是已签名、公证、完成全部交互验收的发行版。

## 来源与完整性

- 来源：用户提供的 Multica AIT-39 附件 `Codex-Island-0.1.22-source.zip`。
- 包大小：51,500 字节。
- SHA-256：`b49e79aee33a3037f5b5d036ad0fae58f9fa39e114a73d168796171701c504f8`。
- ZIP CRC 校验通过；解压前检查绝对路径、路径穿越与符号链接。
- 原始包含 28 个文件；未更改应用源代码。本报告为本地新增说明。

## 本次实际执行

环境：Apple Silicon、macOS 26.3、Apple Swift 6.3.3。

- `swift test`：34 项 XCTest，0 失败；包括 21 项核心、9 项表现层、4 项额度测试。
- `swift build -c release --arch arm64 --arch x86_64`：成功。
- `lipo -archs`：产物包含 `x86_64 arm64`。
- 两个 Bash 脚本通过 `bash -n` 语法检查。
- `CodexIsland --version`：返回 0.1.22。
- `CodexIsland --diagnose`：`connected=true`、`catalogAvailable=true`、目录 24 项、宠物 9 个、默认宠物加载成功、屏幕 1 个。`liveTaskCount=0`，因此没有据此证明活跃任务的实时状态更新。
- 使用项目原有 `UsageReader.swift`、编译好的 IslandCore 和仓库外临时测试入口，实测调用本机 Codex App Server：`account/rateLimits/read` 成功，解析出每周剩余额度。未将账户标识、原始响应或凭据加入仓库。
- `git diff --cached --check` 通过。原始 28 个源码文件中未命中所检查的私钥、GitHub Token、常见 API Key 模式；不等于全面安全审计。

## 限制与注意事项

1. `scripts/build-app.sh` 因本机无 Apple Development / Developer ID 签名身份而停止。未绕过签名、未生成或上传可分发 `.app`，未做公证。双架构编译成功不等于安装包交付成功。
2. `PanelController.swift` 的 Timer 动画回调产生 Swift 并发警告，包括非 Sendable 值捕获和 MainActor 隔离访问。当前 Swift 5.10 package 模式可构建，未来严格 Swift 6 模式需要整改。
3. 实时状态依赖 Codex Desktop 内部 IPC v11；升级客户端可能需要适配。连接握手成功不等于全部活跃任务快照已验证。
4. 未进行完整桌面手工点击、刘海屏、多显示器、Intel 硬件、macOS 14、开机启动和深链接端到端验收。
5. 原包没有 LICENSE 文件。保留原始归属与第三方声明，不自行添加开源授权；公开发布或再分发前需确认授权。
6. `VALIDATION.md` 是原包作者的记录，与本报告独立；不得把作者机器上的签名与界面验证视为本机已完成。

## 补充静态审查：待修复项

第二路只读审查返回后复核了以下代码路径。正常路径的构建、测试和连接成功，不代表这些异常路径已通过验证；本次只记录，不修改原始应用源码。

- **中：SQLite 错误可能被误判为成功。** `Sources/IslandCore/TaskCatalog.swift:28–39` 只处理 `SQLITE_ROW`，未检查结束返回码是否为 `SQLITE_DONE`。运行期锁冲突或 I/O 错误可能返回空/部分目录，而 `IPCObserver.swift:185–193` 随后标记目录可用。建议优先补充错误检查与异常路径测试。
- **中：辅助进程退出清理缺少同步保证。** `Sources/CodexIsland/UsageReader.swift:45–49,69–76` 的 stop 只发送 SIGTERM，强制退出和回收在后台 defer 中。应用退出时能否完成回收仍需专门验证；没有证据表明本次实际发生残留。
- **中：本地素材资源限制偏晚。** `Sources/CodexIsland/PetLibrary.swift:47–49,70–72` 在读取 manifest、创建图像后才检查数据大小或图像尺寸；畸形/巨大素材可能带来内存压力。
- **低：ASAR 偏移缺少溢出保护。** `PetLibrary.swift:102–106` 直接计算 `base + offset`，异常本地 ASAR header 可能造成溢出崩溃。

静态审查未发现明确的恶意上传、直接写入 Codex 凭据或 shell 命令注入。额度辅助程序本身仍会继承环境、联网并可能执行自身日志或认证刷新，不能将“本应用只发读取 RPC”扩大表述为全链路零写入或完全离线。

建议将本版本定位为**正常路径已验证、异常健壮性待加固的私有开发版**，而非生产安全验收完成的正式版。

仓库只托管源码与说明，排除 `.build`、`dist`、账户配置、运行数据和签名凭据。
