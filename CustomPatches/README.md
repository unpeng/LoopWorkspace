# CustomPatches - 子模块自定义改动备份

## 这是干什么的

LoopWorkspace 是一个由多个 git 子模块（submodule）组成的工程。子模块的远端指向 LoopKit 官方仓库，
我们没有推送权限，所以子模块里的本地改动**无法**跟着主仓库一起推到自己的 fork。

这个目录把所有子模块的改动导出成 **patch 补丁文件**，作为主仓库的普通文件提交，
从而实现：改动能备份到自己的 fork、换机器能还原、同时还能继续拉官方更新。

用 patch 而不是整份文件拷贝，是因为 patch 只记录"改了哪几行"。官方更新后重新应用时可以做三方合并，
只有真正冲突的地方才需要手工处理；整份文件覆盖会把官方的新改动直接冲掉。

> 注意：这套机制**只用于本地 Xcode 构建**的备份与还原，是手动执行的。
> 它和 `LoopWorkspace/patches/` 那个目录无关 —— 那个是 GitHub Actions 云端构建（Browser Build）
> 自动应用补丁用的，本地 Xcode 构建不会触发。

## 目录结构

```
CustomPatches/
├── README.md         # 本文件
├── manifest.txt      # 各子模块的基线 commit 记录（自动生成，勿手工编辑）
├── save.sh           # 导出补丁
├── restore.sh        # 应用补丁
└── patches/
    ├── Loop.patch
    ├── LoopKit.patch
    ├── LoopOnboarding.patch
    ├── NightscoutRemoteCGM.patch
    ├── NightscoutService.patch
    └── OmnipodKit.patch
```

`manifest.txt` 每行四个字段（TAB 分隔）：

| 字段 | 含义 |
|---|---|
| 子模块路径 | 例如 `LoopKit` |
| 生成补丁时的 HEAD | 补丁的**基线版本**，还原时的参照 |
| 主仓库记录的 commit | 主仓库 `.gitmodules` 指针指向的版本 |
| 远端地址 | 该子模块的 origin |

## 日常用法

### 改完代码后，保存改动

```bash
./CustomPatches/save.sh
git add CustomPatches
git commit -m "更新子模块自定义改动补丁"
git push origin main
```

`save.sh` 会全量重新生成所有补丁，不需要手工维护补丁文件。
它会自动把未跟踪的新增文件也纳入补丁（通过 intent-to-add，不产生 commit），
并且会备份/还原子模块的 index，不影响你已经 `git add` 过的文件状态。

### 换新机器 / 重新拉代码后，还原改动

```bash
git clone https://github.com/unpeng/LoopWorkspace.git
cd LoopWorkspace
git submodule update --init --recursive

./CustomPatches/restore.sh --checkout
```

`--checkout` 会先把每个子模块切回 `manifest.txt` 里记录的基线版本再应用补丁，最稳妥。
如果不加 `--checkout`，就在子模块当前版本上用三方合并的方式应用。

### 拉取官方更新后，把改动重新贴回去

```bash
# 1. 拉官方更新
git fetch upstream
git merge upstream/main

# 2. 同步子模块到新版本
git submodule update --init --recursive

# 3. 重新应用补丁（不要加 --checkout，否则会退回旧版本）
./CustomPatches/restore.sh
```

第 3 步可能出现冲突。冲突的文件里会有 `<<<<<<<` 标记，用 `git status` 在对应子模块里查看，
手工处理后**重新跑一次 `save.sh`** 更新补丁基线。

## remote 配置

主仓库配置为 fork 工作流：

```
origin   → https://github.com/unpeng/LoopWorkspace.git   # 推自己的改动
upstream → https://github.com/LoopKit/LoopWorkspace.git  # 只拉官方更新
```

## 注意事项

- **`OmnipodKit` 版本不一致**：它 checkout 的 commit 与主仓库记录的指针不同，
  且远端是 `loopandlearn/OmnipodKit` 而非 LoopKit 官方。还原时以 `manifest.txt` 第二个字段为准。
- 主仓库自身的改动（AppIcon 图标、`Package.resolved` 等）是普通文件，直接 commit 即可，**不需要**补丁。
- 补丁基线会随官方更新而过期。每次处理完冲突都重新跑 `save.sh`，保持补丁与当前代码同步。
- `restore.sh` 会先检测补丁是否已应用过，重复执行是安全的。
