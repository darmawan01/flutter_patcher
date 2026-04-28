# 技术架构

> 本文档解释 flutter_patcher 内部如何工作，以及自托管服务端的实现要求。
>
> - 公开 API、pack CLI 参数、性能与兼容范围见 [API Reference](https://pub.dev/documentation/flutter_patcher/latest/topics/API-reference-topic.html)
> - 崩溃保护与回滚机制见 [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html)
>
> 本文按读者意图分为三块：
> - **Part 1 · 工作原理** —— 想理解"它怎么生效"
> - **Part 2 · 自托管服务端** —— 要自己搭后端分发补丁
> - **Part 3 · 进阶配置** —— 标准接入流程不够用，需要定制启动时序或启用增量补丁

---

## Part 1 · 工作原理

### 整体流程

整套系统涉及三个角色：

```
  你的开发机                   你的服务端                  用户设备
 ─────────────              ─────────────              ─────────────
 修改 Dart 代码               存储 + 分发                 下载 + 校验
       │                         │                         │
 flutter build apk            上传补丁                  applyPatch()
       │                    libapp.so + meta               │
 pack 工具提取                    │                    写入本地 + 落盘
 libapp.so + meta ──────→   CDN / 对象存储 ──────→    下次冷启动加载
                                                          │
                                                     启动成功 → 清熔断
                                                     启动失败 → 自动回滚
```

**用户设备冷启动时：** 插件在 `Application.attachBaseContext` 阶段完成熔断检查 → 补丁校验（versionCode + MD5 + 可选签名）→ 反射替换 `FlutterLoader` → 引导 Engine 加载补丁 `.so`。首帧渲染时立即清除熔断计数；Dart 错误钩子再守 5 秒（默认）捕捉首屏点击型异常。

**补丁出问题时：** 用户最多经历一次白屏。下次冷启动插件检测到上次启动失败，自动回滚到 APK 内置版本，并将该补丁加入本地黑名单防止循环下载。完整流程见 [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html)。

---

### versionCode 强绑定

`applyPatch` 落盘时将 `targetVersionCode` 写入 `patch_meta.json`。每次冷启动在反射替换之前比对，不匹配则删除补丁。

即使服务端未下发 `targetVersionCode`，APK 升级后也会自动清除旧补丁——因为 `pack` 工具会在生成补丁时记录基准 APK 的 versionCode，客户端比对宿主 APK 的 `PackageInfo.versionCode` 不一致就丢弃。

这是为什么 `pack --target-version-code` 是必填参数。

---

### 反射兼容矩阵

| Flutter 版本 | `FlutterInjector` 字段 | `ensureInitializationComplete` 签名 |
|---|---|---|
| 3.19.x ~ 3.38.x | `flutterLoader` | `(Context, @Nullable String[])` |

Flutter 大版本升级后如反射字段名变更，可临时适配：

```dart
await FlutterPatcher.init(loaderFieldCandidates: ['newFieldName', 'flutterLoader']);
```

升级后请检查 logcat 中 `FlutterPatcher/Hook` 标签的输出确认注入成功。

---

### 签名设计

Ed25519 签名提供独立于 HTTPS 的完整性校验，防止 CDN 篡改。

#### 算法与编码

- **算法：** Ed25519
- **公钥格式：** X.509 SubjectPublicKeyInfo DER → Base64
- **签名消息体：** MD5 hex 字符串（32 字节 UTF-8）
- **签名编码：** Base64

签名对象不是补丁文件二进制本身，而是补丁的 MD5 hex 字符串。这样验签成本恒定（仅 32 字节），与文件大小解耦；MD5 已在前置阶段确保了文件内容完整性。

#### 为什么 strictSignature 默认 true

JDK 原生 Ed25519 需要 Android 13+（API 33）。低版本设备遇到带签名补丁时：

- `strictSignature: true`（默认）→ **拒绝加载**
- `strictSignature: false` → 跳过验签，仅靠 MD5 + HTTPS 防护

默认拒绝是为了防止**降级攻击**：如果默认放行，攻击者可以伪造旧 API 设备（或强制运行在 API < 33 环境），让带恶意签名的补丁直接绕过验签。默认严格模式确保"只要配了签名，就一定真的会校验"，低版本设备宁可加载失败也不静默放行。

服务端如何生成密钥与签名，见 [Part 2 · 服务端签名](#服务端签名)。

---

## Part 2 · 自托管服务端

flutter_patcher 不绑定任何特定后端。你需要实现的最小协议如下。

### check-update 接口

客户端定期请求，服务端返回是否有新补丁：

```http
GET /api/patch/check?app_version_code=100&abi=arm64-v8a&current_patch=1.0.0-h1
```

无可用补丁：

```json
{ "has_update": false }
```

有可用补丁：

```json
{
  "has_update": true,
  "version": "1.0.0-h2",
  "patch_url": "https://cdn.example.com/patches/arm64-v8a/libapp.so",
  "md5": "0123456789abcdef0123456789abcdef",
  "target_version_code": 100
}
```

### 补丁文件托管

任何能提供 HTTP GET 下载的服务即可——CDN、对象存储、nginx 静态目录都行。

### 多 ABI 分发

服务端需按 ABI 分发不同的 `libapp.so`。客户端可通过 `await FlutterPatcher.deviceAbi` 获取当前设备 ABI，拼进 check-update 请求中。

### 服务端签名

如果你要启用签名校验，需要在服务端完成两件事：生成密钥对（一次）与签名每个补丁（每次发布）。

#### 生成密钥对

```bash
# 开发机执行一次
openssl genpkey -algorithm ed25519 -out patch_sk.pem
openssl pkey -in patch_sk.pem -pubout -outform DER | base64 -w0
# 输出类似 MCowBQYDK2VwAyEA...
```

私钥 `patch_sk.pem` 留在服务端构建机器；公钥 Base64 字符串配置到客户端 `FlutterPatcher.init(publicKeyBase64: ...)`。

#### 签名补丁

```bash
# 消息体 = MD5 hex 字符串的 UTF-8 字节
printf "%s" "0123456789abcdef0123456789abcdef" | \
  openssl pkeyutl -sign -inkey patch_sk.pem -rawin | base64 -w0
```

签名结果填入 check-update 响应的 `signature` 字段下发。签名消息体的设计原理见 [Part 1 · 签名设计](#签名设计)。

### 推荐功能

- **崩溃上报联动：** 接收客户端 `droppedCircuitBreaker` 事件（来自 `lastBootDiagnostic`），同一补丁短时间收到 N 次回滚事件后 **自动停止下发**
- **灰度发布：** 1% → 5% → 20% → 100% 分阶段放量，配合监控指标观察 crash 率
- **紧急下架：** 从 check-update 接口的返回中移除该版本即可，已安装的用户不受影响直到下次冷启动拉新配置

> 仓库 `example/tools/mock_server.dart` 提供了一个本地 mock server，可用于开发联调。

---

## Part 3 · 进阶配置

### 关闭自动初始化

仅在一种情形需要：**你在 `Application.attachBaseContext` 里预热了 `FlutterEngine`**（常见于大厂混合工程的冷启动优化）。此时自动初始化的 ContentProvider 比 Engine 创建晚，反射来不及。

```xml
<!-- AndroidManifest.xml -->
<provider
    android:name="com.flutter_patcher.flutter_patcher.FlutterPatcherAutoInitProvider"
    android:authorities="${applicationId}.flutter_patcher.autoinit"
    tools:node="remove" />
```

```kotlin
class MyApp : FlutterApplication() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        FlutterPatcherApplication.attachPatcher(base)
    }
}
```

### 启用 bsdiff 差分

默认关闭。启用后补丁包体积从数 MB 降至数十 KB。需要手动集成 C 源码，约 10 分钟。

详细步骤：将 [bsdiff-4.3](https://www.daemonology.net/bsdiff/) 的 `bspatch.c` 和 [bzip2-1.0.x](https://sourceware.org/pub/bzip2/) 源码放入 `android/src/main/cpp/third_party/`，将 `bspatch.c` 的 `main` 改为 `flutter_patcher_bspatch(old, new, patch)` 签名，重新构建。服务端用 `bsdiff` 命令生成差分包，下发时设 `mode: "bsdiff"` 并附上合成目标的 MD5。

---

## 已知限制

- **iOS 不支持：** Apple 政策禁止下载可执行代码
- **Flutter Engine 升级即作废：** 大版本升级后所有旧补丁必须重新生成
- **反射依赖 Flutter 私有 API：** Flutter 大改 loader 架构时可能需要适配
- **合规风险：** 动态下发可执行代码在部分应用商店类目（面向未成年人、金融、医疗等）存在政策限制，接入前请评估目标市场要求
