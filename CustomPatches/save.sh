#!/bin/bash
#
# save.sh - 把所有子模块的本地改动导出成补丁文件
#
# 用法: ./CustomPatches/save.sh
#
# 每次在子模块里改完代码后跑一次，补丁会被重新生成（全量覆盖旧补丁）。
# 生成的补丁 + manifest.txt 属于主仓库，需要 commit 后推到自己的 fork。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_DIR="$SCRIPT_DIR/patches"
MANIFEST="$SCRIPT_DIR/manifest.txt"

cd "$ROOT"
mkdir -p "$PATCH_DIR"
rm -f "$PATCH_DIR"/*.patch

{
    echo "# 子模块改动清单 - 由 save.sh 自动生成，请勿手工编辑"
    echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# 字段: 子模块路径 <TAB> 生成补丁时的HEAD <TAB> 主仓库记录的commit <TAB> 远端地址"
} > "$MANIFEST"

count=0

# 从 .gitmodules 读取所有子模块路径
while read -r _key sm; do
    [ -e "$ROOT/$sm/.git" ] || continue

    cd "$ROOT/$sm"

    # 没有任何改动的子模块直接跳过
    if [ -z "$(git status --porcelain)" ]; then
        cd "$ROOT"
        continue
    fi

    # 备份 index，生成补丁后原样还原（保住已 staged 的文件状态）
    index_file="$(git rev-parse --absolute-git-dir)/index"
    index_backup="${index_file}.custompatches.bak"
    cp "$index_file" "$index_backup"

    # intent-to-add: 让未跟踪的新文件也能进入 diff，不产生 commit
    git add -N . > /dev/null 2>&1 || true

    # --binary 保证图片等二进制文件也能正确记录
    git diff HEAD --binary > "$PATCH_DIR/${sm}.patch"

    # 还原 index 到操作前的状态
    mv -f "$index_backup" "$index_file"

    head_sha="$(git rev-parse HEAD)"
    recorded_sha="$(git -C "$ROOT" ls-tree HEAD -- "$sm" | awk '{print $3}')"
    remote_url="$(git remote get-url origin 2>/dev/null || echo 'unknown')"

    printf '%s\t%s\t%s\t%s\n' "$sm" "$head_sha" "$recorded_sha" "$remote_url" >> "$MANIFEST"

    changed="$(grep -c '^+++ ' "$PATCH_DIR/${sm}.patch" || true)"
    echo "已导出 $sm (${changed} 个文件)"
    count=$((count + 1))

    cd "$ROOT"
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')

echo ""
echo "完成: 共导出 $count 个子模块的补丁到 CustomPatches/patches/"
echo "下一步: 在主仓库 commit 并 push 到自己的 fork"
