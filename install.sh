#!/usr/bin/env bash
# Install agent-orchestration skills and local configuration.
# Compatible with the bash 3.2 that ships with macOS.

set -euo pipefail

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
TEMPLATES_DIR="$REPO_ROOT/templates"
CONFIG_DIR="${AGENT_ORCH_HOME:-$HOME/.config/agent-orchestration}"
CLAUDE_SKILLS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
CODEX_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"

MODE="link"
WITH_CODEX=0
PROJECT_DIR=""
PROJECT_ONLY=0
CHECK_ONLY=0

INSTALLED_NOTES=()
SKIPPED_NOTES=()
BACKUP_NOTES=()

usage() {
    cat <<'EOF'
用法: ./install.sh [选项]

默认把 skills/ 下的每个 skill 以符号链接安装到 Claude 配置目录；
所有安装动作都是幂等的，重复运行不会产生额外变更。

选项:
  --copy               复制 skill（而不是创建符号链接）
  --codex              同时安装到 ${CODEX_HOME:-$HOME/.codex}/skills/
  --project DIR        初始化项目目录（可与默认安装一起执行）
  --project-only DIR   只初始化项目目录，不安装 skill、不创建配置
  --check              只检查，不修改任何文件；运行离线测试并报告状态
  -h, --help           显示本帮助

环境变量:
  CLAUDE_CONFIG_DIR    Claude 配置目录（默认: ~/.claude）
  CODEX_HOME           Codex 配置目录（默认: ~/.codex）
  AGENT_ORCH_HOME      本工具的配置目录
                       （默认: ~/.config/agent-orchestration）
EOF
}

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

usage_error() {
    printf '错误: %s\n' "$*" >&2
    usage >&2
    exit 2
}

require_python3() {
    if ! command -v python3 >/dev/null 2>&1; then
        printf '错误: 未找到 python3。请先安装 Python 3 再运行本脚本。\n' >&2
        exit 1
    fi
}

record_installed() {
    INSTALLED_NOTES[${#INSTALLED_NOTES[@]}]="$1"
}

record_skipped() {
    SKIPPED_NOTES[${#SKIPPED_NOTES[@]}]="$1"
}

record_backup() {
    BACKUP_NOTES[${#BACKUP_NOTES[@]}]="$1"
}

# Follow a directory symlink and compare its physical location with $2.
link_matches() {
    # $1 = link path, $2 = physical source directory
    [ -L "$1" ] || return 1
    [ -d "$1" ] || return 1
    link_actual="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
    [ "$link_actual" = "$2" ]
}

backup_target() {
    target="$1"
    stamp="$(date +%Y%m%d%H%M%S)"
    backup="$target.bak-$stamp"
    suffix=1
    while [ -e "$backup" ] || [ -L "$backup" ]; do
        backup="$target.bak-$stamp-$suffix"
        suffix=$((suffix + 1))
    done
    mv "$target" "$backup"
    printf '备份: %s -> %s\n' "$target" "$backup"
    record_backup "$target -> $backup"
}

install_skill() {
    # $1 = destination label, $2 = destination skills dir, $3 = skill name,
    # $4 = physical source dir, $5 = link|copy
    dest_label="$1"
    dest_root="$2"
    name="$3"
    source_dir="$4"
    install_mode="$5"
    target="$dest_root/$name"

    mkdir -p "$dest_root"
    dest_root_abs="$(cd "$dest_root" && pwd -P)"
    if [ "$dest_root_abs/$name" = "$source_dir" ]; then
        printf '跳过: 目标与源目录相同，不安装到仓库自身: %s\n' "$target"
        record_skipped "$dest_label: ${name}（目标即源目录）"
        return 0
    fi

    if [ "$install_mode" = "link" ]; then
        if link_matches "$target" "$source_dir"; then
            printf '跳过: %s 已链接到 %s\n' "$target" "$source_dir"
            record_skipped "$dest_label: ${name}（已链接）"
            return 0
        fi

        if [ -e "$target" ] || [ -L "$target" ]; then
            backup_target "$target"
        fi

        ln -s "$source_dir" "$target"
        printf '链接: %s -> %s\n' "$target" "$source_dir"
        record_installed "$dest_label: ${name}（符号链接）"
        return 0
    fi

    # Copy mode. A copy made by this script carries a marker and may be
    # replaced in place; everything else is backed up first.
    if [ -d "$target" ] && [ ! -L "$target" ] && [ -f "$target/.agent-orchestration-copy" ]; then
        rm -rf "$target"
        printf '替换: %s（上次由本脚本复制）\n' "$target"
    elif [ -e "$target" ] || [ -L "$target" ]; then
        backup_target "$target"
    fi

    cp -R "$source_dir" "$target"
    {
        printf 'source=%s\n' "$source_dir"
        printf 'installed_at=%s\n' "$(date +%Y%m%d%H%M%S)"
    } > "$target/.agent-orchestration-copy"
    printf '复制: %s -> %s\n' "$target" "$source_dir"
    record_installed "$dest_label: ${name}（复制）"
}

install_skills() {
    if [ ! -d "$REPO_ROOT/skills" ]; then
        die "找不到 skills 目录: $REPO_ROOT/skills"
    fi

    skills_found=0
    for source in "$REPO_ROOT"/skills/*; do
        [ -d "$source" ] || continue
        skills_found=$((skills_found + 1))
        name="$(basename "$source")"
        source_dir="$(cd "$source" && pwd -P)"

        install_skill "Claude" "$CLAUDE_SKILLS_DIR" "$name" "$source_dir" "$MODE"
        if [ "$WITH_CODEX" = "1" ]; then
            install_skill "Codex" "$CODEX_SKILLS_DIR" "$name" "$source_dir" "$MODE"
        fi
    done

    if [ "$skills_found" -eq 0 ]; then
        printf '提示: skills/ 下没有可安装的 skill 目录。\n'
    fi
}

configure_agent_orchestration() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
        chmod 700 "$CONFIG_DIR"
        printf '创建配置目录: %s（权限 700）\n' "$CONFIG_DIR"
    else
        printf '配置目录已存在: %s\n' "$CONFIG_DIR"
    fi

    config_file="$CONFIG_DIR/config.json"
    config_template="$TEMPLATES_DIR/config.example.json"
    if [ -e "$config_file" ] || [ -L "$config_file" ]; then
        printf '保留现有: %s\n' "$config_file"
    else
        [ -f "$config_template" ] || die "找不到配置模板: $config_template"
        python3 - "$config_template" "$config_file" <<'PY'
import json
import os
import shutil
import sys

template_path, output_path = sys.argv[1], sys.argv[2]
with open(template_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

commands = {
    "deepseek": "dsh",
    "codex": "codex",
    "claude": "claude",
}
cli = data.setdefault("cli", {})
for key, command in commands.items():
    raw = cli.get(key, "")
    candidate = os.path.expanduser(raw) if isinstance(raw, str) else ""
    if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
        chosen = candidate
    else:
        chosen = shutil.which(command) or ""
    cli[key] = chosen

with open(output_path, "x", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
        printf '生成配置: %s\n' "$config_file"
    fi

    auth_file="$CONFIG_DIR/authorizations.md"
    auth_template="$TEMPLATES_DIR/authorizations.example.md"
    if [ -e "$auth_file" ] || [ -L "$auth_file" ]; then
        printf '保留现有: %s\n' "$auth_file"
    else
        [ -f "$auth_template" ] || die "找不到授权模板: $auth_template"
        cp "$auth_template" "$auth_file"
        printf '生成授权记录: %s\n' "$auth_file"
    fi
}

append_project_snippet() {
    claude_file="$1"
    snippet_file="$TEMPLATES_DIR/CLAUDE.md.snippet"

    [ -f "$snippet_file" ] || die "找不到 CLAUDE.md 片段: $snippet_file"

    if [ -e "$claude_file" ] || [ -L "$claude_file" ]; then
        if [ ! -f "$claude_file" ]; then
            die "$claude_file 已存在但不是普通文件。"
        fi
        if grep -q 'agent-orchestration:begin' "$claude_file"; then
            printf '保留现有: %s（已包含 agent-orchestration 片段）\n' "$claude_file"
            return 0
        fi
    fi

    if [ -s "$claude_file" ]; then
        # Terminate the last line if it has no newline.
        if [ "$(tail -c 1 "$claude_file" | wc -l | tr -d ' ')" -eq 0 ]; then
            printf '\n' >> "$claude_file"
        fi
        # Make sure there is one blank line before the appended section.
        last_two="$(tail -c 2 "$claude_file" | od -An -t u1 | tr -d ' \n')"
        if [ "$last_two" != "1010" ]; then
            printf '\n' >> "$claude_file"
        fi
    fi

    cat "$snippet_file" >> "$claude_file"
    printf '追加 CLAUDE.md 片段: %s\n' "$claude_file"
}

initialize_project() {
    project_dir="$1"
    [ -n "$project_dir" ] || die "项目目录不能为空。"

    mkdir -p "$project_dir/work" "$project_dir/outputs"
    printf '初始化项目: %s\n' "$project_dir"

    if [ -d "$TEMPLATES_DIR/project" ]; then
        while IFS= read -r source_file; do
            relative_path="${source_file#"$TEMPLATES_DIR/project/"}"
            destination="$project_dir/$relative_path"
            if [ -e "$destination" ] || [ -L "$destination" ]; then
                printf '跳过已有文件: %s\n' "$destination"
            else
                mkdir -p "$(dirname "$destination")"
                cp "$source_file" "$destination"
                printf '复制模板: %s\n' "$destination"
            fi
        done < <(find "$TEMPLATES_DIR/project" -type f -print)
    fi

    append_project_snippet "$project_dir/CLAUDE.md"
}

skill_status() {
    # $1 = target, $2 = physical source directory
    [ -L "$1" ] && {
        if link_matches "$1" "$2"; then
            printf '已链接'
        else
            printf '被占用（链接到别处）'
        fi
        return 0
    }
    if [ -d "$1" ]; then
        if [ -f "$1/.agent-orchestration-copy" ]; then
            printf '已复制'
        else
            printf '被占用（目录）'
        fi
        return 0
    fi
    if [ -e "$1" ]; then
        printf '被占用（文件）'
        return 0
    fi
    printf '缺失'
}

report_skills_for() {
    label="$1"
    skills_dir="$2"
    printf '\n%s skills 目录: %s\n' "$label" "$skills_dir"
    for source in "$REPO_ROOT"/skills/*; do
        [ -d "$source" ] || continue
        name="$(basename "$source")"
        source_dir="$(cd "$source" && pwd -P)"
        status="$(skill_status "$skills_dir/$name" "$source_dir")"
        printf '  %-24s %s\n' "$name" "$status"
    done
}

check_cli_paths() {
    config_file="$CONFIG_DIR/config.json"
    if [ ! -f "$config_file" ]; then
        printf '\nCLI 配置: 缺少 %s\n' "$config_file"
        return 0
    fi

    printf '\nCLI 配置: %s\n' "$config_file"
    if ! cli_lines="$(python3 - "$config_file" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
cli = data.get("cli", {})
for key in ("deepseek", "codex", "claude"):
    value = cli.get(key, "")
    value = os.path.expanduser(value) if isinstance(value, str) else ""
    print("{}\t{}".format(key, value))
PY
    )"; then
        printf '  无法解析 config.json（不是合法 JSON）。\n'
        return 0
    fi

    tab="$(printf '\t')"
    while IFS="$tab" read -r key path; do
        [ -n "$key" ] || continue
        command_name="$key"
        [ "$key" = "deepseek" ] && command_name="dsh"
        if [ -z "$path" ]; then
            printf '  %-8s 空（未探测到 %s）\n' "$key" "$command_name"
        elif [ -f "$path" ] && [ -x "$path" ]; then
            printf '  %-8s %s（可执行）\n' "$key" "$path"
        else
            printf '  %-8s %s（不存在或不可执行）\n' "$key" "$path"
        fi
    done <<EOF
$cli_lines
EOF
}

perform_check() {
    check_status=0

    printf '== 离线测试 ==\n'
    worker_test="$REPO_ROOT/skills/subagent-dispatch/tests/test_worker.py"
    progress_test="$REPO_ROOT/skills/subagent-dispatch/tests/check_progress_test/run_tests.sh"

    if [ -f "$worker_test" ]; then
        if python3 -B "$worker_test"; then
            printf '测试通过: test_worker.py\n'
        else
            printf '测试失败: test_worker.py\n' >&2
            check_status=1
        fi
    else
        printf '测试文件缺失: %s\n' "$worker_test" >&2
        check_status=1
    fi

    if [ -f "$progress_test" ]; then
        if PYTHONDONTWRITEBYTECODE=1 bash "$progress_test"; then
            printf '测试通过: check_progress_test/run_tests.sh\n'
        else
            printf '测试失败: check_progress_test/run_tests.sh\n' >&2
            check_status=1
        fi
    else
        printf '测试文件缺失: %s\n' "$progress_test" >&2
        check_status=1
    fi

    printf '\n== Skill 状态 ==\n'
    report_skills_for "Claude" "$CLAUDE_SKILLS_DIR"
    report_skills_for "Codex" "$CODEX_SKILLS_DIR"
    check_cli_paths

    if [ "$check_status" -eq 0 ]; then
        printf '\n检查完成: 离线测试全部通过。\n'
    else
        printf '\n检查完成: 有离线测试失败。\n' >&2
    fi
    return "$check_status"
}

print_summary() {
    printf '\n===== 摘要 =====\n'

    printf '已安装/更新:\n'
    if [ "${#INSTALLED_NOTES[@]}" -eq 0 ]; then
        printf '  （无）\n'
    else
        for note in "${INSTALLED_NOTES[@]}"; do
            printf '  - %s\n' "$note"
        done
    fi

    if [ "${#SKIPPED_NOTES[@]}" -gt 0 ]; then
        printf '已跳过（已是目标状态）:\n'
        for note in "${SKIPPED_NOTES[@]}"; do
            printf '  - %s\n' "$note"
        done
    fi

    printf '已备份:\n'
    if [ "${#BACKUP_NOTES[@]}" -eq 0 ]; then
        printf '  （无）\n'
    else
        for note in "${BACKUP_NOTES[@]}"; do
            printf '  - %s\n' "$note"
        done
    fi

    if [ "$PROJECT_ONLY" = "1" ]; then
        printf '配置目录: %s（--project-only 未改动）\n' "$CONFIG_DIR"
    else
        printf '配置目录: %s\n' "$CONFIG_DIR"
    fi
    if [ -n "$PROJECT_DIR" ]; then
        printf '项目目录: %s\n' "$PROJECT_DIR"
    fi

    printf '\n下一步: 在 Claude Code 里输入 /subagent-dispatch 或让它自动触发；新项目运行 ./install.sh --project-only <目录>\n'
}

# --- Parse arguments -------------------------------------------------------

require_python3

while [ "$#" -gt 0 ]; do
    case "$1" in
        --copy)
            MODE="copy"
            shift
            ;;
        --codex)
            WITH_CODEX=1
            shift
            ;;
        --project)
            [ "$#" -ge 2 ] || usage_error "--project 需要一个目录参数"
            PROJECT_DIR="$2"
            shift 2
            ;;
        --project-only)
            [ "$#" -ge 2 ] || usage_error "--project-only 需要一个目录参数"
            PROJECT_DIR="$2"
            PROJECT_ONLY=1
            shift 2
            ;;
        --check)
            CHECK_ONLY=1
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

if [ "$CHECK_ONLY" = "1" ]; then
    if perform_check; then
        exit 0
    fi
    exit 1
fi

if [ "$PROJECT_ONLY" = "1" ]; then
    initialize_project "$PROJECT_DIR"
    print_summary
    exit 0
fi

install_skills
configure_agent_orchestration
if [ -n "$PROJECT_DIR" ]; then
    initialize_project "$PROJECT_DIR"
fi
print_summary
