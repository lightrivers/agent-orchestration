#!/usr/bin/env bash
# Run the checker against fixture task directories and assert that their exit
# codes distinguish clean / HIGH / MEDIUM-only / protected-path results.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/../../scripts/check_progress.py"

# Point the checker at a non-existent AGENT_ORCH_HOME so the real user config
# never affects the tests.
EMPTY_AGENT_ORCH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agent-orch-home.XXXXXX")"
rmdir "$EMPTY_AGENT_ORCH_HOME"
CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-orch-config.XXXXXX")"
printf '{"protected_paths": ["/data/keep"]}\n' > "$CONFIG_FILE"

cleanup() {
    rm -f "$CONFIG_FILE"
}
trap cleanup EXIT

run_checker() {
    AGENT_ORCH_HOME="$EMPTY_AGENT_ORCH_HOME" python3 "$CHECKER" "$@"
}

failures=0

# Exit 0: no findings; the output must explicitly say OK.
clean_output="$(run_checker "$SCRIPT_DIR/clean" 2>&1)"
clean_status=$?
if [ "$clean_status" -ne 0 ]; then
    printf 'FAIL %-10s expected exit 0, got %s\n' "clean" "$clean_status"
    printf '%s\n' "$clean_output" | sed 's/^/    /'
    failures=$((failures + 1))
elif ! printf '%s\n' "$clean_output" | grep -qx 'OK'; then
    printf 'FAIL %-10s expected output line OK\n' "clean"
    printf '%s\n' "$clean_output" | sed 's/^/    /'
    failures=$((failures + 1))
else
    printf 'PASS %-10s exit=0 and output OK\n' "clean"
fi

# Exit 2: has at least one HIGH finding.
high_output="$(run_checker "$SCRIPT_DIR/has_high" 2>&1)"
high_status=$?
if [ "$high_status" -ne 2 ]; then
    printf 'FAIL %-10s expected exit 2, got %s\n' "has_high" "$high_status"
    printf '%s\n' "$high_output" | sed 's/^/    /'
    failures=$((failures + 1))
elif ! printf '%s\n' "$high_output" | grep -q '^HIGH |'; then
    printf 'FAIL %-10s expected a HIGH alert\n' "has_high"
    printf '%s\n' "$high_output" | sed 's/^/    /'
    failures=$((failures + 1))
else
    printf 'PASS %-10s exit=2 and HIGH alert present\n' "has_high"
fi

# Exit 1: MEDIUM-only findings.
medium_output="$(run_checker "$SCRIPT_DIR/has_medium" 2>&1)"
medium_status=$?
if [ "$medium_status" -ne 1 ]; then
    printf 'FAIL %-10s expected exit 1, got %s\n' "has_medium" "$medium_status"
    printf '%s\n' "$medium_output" | sed 's/^/    /'
    failures=$((failures + 1))
elif ! printf '%s\n' "$medium_output" | grep -q '^MEDIUM |'; then
    printf 'FAIL %-10s expected a MEDIUM alert\n' "has_medium"
    printf '%s\n' "$medium_output" | sed 's/^/    /'
    failures=$((failures + 1))
elif printf '%s\n' "$medium_output" | grep -q '^HIGH |'; then
    printf 'FAIL %-10s should not contain a HIGH alert\n' "has_medium"
    printf '%s\n' "$medium_output" | sed 's/^/    /'
    failures=$((failures + 1))
else
    printf 'PASS %-10s exit=1 and MEDIUM-only alert present\n' "has_medium"
fi

# With no protected paths configured, the fixture's L1 write is clean.
protected_clean_output="$(run_checker "$SCRIPT_DIR/has_protected" 2>&1)"
protected_clean_status=$?
if [ "$protected_clean_status" -ne 0 ]; then
    printf 'FAIL %-16s expected exit 0, got %s\n' "has_protected" "$protected_clean_status"
    printf '%s\n' "$protected_clean_output" | sed 's/^/    /'
    failures=$((failures + 1))
elif ! printf '%s\n' "$protected_clean_output" | grep -qx 'OK'; then
    printf 'FAIL %-16s expected output line OK\n' "has_protected"
    printf '%s\n' "$protected_clean_output" | sed 's/^/    /'
    failures=$((failures + 1))
else
    printf 'PASS %-16s exit=0 with no protected paths\n' "has_protected"
fi

# A write under --protected-path is HIGH.
protected_cli_output="$(
    run_checker "$SCRIPT_DIR/has_protected" --protected-path /data/keep 2>&1
)"
protected_cli_status=$?
if [ "$protected_cli_status" -ne 2 ]; then
    printf 'FAIL %-16s expected exit 2, got %s\n' "protected-cli" "$protected_cli_status"
    printf '%s\n' "$protected_cli_output" | sed 's/^/    /'
    failures=$((failures + 1))
elif ! printf '%s\n' "$protected_cli_output" | grep -q '受保护路径写操作'; then
    printf 'FAIL %-16s expected a protected-path alert\n' "protected-cli"
    printf '%s\n' "$protected_cli_output" | sed 's/^/    /'
    failures=$((failures + 1))
else
    printf 'PASS %-16s exit=2 and protected-path alert present\n' "protected-cli"
fi

# The same write is HIGH when the path comes from --config.
protected_config_output="$(
    run_checker "$SCRIPT_DIR/has_protected" --config "$CONFIG_FILE" 2>&1
)"
protected_config_status=$?
if [ "$protected_config_status" -ne 2 ]; then
    printf 'FAIL %-16s expected exit 2, got %s\n' "protected-config" "$protected_config_status"
    printf '%s\n' "$protected_config_output" | sed 's/^/    /'
    failures=$((failures + 1))
elif ! printf '%s\n' "$protected_config_output" | grep -q '受保护路径写操作'; then
    printf 'FAIL %-16s expected a protected-path alert\n' "protected-config"
    printf '%s\n' "$protected_config_output" | sed 's/^/    /'
    failures=$((failures + 1))
else
    printf 'PASS %-16s exit=2 and config protected-path alert present\n' "protected-config"
fi

if [ "$failures" -ne 0 ]; then
    printf 'TESTS FAILED (%s failure(s))\n' "$failures"
    exit 1
fi

printf 'ALL TESTS PASSED\n'
