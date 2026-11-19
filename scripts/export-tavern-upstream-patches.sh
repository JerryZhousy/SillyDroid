#!/usr/bin/env bash
set -euo pipefail

# Tool Contract: Upstream Patch Export (development-time, not part of stages 1-4)
# Responsibilities:
# - Rebase a fork's own commits onto a pinned upstream SillyTavern tag and export them as a patch series.
# - Write patches/tavern/<base-tag>/*.patch plus series.json (base tag, source repo/ref/head, patch count, series sha256, groups).
# Must not:
# - Be invoked by any stage script or workflow.
# - Modify the SillyDroid working tree outside the target patch directory.
# - Emit a series that does not rebase cleanly onto the requested base tag.

usage() {
    cat <<'EOF'
Usage: export-tavern-upstream-patches.sh --base-tag <tag> [options]

说明：
- 从上游 tag 的源码基线重放 fork 自有提交，导出 git format-patch 补丁序列与 series.json。
- 这是开发期工具，不参与 stage 1-4 构建。

选项：
  --base-tag <tag>        上游 SillyTavern tag，作为补丁基线（必填），例如 1.19.0
  --source-repo <owner/repo>  fork 仓库，默认 shalistera/sillytavern
  --source-ref <ref>      fork 分支，默认 release
  --upstream-base <sha>   fork 起点的上游提交；默认自动探测（fork 首个父链上已存在于上游的提交的父节点）
  --output-dir <path>     补丁输出目录，默认 <repo>/patches/tavern/<base-tag>
  --work-dir <path>       克隆工作目录，默认 <cache>/sillydroid-tavern-patch-export/<owner-repo>
  -h, --help              显示帮助
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_root="$(cd "$script_dir/.." && pwd)"

base_tag=''
source_repo='shalistera/sillytavern'
source_ref='release'
upstream_base=''
output_dir=''
work_dir=''

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-tag)
            base_tag="$2"
            shift 2
            ;;
        --source-repo)
            source_repo="$2"
            shift 2
            ;;
        --source-ref)
            source_ref="$2"
            shift 2
            ;;
        --upstream-base)
            upstream_base="$2"
            shift 2
            ;;
        --output-dir)
            output_dir="$2"
            shift 2
            ;;
        --work-dir)
            work_dir="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unsupported argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$base_tag" ]]; then
    echo '缺少 --base-tag。' >&2
    usage >&2
    exit 1
fi

for command_name in git python3 sha256sum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "缺少命令：$command_name" >&2
        exit 1
    fi
done

safe_repo="${source_repo//\//-}"
if [[ -z "$output_dir" ]]; then
    output_dir="$workspace_root/patches/tavern/$base_tag"
fi
if [[ -z "$work_dir" ]]; then
    work_dir="${XDG_CACHE_HOME:-$HOME/.cache}/sillydroid-tavern-patch-export/$safe_repo"
fi

fork_url="https://github.com/${source_repo}.git"
upstream_url='https://github.com/SillyTavern/SillyTavern.git'
export_branch='sillydroid-export'

mkdir -p "$work_dir"

if [[ ! -d "$work_dir/fork/.git" ]]; then
    echo "==> clone $source_repo into $work_dir/fork"
    git clone --filter=blob:none --single-branch --branch "$source_ref" "$fork_url" "$work_dir/fork"
fi

cd "$work_dir/fork"

if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "$upstream_url"
fi

echo "==> fetch $source_repo/$source_ref"
git fetch --filter=blob:none origin "+refs/heads/${source_ref}:refs/remotes/origin/${source_ref}"

echo "==> fetch upstream tag $base_tag"
git fetch --filter=blob:none upstream "refs/tags/${base_tag}:refs/tags/${base_tag}"

source_head="$(git rev-parse "refs/remotes/origin/${source_ref}")"

git checkout --quiet --detach "$source_head"
git branch -f "$export_branch" "$source_head" >/dev/null
git checkout --quiet "$export_branch"

if [[ -z "$upstream_base" ]]; then
    # 沿 fork 首个父链向下找第一个已存在于上游 tag 的提交，取其子提交作为 fork 起点。
    mapfile -t first_parent_chain < <(git rev-list --first-parent "$export_branch")
    base_index=-1
    for index in "${!first_parent_chain[@]}"; do
        if git merge-base --is-ancestor "${first_parent_chain[$index]}" "refs/tags/${base_tag}" 2>/dev/null; then
            base_index="$index"
            break
        fi
    done
    if [[ "$base_index" -le 0 ]]; then
        echo "无法探测 ${source_repo} 相对 ${base_tag} 的 fork 起点，请显式传 --upstream-base。" >&2
        exit 1
    fi
    upstream_base="${first_parent_chain[$((base_index - 1))]}"
fi

echo "==> source head : $source_head"
echo "==> upstream base: $upstream_base"
echo "==> rebase --onto $base_tag $upstream_base $export_branch"

if ! git rebase --onto "refs/tags/${base_tag}" "$upstream_base" "$export_branch"; then
    echo "补丁序列无法干净落到 ${base_tag} 上，已中止。请人工处理冲突后重试。" >&2
    git rebase --abort >/dev/null 2>&1 || true
    exit 1
fi

patch_count="$(git rev-list --count "refs/tags/${base_tag}..${export_branch}")"
if [[ "$patch_count" -le 0 ]]; then
    echo "${source_repo} 相对 ${base_tag} 没有需要导出的提交。" >&2
    exit 1
fi

mkdir -p "$output_dir"
rm -f "$output_dir"/*.patch

echo "==> format-patch $patch_count commits into $output_dir"
git format-patch --quiet --zero-commit --no-signature -o "$output_dir" "refs/tags/${base_tag}..${export_branch}"

python3 - "$output_dir" "$base_tag" "$source_repo" "$source_ref" "$source_head" "$upstream_base" "$patch_count" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

output_dir = pathlib.Path(sys.argv[1])
base_tag, source_repo, source_ref, source_head, upstream_base, patch_count = sys.argv[2:8]
patch_count = int(patch_count)

# 分类规则按顺序匹配，命中即止；未命中归入 perf。
GROUP_RULES = [
    ("docs", re.compile(r"^(Document|Add .*documentation)", re.I)),
    ("feature", re.compile(r"(native Vertex|custom model IDs|vertex)", re.I)),
    ("fix", re.compile(r"^(Prevent|Avoid|Settle|Preserve|Keep|Release|Fix|Stop)", re.I)),
    ("perf", re.compile(r".")),
]

patches = sorted(output_dir.glob("*.patch"))
if len(patches) != patch_count:
    raise SystemExit(f"补丁文件数 {len(patches)} 与提交数 {patch_count} 不一致")

digest = hashlib.sha256()
entries = []
for patch_file in patches:
    raw = patch_file.read_bytes()
    digest.update(raw)
    text = raw.decode("utf-8", errors="replace")
    subject_match = re.search(r"^Subject: \[PATCH[^\]]*\] (.+)$", text, re.M)
    subject = subject_match.group(1).strip() if subject_match else patch_file.stem
    from_match = re.search(r"^From ([0-9a-f]{40}) ", text, re.M)
    sha = from_match.group(1) if from_match else ""
    group = next(name for name, pattern in GROUP_RULES if pattern.search(subject))
    entries.append({
        "file": patch_file.name,
        "sha": sha,
        "subject": subject,
        "group": group,
        "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    })

groups = {}
for entry in entries:
    groups.setdefault(entry["group"], []).append(entry["subject"])

payload = {
    "schemaVersion": 1,
    "setId": f"{source_repo.replace('/', '-')}-{base_tag}",
    "baseTag": base_tag,
    "sourceRepo": source_repo,
    "sourceRef": source_ref,
    "sourceHead": source_head,
    "upstreamBase": upstream_base,
    "patchCount": patch_count,
    "seriesSha256": digest.hexdigest(),
    "groups": {name: len(items) for name, items in sorted(groups.items())},
    "groupMembers": {name: items for name, items in sorted(groups.items())},
    "patches": entries,
}

series_path = output_dir / "series.json"
series_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"wrote {series_path} ({patch_count} patches, seriesSha256={payload['seriesSha256']})")
print("groups: " + ", ".join(f"{name}={count}" for name, count in payload["groups"].items()))
PY
