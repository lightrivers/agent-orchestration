#!/usr/bin/env bash
# Uninstall agent-orchestration skills owned by this repository.
# Compatible with the bash 3.2 that ships with macOS.

set -euo pipefail

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
CONFIG_DIR="${AGENT_ORCH_HOME:-$HOME/.config/agent-orchestration}"
CLAUDE_SKILLS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
CODEX_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"

PURGE=0

usage() {
    cat <<'EOF'
用法: ./uninstall.sh [选项]

只删除指向本仓库的 skill 符号链接，以及带
.agent-orchestration-copy 标记的复制目录（Claude 和 Codex 两处）。
其他文件一律不碰；配置目录默认保留。

选项:
  --purge      同时删除 ${AGENT_ORCH_HOME:-$HOME/.config/agent-orchestration}
  -h, --help   显示本帮助

环境变量:
  CLAUDE_CONFIG_DIR    Claude 配置目录（默认: ~/.claude）
  CODEX_HOME           Codex 配置目录（默认: ~/.codex）
  AGENT_ORCH_HOME      本工具的配置目录
                       （默认: ~/.config/agent-orchestration）
EOF
}

usage_error() {
    printf '错误: %s\n' "$*" >&2
    usage >&2
    exit 2
}

link_matches() {
    # $1 = link path, $2 = physical source directory
    [ -L "$1" ] || return 1
    [ -d "$1" ] || return 1
    link_actual="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
    [ "$link_actual" = "$2" ]
}

remove_from_skills_dir() {
    label="$1"
    skills_dir="$2"

    [ -d "$skills_dir" ] || return 0

    for source in "$REPO_ROOT"/skills/*; do
        [ -d "$source" ] || continue
        name="$(basename "$source")"
        source_dir="$(cd "$source" && pwd -P)"
        target="$skills_dir/$name"

        if [ -L "$target" ]; then
            if link_matches "$target" "$source_dir"; then
                rm "$target"
                printf '删除 %s 链接: %s\n' "$label" "$target"
            else
                printf '保留 %s（不是指向本仓库的链接）: %s\n' "$label" "$target"
            fi
        elif [ -d "$target" ] && [ -f "$target/.agent-orchestration-copy" ]; then
            rm -rf "$target"
            printf '删除 %s 复制目录: %s\n' "$label" "$target"
        elif [ -e "$target" ] || [ -L "$target" ]; then
            printf '保留 %s（不是本脚本安装的）: %s\n' "$label" "$target"
        fi
    done
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --purge)
            PURGE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage_error "未知参数: $1"
            ;;
    esac
done

remove_from_skills_dir "Claude" "$CLAUDE_SKILLS_DIR"
remove_from_skills_dir "Codex" "$CODEX_SKILLS_DIR"

if [ "$PURGE" = "1" ]; then
    case "$CONFIG_DIR" in
        ""|"/"|"."|"..")
            printf '错误: 拒绝删除不安全的配置路径: %s\n' "$CONFIG_DIR" >&2
            exit 1
            ;;
    esac
    if [ -e "$CONFIG_DIR" ] || [ -L "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR"
        printf '已删除配置目录: %s\n' "$CONFIG_DIR"
    else
        printf '配置目录不存在: %s\n' "$CONFIG_DIR"
    fi
else
    printf '配置目录保留: %s\n' "$CONFIG_DIR"
fi
