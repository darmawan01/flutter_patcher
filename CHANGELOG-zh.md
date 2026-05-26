# 更新日志

[English](CHANGELOG.md) | **简体中文**

## 0.1.3

### Added

- 新增 Android 冷启动 Flutter 资源热更新。资源（图片、字体、JSON，凡是
  `Image.asset(...)` 或 `rootBundle.load(...)` 能拿到的内容）可以和 Dart
  代码一起通过同一个 `patch.zip` 打包热更。
- `dart run flutter_patcher:pack` 新增 `--assets`。可以内联传入
  （`--assets a,b`），也可以用 `@` 前缀指向 UTF-8 文本文件
  （`--assets @patch-assets.txt`，每行一个 path，`#` 开头为注释）；内联与
  `@file` 可在同一个参数里混用。每个 path 都必须先在新 APK 的
  `pubspec.yaml` `assets:` 下登记 —— `--assets` 只是告诉 `pack`：从这些
  已编入 APK 的资源里挑哪些放进 `patch.zip`。运行时在**安装阶段**把它们
  overlay 到 APK 的 Flutter 资源 bundle 之上。

### Changed

- `dart run flutter_patcher:pack` 现在恒定输出 `dist/patch.zip` +
  `dist/manifest.json`（外层 `schemaVersion: 2`、`payload: patch.zip`），
  无论是否传 `--assets`。纯 Dart 补丁的 `patch.zip` 内仅含 `manifest.json` +
  `lib/<abi>/libapp.so`，内部 manifest 不包含 `assets` 块。原先的裸 `.so`
  输出形态已下线。
- Android runtime 识别 ZIP payload、安装 overlay asset package、生成私有
  `flutter_assets.apk`，并在带资源时通过 patched `FlutterJNI` AssetManager
  启动 Flutter；纯 Dart 的 `patch.zip` 会跳过资源 overlay，安装时表现与纯
  代码补丁一致。
- `mock_server --dist` 读取 `manifest.payload`，按声明分发对应文件。

### 兼容性

- 0.1.0–0.1.2 时代产出的裸 `.so` 补丁仍能在 0.1.3 设备上安装（runtime 保留
  了一条不在文档中暴露的 legacy 安装路径）；但 pack CLI 不再生成该格式。
  在 0.1.3+ 宿主 APK 上发布的新补丁应统一为 `patch.zip`。

## 0.1.2

### Added

- 新增 `dart run flutter_patcher:mock_server`，用于本地测试
  `checkUpdate -> applyPatch` 流程。

### Changed

- 改进 README 顶部结构，增加 TL;DR、适合 / 不适合场景、商店政策提醒和本地
  mock server 说明。
- 更新 pub.dev package description 和 topics。
- 新增 GitHub social preview 图片：`doc/social-preview.png`。

## 0.1.1+1

### Fixed

- 修正 README 安装片段中的版本号为 `^0.1.1`。
- 将英文 CHANGELOG 作为 pub.dev 展示版本，中文版本保留为 `CHANGELOG-zh.md`。

## 0.1.1

### Changed

- `PatchInfo.md5` 改为可选。空字符串表示跳过下载完整性校验，并同时跳过签名校验。
- `validatePatchArgs` 接受空 md5；非空 md5 仍要求 32 位 hex。
- 黑名单在未下发 md5 时可按 version 维度做下载前检查；入黑名单时仍记录实际 md5。
- `meta.json` 的 `effectiveMd5` 始终使用下载后实际计算的 md5。
- 放宽 Dart SDK 与运行时依赖约束，减少宿主项目依赖冲突。

## 0.1.0

首次公开发布，Android-only beta。

### Added

- 冷启动热更新：在 Android 启动早期加载补丁 `libapp.so`。
- MD5 + 可选 Ed25519 签名校验。
- 崩溃熔断 / 自动回滚 / 本地黑名单。
- `FlutterPatcher.applyProgress` 进度事件流。
- `dart run flutter_patcher:pack` 打包工具。

### Known limitations

- 仅 Android。
- 严格 Ed25519 模式需要 Android API 33+。
- 仅支持完整补丁，不支持二进制差分。
