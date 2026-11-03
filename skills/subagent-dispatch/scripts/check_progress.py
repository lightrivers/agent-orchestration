#!/usr/bin/env python3
"""Inspect progress.md / changes.md and report items needing attention.

Only the Python 3 standard library is used.  The accepted row formats are:

  progress.md: 时间 | 级别 | 命令 | 目的 | 结果
  changes.md:  时间 | 级别 | 主机 | 改了什么 | 改前值或备份路径 | 改后值 | 怎么回滚

Output is one alert per line, followed by a final "HIGH=n MEDIUM=m" summary.
Exit status is 2 when any HIGH alert exists, 1 for MEDIUM-only, and 0 otherwise.

Protected paths come from the "protected_paths" list in the config file
(--config, or AGENT_ORCH_HOME/config.json) and from repeated --protected-path
options.  Write operations that hit one of those paths are reported as HIGH.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import shlex
import sys
from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple


PROGRESS_COLUMNS = 5
CHANGES_COLUMNS = 7

HIGH = "HIGH"
MEDIUM = "MEDIUM"

CAUSE_WORDS = ("原因是", "确认是", "根因")

_PLACEHOLDER_VALUES = {"", "-", "无"}

# Shell paths which are write targets but are not useful for scope checks.
_SPECIAL_WRITE_PATHS = {
    "/dev/null",
    "/dev/stdout",
    "/dev/stderr",
    "/dev/zero",
    "/dev/full",
}

# ---------------------------------------------------------------------------
# Regular expressions

_HEADER_TIMES = {
    "时间",
    "时间戳",
    "日期",
    "time",
    "timestamp",
    "date",
    "datetime",
}
_HEADER_LEVELS = {"级别", "level", "severity"}

# A command word, optionally reached through a path such as /bin/rm.
def _word(name: str) -> re.Pattern[str]:
    return re.compile(r"(?<![\w.-])" + name + r"(?![\w.-])", re.IGNORECASE)


_RM_RE = _word("rm")
_MV_RE = _word("mv")
_CP_RE = _word("cp")
_TEE_RE = _word("tee")
_CHMOD_RE = _word("chmod")
_CHOWN_RE = _word("chown")
_MKDIR_RE = _word("mkdir")
_TOUCH_RE = _word("touch")
_SED_RE = _word("sed")
_SHRED_RE = _word("shred")
_TRUNCATE_RE = _word("truncate")
_DD_RE = _word("dd")

_REDIRECT_RE = re.compile(r"(?<![-<>=])(>{1,2})(?![>&=])")
_REDIRECT_TARGET_RE = re.compile(
    r"(?<![-<>=])>{1,2}\s*"
    r"(\"[^\"]*\"|'[^']*'|[^\s|;&<>()\[\]{}\"']+)"
)
_SED_IN_PLACE_RE = re.compile(
    r"(?<![\w.-])sed\b[^;|&\n]*?"
    r"(?<![\w-])(?:-i(?:\S*)?|--in-place(?:=\S*)?)(?=\s|$)",
    re.IGNORECASE,
)
_SYSTEMCTL_WRITE_RE = re.compile(
    r"(?<![\w.-])(?:systemctl|synosystemctl)\s+"
    r"(?:--[^\s]+\s+)*(?:start|stop|restart)(?=\s|$)",
    re.IGNORECASE,
)
_DOCKER_WRITE_RE = re.compile(
    r"(?<![\w.-])docker\s+(?:--[^\s]+\s+)*"
    r"(?:(?:rm|stop|restart)(?=\s|$)|compose\s+(?:--[^\s]+\s+)*"
    r"(?:up|down)(?=\s|$))",
    re.IGNORECASE,
)
_SYNOPKG_WRITE_RE = re.compile(
    r"(?<![\w.-])synopkg\s+(?:--[^\s]+\s+)*"
    r"(?:start|stop|install|uninstall)(?=\s|$)",
    re.IGNORECASE,
)

_CP_CALL_RE = re.compile(r"(?<![\w.-])cp\b([^;|&\n]*)", re.IGNORECASE)

_L3_PATTERNS: List[Tuple[re.Pattern[str], str]] = [
    (re.compile(r"(?<![\w.-])mkfs(?:\.[\w-]+)?(?![\w.-])", re.I), "mkfs"),
    (re.compile(r"(?<![\w.-])wipefs(?![\w.-])", re.I), "wipefs"),
    (re.compile(r"(?<![\w.-])dd\b[^\n|;&]*\bof\s*=", re.I), "dd of="),
    (re.compile(r"(?<![\w.-])fdisk(?![\w.-])", re.I), "fdisk"),
    (re.compile(r"(?<![\w.-])parted(?![\w.-])", re.I), "parted"),
    (re.compile(r"(?<![\w.-])mdadm(?![\w.-])", re.I), "mdadm"),
    (re.compile(r"(?<![\w.-])lvremove(?![\w.-])", re.I), "lvremove"),
    (re.compile(r"(?<![\w.-])vgremove(?![\w.-])", re.I), "vgremove"),
    (
        re.compile(
            r"(?<![\w.-])btrfs\s+"
            r"(?:balance|scrub|device\b|subvolume\s+delete|"
            r"check\s+--repair)",
            re.I,
        ),
        "btrfs 破坏性操作",
    ),
    (re.compile(r"(?<![\w.-])synopool(?![\w.-])", re.I), "synopool"),
    (re.compile(r"(?<![\w.-])synostgpool(?![\w.-])", re.I), "synostgpool"),
    (re.compile(r"(?<![\w.-])synospace(?![\w.-])", re.I), "synospace"),
    (
        re.compile(
            r"(?<![\w.-])rm\s+"
            r"(?:(?:-[^\s]+|--[^\s]+)\s+)*"
            r"(?:-[A-Za-z]*[rR][A-Za-z]*|--recursive)(?=\s|$)",
            re.I,
        ),
        "rm -r/-rf",
    ),
    (re.compile(r"(?<![\w.-])shred(?![\w.-])", re.I), "shred"),
    (re.compile(r"(?<![\w.-])truncate(?![\w.-])", re.I), "truncate"),
    (re.compile(r">+\s*/dev/sd[a-z]", re.I), "写入 /dev/sd"),
    (
        re.compile(r"(?<![\w.-])synosnap(?![\w.-])", re.I),
        "删除快照（synosnap）",
    ),
    (
        re.compile(
            r"(?<![\w.-])snapshot\b[^\n|;&]*\bdelete\b",
            re.I,
        ),
        "删除快照（snapshot delete）",
    ),
]


# ---------------------------------------------------------------------------
# Data structures


@dataclass
class Row:
    file_label: str
    line_no: int
    raw: str
    parts: List[str]

    def cell(self, index: int) -> str:
        if index < 0 or index >= len(self.parts):
            return ""
        return self.parts[index].strip()


@dataclass
class Alert:
    severity: str
    file_label: str
    line_no: int
    reason: str
    raw: str

    def render(self) -> str:
        return (
            f"{self.severity} | {self.file_label}:{self.line_no} | "
            f"{self.reason} | {self.raw[:120]}"
        )


# ---------------------------------------------------------------------------
# Parsing helpers


def _looks_like_header(parts: Sequence[str]) -> bool:
    if not parts:
        return False
    first = parts[0].strip().lower()
    if first in _HEADER_TIMES:
        return True
    if len(parts) > 1 and parts[1].strip().lower() in _HEADER_LEVELS:
        return True
    return False


def _parse_rows(path: str, file_label: str) -> List[Row]:
    rows: List[Row] = []
    try:
        with open(path, "r", encoding="utf-8-sig", errors="replace") as handle:
            for line_no, raw_line in enumerate(handle, start=1):
                raw = raw_line.rstrip("\n").rstrip("\r")
                stripped = raw.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                parts = raw.split(" | ")
                if _looks_like_header(parts):
                    continue
                rows.append(Row(file_label, line_no, raw, parts))
    except FileNotFoundError:
        # A missing file simply contributes no rows.  A missing directory is
        # rejected by main().
        return []
    return rows


def _parse_time(value: str) -> Optional[_dt.datetime]:
    value = value.strip()
    if not value:
        return None
    candidate = value
    if candidate.endswith(("Z", "z")):
        candidate = candidate[:-1] + "+00:00"
    try:
        return _dt.datetime.fromisoformat(candidate)
    except ValueError:
        pass

    formats = (
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y/%m/%d %H:%M:%S",
        "%Y/%m/%d %H:%M",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%d",
        "%Y/%m/%d",
    )
    for fmt in formats:
        try:
            return _dt.datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None


def _same_time(left: str, right: str) -> bool:
    left = " ".join(left.split())
    right = " ".join(right.split())
    if not left or not right:
        return False
    if left == right:
        return True
    left_dt = _parse_time(left)
    right_dt = _parse_time(right)
    if left_dt is None or right_dt is None:
        return False
    # Comparing two aware datetimes is straightforward.  For mixed/naive
    # values, timestamp() gives the same local-time interpretation used for
    # checkpoint mtimes.
    return left_dt.timestamp() == right_dt.timestamp()


# ---------------------------------------------------------------------------
# Command analysis


def _strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def _clean_path(value: str) -> str:
    value = _strip_quotes(value)
    return value.rstrip(".,;:!?")


def _normalize_path(value: str) -> str:
    value = _clean_path(value)
    if not value:
        return ""
    value = os.path.expanduser(value)
    if len(value) > 1:
        value = value.rstrip("/")
    return value or "/"


def _normalize_protected_paths(paths: Sequence[str]) -> List[str]:
    normalized: List[str] = []
    for value in paths:
        path = _normalize_path(value)
        if path and path not in normalized:
            normalized.append(path)
    return normalized


def _redirect_targets(command: str) -> List[str]:
    targets: List[str] = []
    for match in _REDIRECT_TARGET_RE.finditer(command):
        target = _clean_path(match.group(1))
        if target and target not in targets:
            targets.append(target)
    return targets


def _tokenize(segment: str) -> List[str]:
    try:
        return shlex.split(segment, posix=True)
    except ValueError:
        return segment.split()


_CONTROL_SPLIT_RE = re.compile(r"\s*(?:\|\||&&|[;|&\n])\s*")


def _command_segment(rest: str) -> str:
    return _CONTROL_SPLIT_RE.split(rest, maxsplit=1)[0]


def _looks_like_path_token(value: str) -> bool:
    value = _strip_quotes(value)
    if not value or value in ("-", "--"):
        return False
    if value.startswith(("/", "./", "../", "~/")):
        return True
    if "://" in value:
        return False
    if "/" in value:
        return True
    if value.startswith("-"):
        return False
    # Reject common option values: sizes, iteration counts, numeric modes and
    # symbolic chmod modes.  Bare filenames remain valid.
    if re.fullmatch(r"\d+(?:\.\d+)?[KMGTP]?", value, re.IGNORECASE):
        return False
    if re.fullmatch(r"[0-7]{3,4}", value):
        return False
    if re.fullmatch(r"[ugoa]*[+\-=][rwxXstugo]*", value):
        return False
    return bool(re.fullmatch(r"[\w.@%+\-~]+", value))


def _operands(
    tokens: Sequence[str],
    skip_first: int = 0,
    value_options: Sequence[str] = (),
) -> List[str]:
    operands: List[str] = []
    skipped = 0
    skip_next = False
    after_double_dash = False
    for token in tokens:
        if skip_next:
            skip_next = False
            continue
        if not after_double_dash and token == "--":
            after_double_dash = True
            continue
        if not after_double_dash and token.startswith("-") and token != "-":
            if token in value_options:
                skip_next = True
            continue
        if re.match(r"^\d*[<>]", token):
            continue
        if skipped < skip_first:
            skipped += 1
            continue
        operands.append(token)
    return operands


def _sed_file_operands(tokens: Sequence[str]) -> List[str]:
    """Return only file operands from a sed invocation.

    Sed's first non-option argument (or the argument of -e/--expression) is a
    script, not a filesystem path.  Treating it as a path causes false scope
    violations for edits such as: sed -i 's/a/b/' /srv/file
    """
    files: List[str] = []
    have_script = False
    after_double_dash = False
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if not after_double_dash and token == "--":
            after_double_dash = True
            index += 1
            continue
        if not after_double_dash and token.startswith("-") and token != "-":
            if token in ("-e", "--expression"):
                have_script = True
                index += 2
                continue
            if token.startswith("--expression="):
                have_script = True
                index += 1
                continue
            if token.startswith("-e") and len(token) > 2:
                have_script = True
                index += 1
                continue
            if token in ("-f", "--file"):
                if index + 1 < len(tokens):
                    files.append(tokens[index + 1])
                have_script = True
                index += 2
                continue
            if token.startswith("--file="):
                files.append(token.split("=", 1)[1])
                have_script = True
                index += 1
                continue
            if token.startswith("-f") and len(token) > 2:
                files.append(token[2:])
                have_script = True
                index += 1
                continue
            index += 1
            continue
        if not have_script:
            have_script = True
        else:
            files.append(token)
        index += 1
    return files


_WRITE_COMMAND_PATTERNS: Tuple[Tuple[str, re.Pattern[str]], ...] = (
    ("rm", _RM_RE),
    ("mv", _MV_RE),
    ("cp", _CP_RE),
    ("tee", _TEE_RE),
    ("chmod", _CHMOD_RE),
    ("chown", _CHOWN_RE),
    ("mkdir", _MKDIR_RE),
    ("touch", _TOUCH_RE),
    ("sed", _SED_RE),
    ("shred", _SHRED_RE),
    ("truncate", _TRUNCATE_RE),
    ("dd", _DD_RE),
)


def _write_paths(command: str) -> List[str]:
    """Return filesystem operands of write commands and redirect targets.

    Command words themselves (for example /bin/rm) are intentionally excluded:
    they are executables, not data paths involved in the write.
    """
    found: List[str] = []

    def add(value: str) -> None:
        value = _clean_path(value)
        if not value or value in _SPECIAL_WRITE_PATHS:
            return
        if value not in found:
            found.append(value)

    invocations: List[Tuple[int, int, str]] = []
    for label, pattern in _WRITE_COMMAND_PATTERNS:
        for match in pattern.finditer(command):
            invocations.append((match.start(), match.end(), label))
    invocations.sort()

    for _start, end, label in invocations:
        tokens = _tokenize(_command_segment(command[end:]))
        if label == "dd":
            for token in tokens:
                for prefix in ("if=", "of="):
                    if token.startswith(prefix):
                        add(token[len(prefix) :])
            continue
        if label == "sed":
            operands = _sed_file_operands(tokens)
        else:
            skip_first = 1 if label in ("chmod", "chown") else 0
            value_options = {
                "touch": ("-d", "--date"),
                "truncate": ("-s", "--size"),
                "shred": ("-n", "--iterations"),
            }.get(label, ())
            operands = _operands(
                tokens,
                skip_first=skip_first,
                value_options=value_options,
            )
        for operand in operands:
            if _looks_like_path_token(operand):
                add(operand)

    # --target-directory=DIR and -t DIR carry the cp destination as an option.
    for target in _cp_targets(command):
        add(target)
    for target in _redirect_targets(command):
        add(target)
    return found


def _cp_targets(command: str) -> List[str]:
    targets: List[str] = []
    for call in _CP_CALL_RE.finditer(command):
        rest = call.group(1).strip()
        if not rest:
            continue
        try:
            tokens = shlex.split(rest, posix=True)
        except ValueError:
            tokens = rest.split()
        operands: List[str] = []
        target_dir: Optional[str] = None
        index = 0
        while index < len(tokens):
            token = tokens[index]
            if token == "--":
                operands.extend(tokens[index + 1 :])
                break
            if token in ("-t", "--target-directory"):
                if index + 1 < len(tokens):
                    target_dir = tokens[index + 1]
                    index += 2
                    continue
                break
            if token.startswith("--target-directory="):
                target_dir = token.split("=", 1)[1]
                index += 1
                continue
            if token.startswith("-") and token != "-":
                index += 1
                continue
            operands.append(token)
            index += 1
        if target_dir:
            targets.append(_strip_quotes(target_dir))
        elif operands:
            targets.append(_strip_quotes(operands[-1]))
    return targets


def _action_labels(command: str) -> List[str]:
    labels: List[str] = []

    def add(label: str) -> None:
        if label not in labels:
            labels.append(label)

    for label, pattern in (
        ("rm", _RM_RE),
        ("mv", _MV_RE),
        ("cp", _CP_RE),
        ("tee", _TEE_RE),
        ("chmod", _CHMOD_RE),
        ("chown", _CHOWN_RE),
        ("mkdir", _MKDIR_RE),
        ("touch", _TOUCH_RE),
        ("shred", _SHRED_RE),
        ("truncate", _TRUNCATE_RE),
        ("dd", _DD_RE),
    ):
        if pattern.search(command):
            add(label)
    if _SED_IN_PLACE_RE.search(command):
        add("sed -i")
    redirect_targets = _redirect_targets(command)
    effective_targets = [
        target for target in redirect_targets if target not in _SPECIAL_WRITE_PATHS
    ]
    redirect = _REDIRECT_RE.search(command)
    if effective_targets or (redirect and not redirect_targets):
        operators = [match.group(1) for match in _REDIRECT_RE.finditer(command)]
        add(">>" if ">>" in operators else ">")
    if _SYSTEMCTL_WRITE_RE.search(command):
        add("systemctl/synosystemctl")
    if _DOCKER_WRITE_RE.search(command):
        add("docker")
    if _SYNOPKG_WRITE_RE.search(command):
        add("synopkg")
    return labels


def _has_write_action(command: str) -> bool:
    return bool(_action_labels(command))


def _l0_write_labels(command: str) -> List[str]:
    """Write actions specifically called out for an L0 progress row."""
    labels = [
        label
        for label in _action_labels(command)
        if label
        in {
            "rm",
            "mv",
            "cp",
            "tee",
            "chmod",
            "chown",
            "mkdir",
            "touch",
            "sed -i",
            ">",
            ">>",
            "systemctl/synosystemctl",
            "docker",
            "synopkg",
        }
    ]
    return labels


def _find_l3_reasons(
    command: str, protected_paths: Sequence[str] = ()
) -> List[str]:
    reasons: List[str] = []
    for pattern, label in _L3_PATTERNS:
        if pattern.search(command) and label not in reasons:
            reasons.append(label)

    if protected_paths:
        actions = _action_labels(command)
        if actions:
            cp_targets = _cp_targets(command)
            non_cp_write = any(label != "cp" for label in actions)
            for protected_path in protected_paths:
                cp_target_hit = any(
                    _is_under_protected(target, protected_path)
                    for target in cp_targets
                )
                # Conservative on purpose: any non-cp write in a command that
                # mentions the path counts, which also catches "cd P && rm x".
                other_write_hit = non_cp_write and _mentions_path(
                    command, protected_path
                )
                if cp_target_hit or other_write_hit:
                    reason = f"受保护路径写操作: {protected_path}"
                    if reason not in reasons:
                        reasons.append(reason)
    return reasons


def _mentions_path(command: str, protected_path: str) -> bool:
    if protected_path == "/":
        return True
    pattern = r"(?<![\w.-])" + re.escape(protected_path) + r"(?![\w.-])"
    return re.search(pattern, command) is not None


def _is_under_protected(path: str, protected_path: str) -> bool:
    path = _normalize_path(path)
    protected_path = _normalize_path(protected_path)
    if not path or not protected_path:
        return False
    if protected_path == "/":
        return path.startswith("/")
    return path == protected_path or path.startswith(protected_path + "/")


def _is_l0(level: str) -> bool:
    return bool(re.match(r"^L0(?:\b|$)", level.strip(), re.IGNORECASE))


# ---------------------------------------------------------------------------
# Alert generation


def _format_alerts(rows: Sequence[Row], expected_columns: int) -> List[Alert]:
    alerts: List[Alert] = []
    for row in rows:
        if len(row.parts) != expected_columns:
            alerts.append(
                Alert(
                    MEDIUM,
                    row.file_label,
                    row.line_no,
                    f"列数错误（期望 {expected_columns} 列，实际 {len(row.parts)} 列）",
                    row.raw,
                )
            )
    return alerts


def _contains_path(text: str, path: str) -> bool:
    path = _clean_path(path).rstrip("/") or "/"
    if not path:
        return False
    # Do not match a path embedded inside another path (for example /a inside
    # /srv/a), and do not match a longer path sharing this prefix.
    path_chars = r"A-Za-z0-9_.@%+\-~/"
    pattern = (
        rf"(?<![{path_chars}])"
        + re.escape(path)
        + rf"(?:/(?![A-Za-z0-9_.@%+\-~])|(?![A-Za-z0-9_.@%+\-~/]))"
    )
    return re.search(pattern, text) is not None


def _path_matches_scope(path: str, scope: re.Pattern[str]) -> bool:
    if path in _SPECIAL_WRITE_PATHS:
        return True
    return scope.search(path) is not None


def _changes_match_progress(row: Row, changes_rows: Sequence[Row]) -> bool:
    command = row.cell(2)
    command_time = row.cell(0)
    command_paths = _write_paths(command)
    for change in changes_rows:
        if _same_time(command_time, change.cell(0)):
            return True
        for path in command_paths:
            if _contains_path(change.raw, path):
                return True
    return False


def _check_checkpoint(
    row: Row,
    task_dir: str,
    result: str,
    alerts: List[Alert],
) -> None:
    if not any(word in result for word in CAUSE_WORDS):
        return

    checkpoint_path = os.path.join(task_dir, "checkpoint.md")
    if not os.path.isfile(checkpoint_path):
        alerts.append(
            Alert(
                MEDIUM,
                row.file_label,
                row.line_no,
                "结果提到原因但同目录缺少 checkpoint.md",
                row.raw,
            )
        )
        return

    row_time = _parse_time(row.cell(0))
    if row_time is None:
        # The requirement explicitly skips this comparison when time cannot be
        # parsed.  The file's mere presence still satisfies the first check.
        return
    try:
        checkpoint_mtime = os.path.getmtime(checkpoint_path)
    except OSError:
        return
    if checkpoint_mtime < row_time.timestamp():
        alerts.append(
            Alert(
                MEDIUM,
                row.file_label,
                row.line_no,
                "checkpoint.md 修改时间早于记录时间",
                row.raw,
            )
        )


def inspect(
    task_dir: str,
    scope: Optional[re.Pattern[str]],
    protected_paths: Sequence[str] = (),
) -> List[Alert]:
    progress_label = "progress.md"
    changes_label = "changes.md"

    progress_rows = _parse_rows(os.path.join(task_dir, progress_label), progress_label)
    changes_rows = _parse_rows(os.path.join(task_dir, changes_label), changes_label)

    alerts: List[Alert] = []
    alerts.extend(_format_alerts(progress_rows, PROGRESS_COLUMNS))
    alerts.extend(_format_alerts(changes_rows, CHANGES_COLUMNS))

    # progress.md checks
    for row in progress_rows:
        level = row.cell(1)
        command = row.cell(2)
        result = row.cell(4)

        l3_reasons = _find_l3_reasons(command, protected_paths)
        if l3_reasons:
            alerts.append(
                Alert(
                    HIGH,
                    row.file_label,
                    row.line_no,
                    "L3 高危命令：" + "、".join(l3_reasons),
                    row.raw,
                )
            )

        if _is_l0(level):
            l0_labels = _l0_write_labels(command)
            if l0_labels:
                alerts.append(
                    Alert(
                        HIGH,
                        row.file_label,
                        row.line_no,
                        "L0 标记但命令含写操作：" + "、".join(l0_labels),
                        row.raw,
                    )
                )

        if scope is not None and _has_write_action(command):
            paths = _write_paths(command)
            out_of_scope = [
                path for path in paths if not _path_matches_scope(path, scope)
            ]
            if out_of_scope:
                alerts.append(
                    Alert(
                        HIGH,
                        row.file_label,
                        row.line_no,
                        "命令路径越出 --scope 范围：" + "、".join(out_of_scope),
                        row.raw,
                    )
                )

        if _has_write_action(command) and not _changes_match_progress(
            row, changes_rows
        ):
            alerts.append(
                Alert(
                    MEDIUM,
                    row.file_label,
                    row.line_no,
                    "写命令在 changes.md 中找不到相同时间或相同路径的记录",
                    row.raw,
                )
            )

        if result:
            _check_checkpoint(row, task_dir, result, alerts)

    # changes.md checks
    for row in changes_rows:
        empty_fields: List[str] = []
        if row.cell(4).strip() in _PLACEHOLDER_VALUES:
            empty_fields.append("改前值或备份路径")
        if row.cell(6).strip() in _PLACEHOLDER_VALUES:
            empty_fields.append("怎么回滚")
        if empty_fields:
            alerts.append(
                Alert(
                    HIGH,
                    row.file_label,
                    row.line_no,
                    "、".join(empty_fields) + "为空/占位符",
                    row.raw,
                )
            )

        if scope is not None:
            changed = row.cell(3)
            if scope.search(changed) is None:
                alerts.append(
                    Alert(
                        HIGH,
                        row.file_label,
                        row.line_no,
                        "改动内容越出 --scope 范围",
                        row.raw,
                    )
                )

    # Stable, readable ordering: HIGH first, then file/line/reason.
    severity_order = {HIGH: 0, MEDIUM: 1}
    alerts.sort(
        key=lambda item: (
            severity_order[item.severity],
            item.file_label,
            item.line_no,
            item.reason,
        )
    )
    return alerts


# ---------------------------------------------------------------------------
# Configuration


DEFAULT_AGENT_ORCH_HOME = "~/.config/agent-orchestration"


def _default_config_path() -> str:
    home = os.environ.get("AGENT_ORCH_HOME") or DEFAULT_AGENT_ORCH_HOME
    return os.path.join(os.path.expanduser(home), "config.json")


def _load_protected_paths(config_path: str) -> List[str]:
    """Read protected_paths from config_path; missing/bad config means none."""
    try:
        with open(config_path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return []
    except (OSError, ValueError) as exc:
        message = str(exc).replace("\n", " ")
        print(f"警告：无法读取配置文件 {config_path}：{message}", file=sys.stderr)
        return []

    if not isinstance(data, dict):
        return []
    values = data.get("protected_paths")
    if not isinstance(values, list):
        return []
    return _normalize_protected_paths(
        [value for value in values if isinstance(value, str)]
    )


# ---------------------------------------------------------------------------
# Entry point


def main(argv: Optional[Sequence[str]] = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(errors="replace")

    parser = argparse.ArgumentParser(
        description="检查 DeepSeek 任务目录中的 progress.md 和 changes.md"
    )
    parser.add_argument("task_dir", help="包含 progress.md / changes.md 的任务目录")
    parser.add_argument(
        "--scope",
        help="可选正则；changes.md 的改动内容和 progress.md 写命令路径必须匹配",
    )
    parser.add_argument(
        "--protected-path",
        action="append",
        default=[],
        dest="protected_paths",
        metavar="PATH",
        help="受保护路径；可重复指定",
    )
    parser.add_argument(
        "--config",
        metavar="FILE",
        help=(
            "配置文件路径（默认 "
            "AGENT_ORCH_HOME/config.json，AGENT_ORCH_HOME 默认为 "
            f"{DEFAULT_AGENT_ORCH_HOME}）"
        ),
    )
    args = parser.parse_args(argv)

    task_dir = os.path.abspath(os.path.expanduser(args.task_dir))
    if not os.path.isdir(task_dir):
        parser.error(f"任务目录不存在或不是目录：{args.task_dir}")

    scope: Optional[re.Pattern[str]] = None
    if args.scope is not None:
        try:
            scope = re.compile(args.scope)
        except re.error as exc:
            parser.error(f"--scope 不是有效的正则表达式：{exc}")

    config_path = (
        os.path.expanduser(args.config)
        if args.config is not None
        else _default_config_path()
    )
    protected_paths = _normalize_protected_paths(
        _load_protected_paths(config_path) + list(args.protected_paths)
    )

    alerts = inspect(task_dir, scope, protected_paths)
    for alert in alerts:
        print(alert.render())

    high_count = sum(1 for alert in alerts if alert.severity == HIGH)
    medium_count = sum(1 for alert in alerts if alert.severity == MEDIUM)
    if not alerts:
        print("OK")
    print(f"HIGH={high_count} MEDIUM={medium_count}")

    if high_count:
        return 2
    if medium_count:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
