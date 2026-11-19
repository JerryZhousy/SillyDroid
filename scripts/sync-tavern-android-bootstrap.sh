#!/usr/bin/env bash
set -euo pipefail

# Stage Contract: 3/4 Server Source
# Responsibilities:
# - Sync the requested SillyTavern tag, apply the pinned source patch set when it is enabled and its base tag matches, then install npm runtime dependencies.
# - Produce only server-source.zip and server-source-manifest.json under artifacts/releases/server-source/<rid>/<tag>.
# - Record the applied patch set in server-source-manifest.json so downstream stages and CI can tell a patched pack from a pristine one.
# Must not:
# - Build dependency packs.
# - Inject Android host launcher scripts, the Node --require runtime patch framework, or mutable host bootstrap behavior.
# - Compose final server assets.
# - Assemble the APK or mutate stage-1/stage-2 outputs.
# - Apply a patch set whose baseTag differs from the requested tag, or let a patch set change npm dependency manifests.

runtime_rid="linux-arm64"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_root="$(cd "$script_dir/.." && pwd)"
target_root=''
working_root="${SILLYDROID_TAVERN_ANDROID_BOOTSTRAP_WORK_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/sillydroid-tavern-android-bootstrap}"
build_config_path="$workspace_root/sillydroid-build-config.json"

patch_disabled_by_flag='false'
patch_set_id=''

read_build_config_value() {
    local key_path="$1"
    local default_value="$2"

    if ! command -v python3 >/dev/null 2>&1; then
        printf '%s\n' "$default_value"
        return
    fi

    python3 "$workspace_root/scripts/read-sillydroid-build-config.py" "$build_config_path" "$key_path" "$default_value"
}

resolve_latest_tavern_tag() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo '缺少 python3，无法自动解析最新 SillyTavern release tag。' >&2
        exit 1
    fi

    python3 - <<'PY'
import json
import sys
import urllib.request

request = urllib.request.Request(
    'https://api.github.com/repos/SillyTavern/SillyTavern/releases/latest',
    headers={'User-Agent': 'SillyDroid-Android-Build'}
)
with urllib.request.urlopen(request) as response:
    payload = json.load(response)

tag_name = (payload.get('tag_name') or '').strip()
if not tag_name:
    print('无法解析最新 SillyTavern release tag。', file=sys.stderr)
    raise SystemExit(1)

print(tag_name)
PY
}

source_android_build_common() {
    local common_script="$workspace_root/scripts/android-build-common.sh"

    # Windows 工作树里的公共 bash 脚本可能是 CRLF；这里用临时 LF 副本加载，避免回写旧脚本。
    # shellcheck disable=SC1090
    source <(tr -d '\r' < "$common_script")
}

source_android_build_common

usage() {
    cat <<'EOF'
Usage: sync-tavern-android-bootstrap.sh [--tag <sillytavern-tag>] [--patch-set <id>] [--no-patches] [--runtime-rid linux-arm64] [--target-root <path>] [--working-root <path>]

说明：
- 未传 --tag 时优先读取仓库根目录 sillydroid-build-config.json 的 build.tavernVersion。
- build.tavernVersion 为 latest 或 auto 时，会自动解析上游最新 GitHub Release tag。
- 默认输出目录为 artifacts/releases/server-source/<rid>/<tag>。
- 源码补丁集由 build.tavernSourcePatches 配置；--no-patches 可强制跳过，--patch-set 可覆盖 setId。
- 补丁集只在 baseTag 与当前 tag 一致时应用，且会在 manifest 里记录 setId 与 seriesSha256。
- 该脚本只生成 Tavern server source；其中包含指定上游 tag 的源码（含已应用的源码补丁）与 npm 运行依赖，不包含宿主启动脚本、runtime patch、node/git dependency packs，也不生成最终 APK server assets。
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            SILLYDROID_TAVERN_TAG="$2"
            shift 2
            ;;
        --patch-set)
            patch_set_id="$2"
            shift 2
            ;;
        --no-patches)
            patch_disabled_by_flag='true'
            shift
            ;;
        --runtime-rid)
            runtime_rid="$2"
            shift 2
            ;;
        --target-root)
            target_root="$2"
            shift 2
            ;;
        --working-root)
            working_root="$2"
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

configured_tavern_tag="$(read_build_config_value 'build.tavernVersion' 'latest')"

if [[ -z "${SILLYDROID_TAVERN_TAG:-}" ]]; then
    SILLYDROID_TAVERN_TAG="$configured_tavern_tag"
fi

case "${SILLYDROID_TAVERN_TAG,,}" in
    ''|auto|latest)
        SILLYDROID_TAVERN_TAG="$(resolve_latest_tavern_tag)"
        ;;
esac

if [[ -z "$target_root" ]]; then
    target_root="$workspace_root/artifacts/releases/server-source/$runtime_rid/$SILLYDROID_TAVERN_TAG"
fi

case "$runtime_rid" in
    linux-arm64)
        ;;
    *)
        echo "Unsupported runtime RID: $runtime_rid" >&2
        exit 1
        ;;
esac

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//"/\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

# 补丁集配置：enabled / setId / baseTag / path / required 全部来自 sillydroid-build-config.json。
patch_set_enabled="$(read_build_config_value 'build.tavernSourcePatches.enabled' 'false')"
patch_base_tag="$(read_build_config_value 'build.tavernSourcePatches.baseTag' "$SILLYDROID_TAVERN_TAG")"
patch_rel_path="$(read_build_config_value 'build.tavernSourcePatches.path' "patches/tavern/$patch_base_tag")"
patch_required="$(read_build_config_value 'build.tavernSourcePatches.required' 'false')"
configured_patch_set_id="$(read_build_config_value 'build.tavernSourcePatches.setId' '')"

if [[ -z "$patch_set_id" ]]; then
    patch_set_id="$configured_patch_set_id"
fi

if [[ "$patch_disabled_by_flag" == 'true' ]]; then
    patch_set_enabled='false'
fi

patch_applied='false'
patch_skip_reason=''
patch_series_repo=''
patch_series_head=''
patch_series_sha=''
patch_series_count='0'
patch_dir_abs=''

abort_on_required_patch_failure() {
    local reason="$1"
    if [[ "$patch_required" == 'true' ]]; then
        echo "补丁集被标记为必需，但无法应用：$reason" >&2
        exit 1
    fi
    sillydroid_log "跳过源码补丁集：$reason"
    patch_skip_reason="$reason"
}

read_series_metadata() {
    local series_path="$1"
    local patch_dir="$2"

    python3 - "$series_path" "$patch_dir" <<'PY'
import hashlib
import json
import pathlib
import sys

series_path = pathlib.Path(sys.argv[1])
patch_dir = pathlib.Path(sys.argv[2])

if not series_path.is_file():
    raise SystemExit(f'missing series.json: {series_path}')

data = json.loads(series_path.read_text(encoding='utf-8'))
patches = sorted(patch_dir.glob('*.patch'))
if not patches:
    raise SystemExit(f'no patch files under {patch_dir}')

digest = hashlib.sha256()
for patch_file in patches:
    digest.update(patch_file.read_bytes())

expected_count = data.get('patchCount')
if expected_count != len(patches):
    raise SystemExit(f'patchCount mismatch: series.json says {expected_count}, found {len(patches)}')

expected_sha = data.get('seriesSha256') or ''
if expected_sha and expected_sha != digest.hexdigest():
    raise SystemExit(f'seriesSha256 mismatch: series.json says {expected_sha}, computed {digest.hexdigest()}')

print('|'.join([
    str(data.get('sourceRepo') or ''),
    str(data.get('sourceHead') or ''),
    digest.hexdigest(),
    str(len(patches)),
]))
PY
}

apply_tavern_source_patches() {
    if [[ "$patch_set_enabled" != 'true' ]]; then
        patch_skip_reason='disabled'
        sillydroid_log '源码补丁集未启用，按纯净上游源码打包。'
        return 0
    fi

    if [[ "$patch_base_tag" != "$SILLYDROID_TAVERN_TAG" ]]; then
        # baseTag 与目标 tag 不一致是正常情况（例如打包 1.18.0 时补丁集只覆盖 1.19.0），
        # 无论 required 与否都只跳过，不能因此让别的版本构建失败。
        patch_skip_reason="base_tag_mismatch($patch_base_tag != $SILLYDROID_TAVERN_TAG)"
        sillydroid_warn "跳过源码补丁集：$patch_skip_reason"
        return 0
    fi

    if [[ "$patch_rel_path" == /* ]]; then
        patch_dir_abs="$patch_rel_path"
    else
        patch_dir_abs="$workspace_root/$patch_rel_path"
    fi

    if [[ ! -d "$patch_dir_abs" ]]; then
        abort_on_required_patch_failure "missing_patch_dir($patch_rel_path)"
        return 0
    fi

    sillydroid_require_command git

    local series_output
    if ! series_output="$(read_series_metadata "$patch_dir_abs/series.json" "$patch_dir_abs" 2>&1)"; then
        abort_on_required_patch_failure "invalid_series($series_output)"
        return 0
    fi

    IFS='|' read -r patch_series_repo patch_series_head patch_series_sha patch_series_count <<< "$series_output"

    sillydroid_progress_stage 1 3 "开始应用源码补丁集 $patch_set_id（$patch_series_count 个补丁）"

    local patch_file
    local applied_count=0
    for patch_file in "$patch_dir_abs"/*.patch; do
        # core.autocrlf=false 保证补丁内容按 LF 原样落盘，避免 Windows 工作树把 CRLF 写进源码。
        if ! git -C "$payload_root" -c core.autocrlf=false -c core.eol=lf apply --check -p1 --whitespace=nowarn "$patch_file" 2>/dev/null; then
            abort_on_required_patch_failure "apply_check_failed($(basename "$patch_file"))"
            return 0
        fi
        if ! git -C "$payload_root" -c core.autocrlf=false -c core.eol=lf apply -p1 --whitespace=nowarn "$patch_file"; then
            abort_on_required_patch_failure "apply_failed($(basename "$patch_file"))"
            return 0
        fi
        applied_count=$((applied_count + 1))
    done

    patch_applied='true'
    sillydroid_log "源码补丁集已应用：$applied_count/$patch_series_count（setId=$patch_set_id）"
}

sillydroid_ensure_java_home
sillydroid_ensure_node
sillydroid_require_command tar
sillydroid_require_command find
sillydroid_require_command unzip
sillydroid_require_command sha256sum

resolved_target_root="$(realpath -m "$target_root")"
resolved_working_root="$(realpath -m "$working_root")"
downloads_root="$resolved_working_root/downloads"
source_root="$resolved_working_root/source"
payload_root="$resolved_working_root/payload"
archive_name="sillytavern-${SILLYDROID_TAVERN_TAG}.tar.gz"
source_archive_path="$downloads_root/$archive_name"
source_archive_url="https://github.com/SillyTavern/SillyTavern/archive/refs/tags/${SILLYDROID_TAVERN_TAG}.tar.gz"

mkdir -p "$downloads_root" "$resolved_target_root"
sillydroid_download_file_if_missing "$source_archive_url" "$source_archive_path"

rm -rf "$source_root" "$payload_root"
mkdir -p "$source_root"
sillydroid_extract_archive_with_progress "$source_archive_path" "$source_root" 'sillytavern-source'
resolved_source_root="$(find "$source_root" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)"
sillydroid_assert_path_exists "$resolved_source_root/package.json" "SillyTavern 源码解压失败：$source_archive_path"
payload_root="$resolved_source_root"

rm -rf "$payload_root/data" "$payload_root/backups" "$payload_root/node_modules"

# 补丁必须在 npm ci 之前应用：补丁集不允许改动 package.json/package-lock.json，
# 若将来出现依赖改动，先更新 lockfile 再导出补丁，避免 npm ci 与源码不一致。
apply_tavern_source_patches

sillydroid_progress_stage 2 3 "开始安装 Tavern npm 运行依赖（npm omit=dev）"
(
    cd "$payload_root"
    npm_cache_dir="$(sillydroid_toolchain_root)/npm-cache"
    mkdir -p "$npm_cache_dir"
    sillydroid_log "复用 npm 缓存目录：$npm_cache_dir"
    if [[ -f package-lock.json ]]; then
        npm ci --omit=dev --no-fund --no-audit --prefer-offline --progress=true --cache "$npm_cache_dir"
    else
        npm install --omit=dev --no-fund --no-audit --prefer-offline --progress=true --cache "$npm_cache_dir"
    fi

    # server-source.zip 会直接作为酒馆版本切换的可解包物料，必须带齐运行依赖。
    # 个别上游 lockfile 缺失 command-exists 时按 package.json 声明补装到当前 tag 的依赖树里。
    command_exists_version="$(node -p "const pkg = require('./package.json'); (pkg.dependencies && pkg.dependencies['command-exists']) || ''")"
    if [[ -z "$command_exists_version" ]]; then
        echo '无法解析运行依赖 command-exists 的版本声明。' >&2
        exit 1
    fi

    if [[ ! -d node_modules/command-exists ]]; then
        npm install --omit=dev --no-fund --no-audit --prefer-offline --progress=true --cache "$npm_cache_dir" --no-save "command-exists@${command_exists_version}"
    fi

    if [[ ! -d node_modules/command-exists ]]; then
        echo '缺少运行依赖 command-exists，扩展安装功能将不可用。' >&2
        exit 1
    fi
)

jar_path="$JAVA_HOME/bin/jar"
sillydroid_assert_path_exists "$jar_path" "缺少 jar 命令：$jar_path"
server_source_archive_path="$resolved_target_root/server-source.zip"
server_source_manifest_path="$resolved_target_root/server-source-manifest.json"
mapfile -t packaged_files < <(find "$payload_root" -type f -printf '%P\n' | LC_ALL=C sort)
rm -f "$server_source_archive_path" "$server_source_manifest_path"
sillydroid_progress_stage 3 3 "开始归档 Tavern server source 与 npm 运行依赖"
"$jar_path" --create --file "$server_source_archive_path" --no-manifest -C "$payload_root" .
server_source_archive_size_bytes="$(stat -c '%s' "$server_source_archive_path")"
server_source_archive_sha256="$(sha256sum "$server_source_archive_path" | awk '{print $1}')"

{
    printf '{\n'
    printf '  "package": "%s",\n' "$(json_escape "SillyTavernServerSource")"
    printf '  "payloadVersion": "%s",\n' "$(json_escape "$SILLYDROID_TAVERN_TAG")"
    printf '  "runtimeRid": "%s",\n' "$(json_escape "$runtime_rid")"
    printf '  "tag": "%s",\n' "$(json_escape "$SILLYDROID_TAVERN_TAG")"
    printf '  "includesNodeModules": true,\n'
    printf '  "installedRuntimeDependencies": true,\n'
    printf '  "sourceArchive": "%s",\n' "$(json_escape "$archive_name")"
    printf '  "archiveFile": "%s",\n' "$(json_escape "$(basename "$server_source_archive_path")")"
    printf '  "archivedFileCount": %s,\n' "${#packaged_files[@]}"
    printf '  "archiveSizeBytes": %s,\n' "$server_source_archive_size_bytes"
    printf '  "patches": {\n'
    printf '    "enabled": %s,\n' "$([[ "$patch_set_enabled" == 'true' ]] && printf 'true' || printf 'false')"
    printf '    "applied": %s,\n' "$([[ "$patch_applied" == 'true' ]] && printf 'true' || printf 'false')"
    printf '    "setId": "%s",\n' "$(json_escape "$patch_set_id")"
    printf '    "baseTag": "%s",\n' "$(json_escape "$patch_base_tag")"
    printf '    "path": "%s",\n' "$(json_escape "$patch_rel_path")"
    printf '    "required": %s,\n' "$([[ "$patch_required" == 'true' ]] && printf 'true' || printf 'false')"
    printf '    "sourceRepo": "%s",\n' "$(json_escape "$patch_series_repo")"
    printf '    "sourceHead": "%s",\n' "$(json_escape "$patch_series_head")"
    printf '    "patchCount": %s,\n' "${patch_series_count:-0}"
    printf '    "seriesSha256": "%s",\n' "$(json_escape "$patch_series_sha")"
    printf '    "skippedReason": "%s"\n' "$(json_escape "$patch_skip_reason")"
    printf '  },\n'
    printf '  "archiveSha256": "%s"\n' "$(json_escape "$server_source_archive_sha256")"
    printf '}\n'
} > "$server_source_manifest_path"

printf 'Packed %s tavern files for tag %s into %s\n' "${#packaged_files[@]}" "$SILLYDROID_TAVERN_TAG" "$server_source_archive_path"
if [[ "$patch_applied" == 'true' ]]; then
    printf 'Applied source patch set %s (%s patches) onto %s\n' "$patch_set_id" "$patch_series_count" "$SILLYDROID_TAVERN_TAG"
else
    printf 'Source patch set not applied: %s\n' "${patch_skip_reason:-disabled}"
fi
