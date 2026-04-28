# 崩溃保护机制

> 补丁有问题时，用户最多看到一次白屏，下次打开 app 自动恢复正常。不会出现反复崩溃、需要卸载重装的情况。整套流程在客户端本地闭环，不依赖服务端。

---

## 默认行为

补丁加载后启动失败 **1 次**，即丢弃补丁 + 入本地黑名单，下次冷启动自动回到 APK 内置版本。不给"再试一次"的机会——生产环境里坏补丁不会第二次变好。

---

## 什么算"失败"

**算崩溃（计入熔断）：** App crash、native crash、ANR、Dart 层未捕获异常导致白屏。

**不算崩溃（不计入）：** 用户从最近任务划掉、用户在设置里强停、系统 OOM 杀进程、用户按 Home 切后台。

补丁加载后 **首帧渲染完成** 即视为初步可信，立即清掉熔断状态——从这一刻起，用户从最近任务划掉、按 Home、被系统 OOM 都不会被误判为补丁崩溃。

Dart 层错误钩子（拦截 throw 被 framework 接住的白屏故障）会在首帧后再多守 `verifyAfter` 秒（默认 5 秒，只在前台累计），捕捉首屏点击立即触发的 Dart 异常。窗口结束后业务自身的异常不再被归到补丁。

---

## 配置

```dart
await FlutterPatcher.init(
  config: PatcherConfig(
    maxCrashCount: 1,                          // 连续失败几次后熔断，默认 1（fail-fast）
    verifyAfter: const Duration(seconds: 5),   // Dart 错误钩子守护窗口，默认 5 秒
  ),
);
```

`maxCrashCount` 可以调高，但通常不建议——多次重试只会让更多用户看到白屏。

---

## 黑名单

被自动回滚的补丁以 `(version, md5)` 双键写入本地黑名单：

- 同一份补丁（version + md5 都一样）再次下发 → 直接拒绝，不浪费流量
- 修了 bug 后用同样 version 重发（md5 必然不同）→ 允许下载
- FIFO 上限 50 条，超出按时间淘汰
- 升级 APK 后黑名单仍保留，防止服务端误发已知有问题的补丁

**手动调用 `rollback()` 不入黑名单**——这是主动操作，不是补丁本身有问题。

黑名单查询和清空接口见 [API Reference](api-reference.md#黑名单)。

---

## Android 版本差异

Android 11+（API 30+）能通过 `ApplicationExitInfo` 精确区分"真崩溃"和"用户主动关闭"，覆盖首帧前后所有崩溃，几乎不会误伤。

Android 10 及以下（约 5–10% 存量设备）没有 `ApplicationExitInfo`，只能检测 **首帧渲染前** 就死掉的崩溃。首帧渲染之后才发生的 native crash / ANR 在低版本设备上不会被本插件识别（Dart 层异常仍由错误钩子在 verifyAfter 窗口内捕获）。这是已知盲区，业务侧若无法接受可显式调高 `maxCrashCount` 增加容忍度。

---

## 监控建议

客户端崩溃保护是最后一道防线。生产环境建议同时在服务端做：

- 接收客户端 `droppedCircuitBreaker` 上报，同一补丁短时间收到 N 次回滚事件后自动停止下发
- 灰度发布：1% → 5% → 20% → 100%，配合 crash 率指标观察
- 紧急下架开关：从 check-update 接口移除该版本即可

诊断接口（`lastBootDiagnostic`）和错误码处理见 [API Reference](api-reference.md#上次启动诊断)。

---

<details>
<summary><strong>内部实现细节</strong>（贡献者 / 好奇者参考）</summary>

### 熔断器时序

| 时机 | 行为 |
|---|---|
| `Application.attachBaseContext` | 写入 `patch_loading=true` + 当前 pid（同步 `commit`）。pid 用于下次冷启动 `ApplicationExitInfo` 查询 |
| Dart `FlutterPatcher.init()` | 再写一次 `patch_loading=true`。兜底 native 层 `commit` 失败的极端情况（磁盘满、进程在两次写入之间被杀） |
| 首帧渲染 | 立即 `markBootSuccess`：清 `patch_loading=false` + `crash_count=0`（**保留** `last_booting_pid` 给下次冷启动用）。同时启动 `verifyAfter` 计时器 |
| 前台累计存活 N 秒 | 关闭 Dart 错误钩子窗口（`_dartHookActive=false`），后续 Dart 异常透明转发原 handler，不再上报熔断 |
| Dart 错误钩子触发（窗口期内） | `crash_count++`，立即在磁盘上完成回滚准备（删除补丁 + 入黑名单），实际恢复等下次冷启动 |
| 下次冷启动 `shouldLoadPatch` | API 30+ 且有 pid → 用 `ApplicationExitInfo` 精确分类（覆盖首帧前后所有崩溃）；API < 30 或 ExitInfo 无记录 → 退回到 `patch_loading` 兜底信号 |
| `crash_count >= maxCrashCount` | 删除补丁文件 + 入黑名单，回退 APK 内置版本 |

### 崩溃判定：Android 11+ ApplicationExitInfo 映射

| reason | 是否计入崩溃 |
|---|---|
| `REASON_CRASH` / `REASON_CRASH_NATIVE` | ✅ |
| `REASON_ANR` | ✅ |
| `REASON_USER_REQUESTED` | ❌ |
| `REASON_USER_STOPPED` | ❌ |
| `REASON_LOW_MEMORY` / `REASON_OTHER` | ❌ |
| `REASON_SIGNALED` (SIGKILL) | ❌ |

### Dart 层白屏兜底

补丁最常见的故障形态不是进程崩溃，而是 Dart 层 throw 被 framework 接住、进程不死但白屏。`ApplicationExitInfo` 看不到任何异常退出。

插件在 init 时安装两个错误钩子（`PlatformDispatcher.instance.onError` + `FlutterError.onError`）。在 `verifyAfter` 窗口内任一钩子触发，等同于一次崩溃：立即 `crash_count++` 并在磁盘上完成回滚准备。由于 `libapp.so` 已加载到内存，当前进程无法切回内置版本，实际恢复等下次冷启动。

窗口关闭后钩子保持安装状态，但变为透明转发原 handler（不再向原生上报熔断）。业务自身的 Dart 异常不会影响补丁状态。

### 调试

Logcat tag `FlutterPatcher/Guard` 输出所有崩溃判定日志：

```bash
adb logcat | grep FlutterPatcher/Guard
```

`example/lib/diag_card.dart` 将诊断字段做成了可视化卡片，真机调试时直接看屏幕。

</details>