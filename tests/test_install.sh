#!/usr/bin/env bash
# Offline tests for install.sh / uninstall.sh.
# Uses a temporary HOME and temporary config directories; never touches the
# real home directory. Do not run install.sh --check from here.

set -uo pipefail

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
UNINSTALL="$REPO_ROOT/uninstall.sh"
TEMPLATES_DIR="$REPO_ROOT/templates"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-orchestration-install-test.XXXXXX")"
FAILURES=0
CASE_FAILED=0
CASE_NUMBER=0
CASE_BASE=""
CASE_LOG=""
HOME=""
CLAUDE_CONFIG_DIR=""
CODEX_HOME=""
AGENT_ORCH_HOME=""

cleanup() {
    if [ -n "${TEST_ROOT:-}" ] && [ -d "$TEST_ROOT" ]; then
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT

fail() {
    CASE_FAILED=1
    printf '  FAIL: %s\n' "$*"
}

assert_file() {
    if [ ! -f "$1" ]; then
        fail "文件不存在: $1"
        return 1
    fi
}

assert_dir() {
    if [ ! -d "$1" ]; then
        fail "目录不存在: $1"
        return 1
    fi
}

assert_missing() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail "路径仍然存在: $1"
        return 1
    fi
}

assert_link_to() {
    path="$1"
    expected="$2"
    if [ ! -L "$path" ]; then
        fail "不是符号链接: $path"
        return 1
    fi
    actual="$(readlink "$path")"
    if [ "$actual" != "$expected" ]; then
        fail "链接目标不正确: $path -> ${actual}（期望 ${expected}）"
        return 1
    fi
}

assert_not_link() {
    if [ -L "$1" ]; then
        fail "不应是符号链接: $1"
        return 1
    fi
}

setup_case() {
    CASE_NUMBER=$((CASE_NUMBER + 1))
    CASE_BASE="$TEST_ROOT/case-$CASE_NUMBER"
    HOME="$CASE_BASE/home"
    CLAUDE_CONFIG_DIR="$CASE_BASE/claude"
    CODEX_HOME="$CASE_BASE/codex"
    AGENT_ORCH_HOME="$CASE_BASE/config"
    CASE_LOG="$CASE_BASE/command.log"
    mkdir -p "$HOME" "$CASE_BASE"
    export HOME CLAUDE_CONFIG_DIR CODEX_HOME AGENT_ORCH_HOME
}

run_install() {
    if "$INSTALL" "$@" >"$CASE_LOG" 2>&1; then
        return 0
    fi
    fail "install.sh 执行失败: $*"
    sed 's/^/    /' "$CASE_LOG"
    return 1
}

run_uninstall() {
    if "$UNINSTALL" "$@" >"$CASE_LOG" 2>&1; then
        return 0
    fi
    fail "uninstall.sh 执行失败: $*"
    sed 's/^/    /' "$CASE_LOG"
    return 1
}

backup_count() {
    find "$1" -name '*.bak-*' -print 2>/dev/null | wc -l | tr -d ' '
}

skill_source() {
    printf '%s/skills/%s' "$REPO_ROOT" "$1"
}

test_default_install() {
    setup_case
    if ! run_install; then
        return 0
    fi

    assert_link_to "$CLAUDE_CONFIG_DIR/skills/subagent-dispatch" "$(skill_source subagent-dispatch)"
    assert_link_to "$CLAUDE_CONFIG_DIR/skills/session-orchestration" "$(skill_source session-orchestration)"

    config_file="$AGENT_ORCH_HOME/config.json"
    assert_file "$config_file"
    if [ -f "$config_file" ]; then
        if ! python3 - "$config_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
cli = data.get("cli")
assert isinstance(cli, dict), "cli must be an object"
for key in ("deepseek", "codex", "claude"):
    assert key in cli, "missing cli.{}".format(key)
assert "protected_paths" in data, "missing protected_paths"
PY
        then
            fail "config.json 不是合法 JSON，或缺少 cli/protected_paths"
        fi
    fi

    assert_file "$AGENT_ORCH_HOME/authorizations.md"

    config_mode="$(python3 - "$AGENT_ORCH_HOME" <<'PY'
import os
import sys

print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])
PY
)"
    if [ "$config_mode" != "700" ]; then
        fail "配置目录权限是 ${config_mode}，期望 700"
    fi

    if [ -e "$HOME/.claude" ]; then
        fail "HOME 下出现了 .claude，环境变量隔离失败"
    fi
}

test_idempotent() {
    setup_case
    if ! run_install; then
        return 0
    fi

    link_one="$(readlink "$CLAUDE_CONFIG_DIR/skills/subagent-dispatch")"
    link_two="$(readlink "$CLAUDE_CONFIG_DIR/skills/session-orchestration")"
    config_before="$(cksum < "$AGENT_ORCH_HOME/config.json")"
    auth_before="$(cksum < "$AGENT_ORCH_HOME/authorizations.md")"

    if ! run_install; then
        return 0
    fi

    if [ "$(readlink "$CLAUDE_CONFIG_DIR/skills/subagent-dispatch")" != "$link_one" ]; then
        fail "重复安装改变了 subagent-dispatch 链接"
    fi
    if [ "$(readlink "$CLAUDE_CONFIG_DIR/skills/session-orchestration")" != "$link_two" ]; then
        fail "重复安装改变了 session-orchestration 链接"
    fi
    if [ "$(cksum < "$AGENT_ORCH_HOME/config.json")" != "$config_before" ]; then
        fail "重复安装改写了 config.json"
    fi
    if [ "$(cksum < "$AGENT_ORCH_HOME/authorizations.md")" != "$auth_before" ]; then
        fail "重复安装改写了 authorizations.md"
    fi

    count="$(backup_count "$CLAUDE_CONFIG_DIR")"
    if [ "$count" -ne 0 ]; then
        fail "重复安装产生了 $count 个 .bak 备份"
    fi
}

test_existing_directory_is_backed_up() {
    setup_case
    mkdir -p "$CLAUDE_CONFIG_DIR/skills/session-orchestration"
    printf 'sentinel\n' > "$CLAUDE_CONFIG_DIR/skills/session-orchestration/sentinel.txt"

    if ! run_install; then
        return 0
    fi

    assert_link_to "$CLAUDE_CONFIG_DIR/skills/session-orchestration" "$(skill_source session-orchestration)"

    found=0
    for candidate in "$CLAUDE_CONFIG_DIR"/skills/session-orchestration.bak-*; do
        [ -d "$candidate" ] || continue
        found=1
        if [ ! -f "$candidate/sentinel.txt" ]; then
            fail "备份目录里没有原文件内容: $candidate"
        fi
    done
    if [ "$found" -eq 0 ]; then
        fail "没有找到 session-orchestration.bak-* 备份目录"
    fi
}

test_codex_install() {
    setup_case
    if ! run_install --codex; then
        return 0
    fi

    assert_link_to "$CLAUDE_CONFIG_DIR/skills/subagent-dispatch" "$(skill_source subagent-dispatch)"
    assert_link_to "$CLAUDE_CONFIG_DIR/skills/session-orchestration" "$(skill_source session-orchestration)"
    assert_link_to "$CODEX_HOME/skills/subagent-dispatch" "$(skill_source subagent-dispatch)"
    assert_link_to "$CODEX_HOME/skills/session-orchestration" "$(skill_source session-orchestration)"
}

test_copy_mode() {
    setup_case
    if ! run_install --copy; then
        return 0
    fi

    for name in subagent-dispatch session-orchestration; do
        target="$CLAUDE_CONFIG_DIR/skills/$name"
        assert_not_link "$target"
        assert_dir "$target"
        assert_file "$target/.agent-orchestration-copy"
    done

    count="$(backup_count "$CLAUDE_CONFIG_DIR")"
    if [ "$count" -ne 0 ]; then
        fail "首次 --copy 不应产生备份，实际有 $count 个"
    fi

    if ! run_install --copy; then
        return 0
    fi

    for name in subagent-dispatch session-orchestration; do
        target="$CLAUDE_CONFIG_DIR/skills/$name"
        assert_not_link "$target"
        assert_dir "$target"
        assert_file "$target/.agent-orchestration-copy"
    done

    count="$(backup_count "$CLAUDE_CONFIG_DIR")"
    if [ "$count" -ne 0 ]; then
        fail "再次 --copy 不应产生备份，实际有 $count 个"
    fi
}

test_project_only() {
    setup_case
    project="$CASE_BASE/project"
    mkdir -p "$project"
    printf '原有项目内容，保留我\n第二行没有结尾换行' > "$project/CLAUDE.md"

    if ! run_install --project-only "$project"; then
        return 0
    fi

    assert_dir "$project/work"
    assert_dir "$project/outputs"

    while IFS= read -r source_file; do
        relative_path="${source_file#"$TEMPLATES_DIR/project/"}"
        assert_file "$project/$relative_path"
    done < <(find "$TEMPLATES_DIR/project" -type f -print)

    count="$(grep -c 'agent-orchestration:begin' "$project/CLAUDE.md" || true)"
    if [ "$count" -ne 1 ]; then
        fail "CLAUDE.md 中片段出现 $count 次，期望 1 次"
    fi
    if ! grep -Fq '原有项目内容，保留我' "$project/CLAUDE.md"; then
        fail "已有 CLAUDE.md 原内容丢失"
    fi
    if [ -e "$AGENT_ORCH_HOME" ]; then
        fail "--project-only 不应创建配置目录"
    fi

    if ! run_install --project-only "$project"; then
        return 0
    fi

    count="$(grep -c 'agent-orchestration:begin' "$project/CLAUDE.md" || true)"
    if [ "$count" -ne 1 ]; then
        fail "重复运行后 CLAUDE.md 片段出现 $count 次，期望 1 次"
    fi
}

test_uninstall_and_purge() {
    setup_case

    # First install links, then verify that uninstall removes them but keeps
    # the configuration directory.
    if ! run_install; then
        return 0
    fi
    if ! run_uninstall; then
        return 0
    fi
    assert_missing "$CLAUDE_CONFIG_DIR/skills/subagent-dispatch"
    assert_missing "$CLAUDE_CONFIG_DIR/skills/session-orchestration"
    assert_dir "$AGENT_ORCH_HOME"

    # Now install copies in Claude, add repository links in Codex, and add one
    # unrelated entry that uninstall must leave alone.
    if ! run_install --copy; then
        return 0
    fi
    mkdir -p "$CODEX_HOME/skills"
    for name in subagent-dispatch session-orchestration; do
        ln -s "$(skill_source "$name")" "$CODEX_HOME/skills/$name"
        assert_file "$CLAUDE_CONFIG_DIR/skills/$name/.agent-orchestration-copy"
    done
    mkdir -p "$CLAUDE_CONFIG_DIR/skills/unrelated-dir"
    ln -s "/tmp" "$CLAUDE_CONFIG_DIR/skills/unrelated-link"

    if ! run_uninstall; then
        return 0
    fi

    assert_missing "$CLAUDE_CONFIG_DIR/skills/subagent-dispatch"
    assert_missing "$CLAUDE_CONFIG_DIR/skills/session-orchestration"
    assert_missing "$CODEX_HOME/skills/subagent-dispatch"
    assert_missing "$CODEX_HOME/skills/session-orchestration"
    assert_dir "$CLAUDE_CONFIG_DIR/skills/unrelated-dir"
    assert_link_to "$CLAUDE_CONFIG_DIR/skills/unrelated-link" "/tmp"
    assert_dir "$AGENT_ORCH_HOME"

    if ! run_uninstall --purge; then
        return 0
    fi
    assert_missing "$AGENT_ORCH_HOME"
}

test_unknown_argument() {
    setup_case
    "$INSTALL" --not-a-real-option >"$CASE_LOG" 2>&1
    status=$?
    if [ "$status" -eq 0 ]; then
        fail "install.sh 对未知参数返回 0，期望 2"
        return 0
    fi
    if [ "$status" -ne 2 ]; then
        fail "install.sh 对未知参数退出码是 ${status}，期望 2"
    fi
    if [ -e "$AGENT_ORCH_HOME" ]; then
        fail "未知参数不应创建配置目录"
    fi
}

run_case() {
    label="$1"
    func="$2"
    CASE_FAILED=0
    "$func"
    if [ "$CASE_FAILED" -eq 0 ]; then
        printf 'PASS %s\n' "$label"
    else
        printf 'FAIL %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

printf '临时测试目录: %s\n' "$TEST_ROOT"

run_case "默认安装" test_default_install
run_case "重复安装幂等" test_idempotent
run_case "已有目录备份" test_existing_directory_is_backed_up
run_case "--codex 安装" test_codex_install
run_case "--copy 模式" test_copy_mode
run_case "--project-only 初始化" test_project_only
run_case "卸载与 --purge" test_uninstall_and_purge
run_case "未知参数退出码" test_unknown_argument

if [ "$FAILURES" -ne 0 ]; then
    printf 'TESTS FAILED (%s case(s))\n' "$FAILURES"
    exit 1
fi

printf 'ALL TESTS PASSED\n'
