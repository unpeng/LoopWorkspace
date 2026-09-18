# CustomPatches - 子模块补丁与依赖锁快照

## 这是干什么的

LoopWorkspace 由多个 git 子模块（submodule）和 Swift Package 依赖组成。子模块的远端指向上游仓库，
我们没有推送权限；同时部分上游 Package 使用浮动分支或宽松版本范围，本地验证过的依赖版本可能被 Xcode 重新解析。

这个目录使用两种方式保存本地状态：

- 子模块改动保存为 patch，便于上游更新后进行三方合并；
- 主 Workspace 的 `Package.resolved` 保存为完整快照，确保即使当前内容与 Git HEAD 一致，后续点击“更新包”也能检测并恢复。

这些文件作为主仓库的普通文件提交，从而实现换机器还原、依赖版本复现和继续拉取上游更新。

> 注意：这套机制**只用于本地 Xcode 构建**的备份与还原，是手动执行的。
> 它和 `LoopWorkspace/patches/` 那个目录无关 —— 后者用于 GitHub Actions 云端构建（Browser Build）。

## 目录结构

```
CustomPatches/
├── README.md
├── manifest.txt      # 快照校验值及子模块基线（自动生成，勿手工编辑）
├── save.sh
├── restore.sh
├── locks/
│   └── Package.resolved
└── patches/
    ├── Loop.patch
    ├── LoopKit.patch
    ├── LoopOnboarding.patch
    ├── NightscoutRemoteCGM.patch
    ├── NightscoutService.patch
    └── OmnipodKit.patch
```

`locks/Package.resolved` 是以下顶层锁文件的完整快照：

```text
LoopWorkspace.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

`manifest.txt` 的注释头记录主仓库基线 HEAD、快照路径及 SHA-256；后续每行记录一个子模块的四个字段（TAB 分隔）：

| 字段 | 含义 |
|---|---|
| 子模块路径 | 例如 `LoopKit` |
| 生成补丁时的 HEAD | 补丁的**基线版本**，还原时的参照 |
| 主仓库记录的 commit | 主仓库 gitlink 指针指向的版本 |
| 远端地址 | 该子模块的 origin |

## 日常用法

### 改完代码或确认依赖版本后，保存状态

```bash
./CustomPatches/save.sh
git add CustomPatches
git commit -m "更新本地自定义改动和依赖锁快照"
git push origin main
```

`save.sh` 每次都会：

- 完整复制顶层 `Package.resolved` 到 `locks/Package.resolved`；
- 在 manifest 中记录快照 SHA-256；
- 全量重新导出所有有本地改动的子模块补丁；
- 通过 intent-to-add 纳入子模块未跟踪文件，并保持原有 staged 状态。

运行 `save.sh` 前应先完成一次成功构建，确保保存的是已验证依赖组合。

### 换新机器或依赖被 Xcode 更新后，还原状态

```bash
git clone https://github.com/unpeng/LoopWorkspace.git
cd LoopWorkspace
git submodule update --init --recursive

./CustomPatches/restore.sh --checkout
```

`restore.sh` 会按以下顺序执行：

1. 校验保存快照的 SHA-256，校验失败时拒绝覆盖；
2. 比较当前顶层锁文件与快照；
3. 如果不同，明确报告依赖锁漂移，将当前文件备份到系统临时目录，再恢复保存的快照；
4. 恢复各子模块补丁。

`--checkout` 只作用于子模块，主仓库不会被 checkout。重复执行时，如果依赖锁和补丁已经恢复，会安全跳过。

### 拉取上游更新后

```bash
git fetch upstream
git merge upstream/main
git submodule update --init --recursive
./CustomPatches/restore.sh
```

完整锁文件快照会覆盖上游更新后的 `Package.resolved`，以保证已验证依赖组合。如果确实需要接受上游的新依赖图，
应先在 Xcode 中完成依赖解析和构建验证，再运行 `save.sh` 更新快照。子模块补丁发生冲突时，处理完冲突后也应重新运行 `save.sh`。

## 推荐的严格构建命令

```bash
xcodebuild \
  -workspace LoopWorkspace.xcworkspace \
  -scheme LoopWorkspace \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  build
```

## remote 配置

```
origin   → https://github.com/unpeng/LoopWorkspace.git
upstream → https://github.com/LoopKit/LoopWorkspace.git
```

## 注意事项

- **`OmnipodKit` 版本不一致**：它 checkout 的 commit 与主仓库记录的指针不同，
  且远端是 `loopandlearn/OmnipodKit`。还原时以 `manifest.txt` 第二个字段为准。
- `Package.resolved` 由完整快照管理；其他主仓库文件仍作为普通文件直接 commit。
- 恢复依赖锁前会在 `${TMPDIR:-/tmp}` 下创建 `LoopWorkspace-Package.resolved.bak.*` 备份，并输出实际路径。
- 快照会固定整个 Swift Package 依赖图，而不只是 TidepoolKit 和 CryptoSwift。
- 每次确认新依赖组合可以成功构建后，都要重新运行 `save.sh` 更新快照。
