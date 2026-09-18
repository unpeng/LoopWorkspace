#!/bin/bash
#
# restore.sh - 校验并恢复 Workspace 依赖锁，再恢复各子模块补丁
#
# 用法:
#   ./CustomPatches/restore.sh              # 在当前版本上恢复
#   ./CustomPatches/restore.sh --checkout   # 先把子模块切回生成补丁时的版本，再应用（最保险）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_DIR="$SCRIPT_DIR/patches"
LOCK_SNAPSHOT="$SCRIPT_DIR/locks/Package.resolved"
MANIFEST="$SCRIPT_DIR/manifest.txt"
DEPENDENCY_LOCK="LoopWorkspace.xcworkspace/xcshareddata/swiftpm/Package.resolved"

DO_CHECKOUT=0
[ "${1:-}" = "--checkout" ] && DO_CHECKOUT=1

[ -f "$MANIFEST" ] || { echo "错误: 找不到 $MANIFEST"; exit 1; }

cd "$ROOT"
ok=0
skipped=0
failed=0
failed_list=""

# Workspace 依赖锁属于主仓库，不受 --checkout 影响。
echo "=== WorkspaceDependencies ==="
expected_lock_sha="$(awk -F': ' '/^# Workspace依赖锁SHA256: / {print $2; exit}' "$MANIFEST")"

if [ ! -f "$LOCK_SNAPSHOT" ]; then
    echo "  失败: 找不到依赖锁快照 $LOCK_SNAPSHOT"
    failed=$((failed + 1))
    failed_list="$failed_list WorkspaceDependencies"
elif [ -z "$expected_lock_sha" ]; then
    echo "  失败: manifest.txt 未记录依赖锁 SHA256，请先运行 save.sh"
    failed=$((failed + 1))
    failed_list="$failed_list WorkspaceDependencies"
else
    actual_snapshot_sha="$(shasum -a 256 "$LOCK_SNAPSHOT" | awk '{print $1}')"
    if [ "$actual_snapshot_sha" != "$expected_lock_sha" ]; then
        echo "  失败: 依赖锁快照校验不通过，拒绝覆盖当前文件"
        echo "  期望: $expected_lock_sha"
        echo "  实际: $actual_snapshot_sha"
        failed=$((failed + 1))
        failed_list="$failed_list WorkspaceDependencies"
    elif [ -f "$DEPENDENCY_LOCK" ] && cmp -s "$LOCK_SNAPSHOT" "$DEPENDENCY_LOCK"; then
        echo "  跳过: 依赖锁与保存的快照一致"
        skipped=$((skipped + 1))
    else
        echo "  检测到依赖锁漂移，准备恢复保存的快照"
        backup_ready=1
        if [ -f "$DEPENDENCY_LOCK" ]; then
            if backup_path="$(mktemp "${TMPDIR:-/tmp}/LoopWorkspace-Package.resolved.bak.XXXXXX")" && cp "$DEPENDENCY_LOCK" "$backup_path"; then
                echo "  当前依赖锁已备份到: $backup_path"
            else
                echo "  失败: 无法备份当前依赖锁，拒绝覆盖"
                backup_ready=0
            fi
        fi

        if [ "$backup_ready" = "1" ] && cp "$LOCK_SNAPSHOT" "$DEPENDENCY_LOCK" && cmp -s "$LOCK_SNAPSHOT" "$DEPENDENCY_LOCK"; then
            echo "  恢复成功"
            ok=$((ok + 1))
        else
            echo "  恢复失败: WorkspaceDependencies"
            failed=$((failed + 1))
            failed_list="$failed_list WorkspaceDependencies"
        fi
    fi
fi

while IFS=$'\t' read -r sm head_sha recorded_sha remote_url; do
    case "$sm" in \#*|"") continue ;; esac

    patch_file="$PATCH_DIR/${sm}.patch"
    echo "=== $sm ==="

    if [ ! -f "$patch_file" ]; then
        echo "  跳过: 补丁文件不存在"
        skipped=$((skipped + 1))
        continue
    fi

    if [ ! -e "$ROOT/$sm/.git" ]; then
        echo "  跳过: 子模块未初始化，请先运行 git submodule update --init --recursive"
        skipped=$((skipped + 1))
        continue
    fi

    cd "$ROOT/$sm"

    if [ "$DO_CHECKOUT" = "1" ]; then
        current="$(git rev-parse HEAD)"
        if [ "$current" != "$head_sha" ]; then
            echo "  切换到基线版本 ${head_sha:0:8}"
            git fetch origin --quiet 2>/dev/null || true
            git checkout --quiet "$head_sha" || echo "  警告: 切换失败，继续在当前版本上应用"
        fi
    fi

    # 已经应用过就不重复应用
    if git apply --reverse --check "$patch_file" > /dev/null 2>&1; then
        echo "  跳过: 补丁已经应用过了"
        skipped=$((skipped + 1))
        cd "$ROOT"
        continue
    fi

    # --3way: 子模块版本和基线不同时仍能做三方合并，冲突会标记在文件里
    # --whitespace=nowarn: 原样还原，不要"修正"尾部空白，保证和原始文件字节级一致
    if git apply --3way --whitespace=nowarn "$patch_file" 2>&1 | sed 's/^/  /'; then
        echo "  应用成功"
        ok=$((ok + 1))
    else
        echo "  应用失败或有冲突，需要手工处理: $sm"
        failed=$((failed + 1))
        failed_list="$failed_list $sm"
    fi

    cd "$ROOT"
done < "$MANIFEST"

echo ""
echo "结果: 成功 $ok / 跳过 $skipped / 失败 $failed"
if [ -n "$failed_list" ]; then
    echo "需要手工处理的项目:$failed_list"
    echo "子模块冲突文件里会有 <<<<<<< 标记，用 git status 查看。"
fi
