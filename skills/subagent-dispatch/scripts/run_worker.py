#!/usr/bin/env python3
"""Run one authorized external CLI task, retain evidence, never retry automatically."""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid
from urllib.parse import urlsplit

DSH_DESKTOP_CLI = '/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh'
CODEX = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
CLAUDE = str(Path.home() / '.local/bin/claude')
CLI_ENV = {'deepseek': 'AGENT_ORCH_DEEPSEEK_CLI',
           'codex': 'AGENT_ORCH_CODEX_CLI',
           'claude': 'AGENT_ORCH_CLAUDE_CLI'}
HERE = Path(__file__).resolve().parent
DSH_DEFAULT_PATCH = HERE / 'dsh-task.patch.yml'
# Total / no-output limits in seconds. The cheap Codex relay is slow, so it gets the longest budget.
DEFAULT_TIMEOUT = {'codex': 3600, 'deepseek': 600, 'claude': 600}
DEFAULT_IDLE_TIMEOUT = {'codex': 900, 'deepseek': 300, 'claude': 300}


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def resolve_cli(provider, explicit=None, env=os.environ):
    """Return (CLI path, source) using explicit, env, config, then built-in defaults."""
    key = 'deepseek' if provider == 'dsh' else provider
    if explicit:
        return str(Path(explicit).expanduser()), 'explicit-cli'
    env_name = CLI_ENV.get(key)
    if env_name:
        from_env = env.get(env_name)
        if from_env:
            return str(Path(from_env).expanduser()), 'env'
    config_home = Path(env.get('AGENT_ORCH_HOME')
                       or str(Path.home() / '.config/agent-orchestration')).expanduser()
    try:
        config = json.loads((config_home / 'config.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        config = None
    if isinstance(config, dict) and isinstance(config.get('cli'), dict):
        configured = config['cli'].get(key)
        if isinstance(configured, str) and configured:
            return str(Path(configured).expanduser()), 'config'
    if key == 'deepseek':
        if sys.platform == 'darwin':
            return str(Path(DSH_DESKTOP_CLI).expanduser()), 'desktop-managed-cli'
        return str(Path(shutil.which('dsh', path=env.get('PATH')) or 'dsh').expanduser()), 'path'
    if key == 'codex':
        if sys.platform == 'darwin':
            return str(Path(CODEX).expanduser()), 'default'
        return str(Path(shutil.which('codex', path=env.get('PATH')) or 'codex').expanduser()), 'path'
    if key == 'claude':
        discovered = shutil.which('claude', path=env.get('PATH'))
        if sys.platform == 'darwin':
            return str(Path(discovered or CLAUDE).expanduser()), 'default'
        fallback = CLAUDE
        if sys.platform == 'win32' or os.name == 'nt':
            fallback = str(Path(CLAUDE).with_suffix('.exe'))
        return str(Path(discovered or fallback).expanduser()), 'path'
    raise ValueError('Unknown CLI provider: ' + str(provider))


def claude_destination(env):
    """Return the API host; the relay itself changes via CC Switch, so only the URL shape is checked."""
    for key in ('CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY'):
        if env.get(key, '').strip().lower() not in ('', '0', 'false', 'no', 'off'):
            raise ValueError('Claude alternate-provider routing is not authorized by this entrypoint')
    base_url = env.get('ANTHROPIC_BASE_URL', '').strip()
    if not base_url:
        return 'api.anthropic.com'
    try:
        endpoint = urlsplit(base_url)
        endpoint.port  # Raises ValueError on a malformed port.
        valid = (endpoint.scheme == 'https' and bool(endpoint.hostname) and endpoint.username is None
                 and endpoint.password is None and not endpoint.query and not endpoint.fragment)
    except ValueError:
        valid = False
    if not valid:
        # Never print the configured URL: it could contain credentials or a sensitive query.
        raise ValueError('Claude ANTHROPIC_BASE_URL must be an HTTPS URL without credentials, query or fragment')
    return endpoint.hostname


def read_deepseek_key_from_credentials(credentials_path):
    """Read refs.DEEPSEEK_API_KEY from the simple credentials YAML without a parser dependency."""
    try:
        lines = credentials_path.read_text(encoding='utf-8').splitlines()
    except OSError:
        return None
    in_refs = False
    for raw_line in lines:
        stripped = raw_line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        if not raw_line[:1].isspace():
            in_refs = stripped == 'refs:'
            continue
        if not in_refs:
            continue
        name, separator, value = stripped.partition(':')
        if not separator or name.strip() != 'DEEPSEEK_API_KEY':
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        return value or None
    return None


def deepseek_credential_source(env):
    if env.get('DEEPSEEK_API_KEY'):
        return 'launch-environment'
    dsh_home = Path(env.get('DSH_HOME') or str(Path.home() / '.dsh')).expanduser()
    credentials_path = dsh_home / '.credentials.yaml'
    if not credentials_path.is_file():
        return None
    ruby = shutil.which('ruby', path=env.get('PATH'))
    if ruby:
        # The shipped headless profile omits the credentials service, so bridge only this key.
        reader = (
            "require 'yaml'; "
            "data = YAML.safe_load(File.read(ARGV.fetch(0))); "
            "refs = data.is_a?(Hash) ? data['refs'] : nil; "
            "key = refs.is_a?(Hash) ? refs['DEEPSEEK_API_KEY'] : nil; "
            "STDOUT.write(key) if key.is_a?(String)"
        )
        try:
            result = subprocess.run([ruby, '-e', reader, str(credentials_path)],
                                    capture_output=True, text=True, check=False, timeout=10)
        except (OSError, subprocess.SubprocessError):
            result = None
        key = result.stdout.strip() if result is not None else ''
        if result is not None and result.returncode == 0 and key:
            env['DEEPSEEK_API_KEY'] = key
            return 'dsh-credentials-file'
    key = read_deepseek_key_from_credentials(credentials_path)
    if not key:
        return None
    env['DEEPSEEK_API_KEY'] = key
    return 'dsh-credentials-file'


def contract_error(summary, message):
    summary['handoff_ok'] = False
    summary.setdefault('contract_errors', []).append(message)
    # Keep the original string field for existing consumers, without losing earlier causes.
    summary['contract_error'] = '; '.join(summary['contract_errors'])


def default_model(provider):
    if provider == 'claude':
        return 'claude-opus-5-5'
    if provider == 'codex':
        return 'gpt-6-astra'
    return None


def parse_result(provider, raw):
    if provider == 'claude':
        try:
            obj = json.loads(raw)
            events = obj if isinstance(obj, list) else [obj]
        except json.JSONDecodeError:
            events = [json.loads(line) for line in raw.splitlines() if line.strip()]
        results = [e for e in events if isinstance(e, dict) and e.get('type') == 'result']
        if not results:
            raise ValueError('No ' + provider + ' result event')
        last = results[-1]
        reported_models = [e.get('model') for e in events if isinstance(e, dict)
                           and e.get('type') == 'system' and e.get('subtype') == 'init'
                           and e.get('model')]
        model_usage = last.get('modelUsage') or {}
        if provider == 'claude' and isinstance(model_usage, dict):
            reported_models = list(dict.fromkeys(reported_models + list(model_usage)))
        retries = [e for e in events if isinstance(e, dict)
                   and e.get('type') == 'system' and e.get('subtype') == 'api_retry']
        inits = [e for e in events if isinstance(e, dict)
                 and e.get('type') == 'system' and e.get('subtype') == 'init']
        init = inits[-1] if inits else {}
        return {
            'cli_reported_success': last.get('is_error') is False and last.get('subtype') == 'success'
                and (provider != 'claude' or bool(last.get('result')) or last.get('structured_output') is not None),
            'session_id': last.get('session_id'),
            'result': last.get('result'),
            'structured_output': last.get('structured_output'),
            'permission_denials': last.get('permission_denials', []),
            'usage': last.get('usage'),
            'reported_cost_usd': last.get('total_cost_usd'),
            'num_turns': last.get('num_turns'),
            'subtype': last.get('subtype'),
            'event_count': len(events),
            'reported_model': reported_models[-1] if reported_models else None,
            'reported_models': reported_models,
            'model_usage': model_usage,
            'errors': last.get('errors', []),
            'api_retries': len(retries),
            'reported_tools': init.get('tools'),
            'reported_mcp_servers': init.get('mcp_servers'),
            'reported_fast_mode': last.get('fast_mode_state', init.get('fast_mode_state')),
            'terminal_reason': last.get('terminal_reason'),
        }
    events = [json.loads(line) for line in raw.splitlines() if line.strip()]
    if provider == 'codex':
        threads = [e for e in events if e.get('type') == 'thread.started']
        ends = [e for e in events if e.get('type') in ('turn.completed', 'turn.failed')]
        # The relay drops streams often; Codex retries and reports "Reconnecting... n/5" as error events.
        retries = [e for e in events if e.get('type') == 'error'
                   and str(e.get('message', '')).startswith('Reconnecting')]
        errors = [e for e in events if e.get('type') in ('error', 'turn.failed') and e not in retries]
        messages = [e['item']['text'] for e in events
                    if e.get('type') == 'item.completed'
                    and e.get('item', {}).get('type') == 'agent_message'
                    and isinstance(e['item'].get('text'), str)]
        completed = [e for e in ends if e.get('type') == 'turn.completed']
        diagnostics = [e['item'].get('message') for e in events
                       if e.get('type') == 'item.completed' and e.get('item', {}).get('type') == 'error']
        return {
            'cli_reported_success': bool(ends) and ends[-1]['type'] == 'turn.completed' and bool(messages) and not errors,
            'session_id': threads[-1].get('thread_id') if threads else None,
            'result': messages[-1] if messages else None,
            'usage': completed[-1].get('usage') if completed else None,
            'errors': errors,
            'reconnects': len(retries),
            'event_count': len(events),
            'diagnostics': diagnostics,
        }
    sessions = [e for e in events if e.get('type') == 'session']
    finals = [e for e in events if e.get('type') == 'final']
    ends = [e for e in events if e.get('type') == 'status' and e.get('phase') == 'turn_end']
    errors = [e for e in events if e.get('type') == 'error']
    usages = [e['usage'] for e in events if e.get('type') == 'status' and e.get('phase') == 'step_end' and e.get('usage')]
    reason = ends[-1].get('reason', {}) if ends else {}
    usage = {k: sum(u.get(k, 0) for u in usages) for k in ('inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'totalTokens')}
    return {
        'cli_reported_success': bool(finals) and reason.get('kind') == 'completed' and not errors,
        'session_id': sessions[-1].get('sessionId') if sessions else None,
        'result': finals[-1].get('text') if finals else None,
        'turn_end_reason': reason,
        'errors': errors,
        'usage': usage,
        'event_count': len(events),
    }


def popen_group_kwargs():
    """Return the Popen arguments that put the CLI in its own killable process group."""
    if os.name == 'nt':
        return {'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP}
    return {'start_new_session': True}


def stop_group(proc):
    if os.name == 'nt':
        try:
            subprocess.run(['taskkill', '/T', '/F', '/PID', str(proc.pid)],
                           capture_output=True, check=False, timeout=15)
        except (OSError, subprocess.SubprocessError):
            pass
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    # Clean up surviving children even when the CLI parent has already exited.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def wait_with_idle(proc, run, timeout, idle_timeout):
    """Return the exit code, None on idle stall; raise TimeoutExpired on total timeout."""
    start = last_change = time.monotonic()
    last_size = -1
    while True:
        try:
            return proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        now = time.monotonic()
        if now - start >= timeout:
            raise subprocess.TimeoutExpired(proc.args, timeout)
        size = sum((run / n).stat().st_size for n in ('stdout.log', 'stderr.log'))
        if size != last_size:
            last_size, last_change = size, now
        elif idle_timeout and now - last_change >= idle_timeout:
            return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('provider', choices=['deepseek', 'dsh', 'codex', 'claude'])
    p.add_argument('--cwd', required=True, type=Path)
    p.add_argument('--task-file', required=True, type=Path)
    p.add_argument('--runs-dir', required=True, type=Path)
    p.add_argument('--timeout', type=float, help='Total seconds; default per provider (codex 3600)')
    p.add_argument('--idle-timeout', type=float, help='Stop if stdout/stderr stay silent this long; 0 disables')
    p.add_argument('--resume', help='Continue an earlier session ID (Codex: thread_id from summary.json)')
    p.add_argument('--cli', type=Path, help='Override executable after separately verifying its version')
    p.add_argument('--model', help='Codex or Claude model ID')
    p.add_argument('--effort', choices=['low', 'medium', 'high', 'xhigh'], help='Codex or Claude reasoning effort')
    p.add_argument('--schema', type=Path, help='JSON Schema file (Codex or Claude)')
    p.add_argument('--tools', default='', help='Claude permits only Read,Glob,Grep')
    p.add_argument('--max-turns', type=int, help='Claude default 6 tool turns, not review rounds')
    p.add_argument('--max-budget-usd', type=float, help='Claude only; optional CLI-estimated stop threshold, unset by default')
    p.add_argument('--patch', type=Path, help='DeepSeek per-task config; default dsh-task.patch.yml')
    p.add_argument('--sandbox', choices=['read-only', 'workspace-write'], default='workspace-write',
                   help='Codex only; writes limited to --cwd')
    p.add_argument('--ephemeral', action='store_true', help='Codex only: do not persist the session (disables --resume)')
    a = p.parse_args()
    if a.provider == 'dsh':
        a.provider = 'deepseek'
    a.model = a.model or default_model(a.provider)
    if a.provider == 'codex':
        a.effort = a.effort or 'high'
    if a.provider == 'claude':
        a.effort = a.effort or 'medium'
        a.stream = True  # Progress prevents idle timeout from killing a silent JSON response.
    elif a.max_budget_usd is not None:
        p.error('--max-budget-usd applies only to claude')
    if a.max_turns is None:
        a.max_turns = 6 if a.provider == 'claude' else 12
    if a.timeout is None:
        a.timeout = DEFAULT_TIMEOUT[a.provider]
    if a.idle_timeout is None:
        a.idle_timeout = DEFAULT_IDLE_TIMEOUT[a.provider]
    if a.timeout <= 0 or a.idle_timeout < 0 or a.max_turns < 1:
        p.error('Timeout and max-turns must be positive')
    if a.max_budget_usd is not None and (not math.isfinite(a.max_budget_usd) or a.max_budget_usd <= 0):
        p.error('--max-budget-usd must be finite and positive')
    if a.provider == 'deepseek' and not a.patch:
        a.patch = DSH_DEFAULT_PATCH
    if a.provider != 'codex' and (a.sandbox != 'workspace-write' or a.ephemeral):
        p.error('--sandbox and --ephemeral apply only to codex')
    if a.provider == 'deepseek' and (a.tools or a.schema or a.model):
        p.error('Tool, schema and model flags do not apply to deepseek')
    if a.effort and a.provider not in ('codex', 'claude'):
        p.error('--effort applies only to codex or claude')
    if a.provider == 'claude':
        if a.patch:
            p.error('Claude reviews cannot use a DeepSeek patch')
        selected_tools = [name.strip() for name in a.tools.split(',') if name.strip()]
        if set(selected_tools) - {'Read', 'Glob', 'Grep'}:
            p.error('Claude review tools are restricted to Read,Glob,Grep')
    if a.provider == 'codex':
        if a.tools or a.patch:
            p.error('Tool and patch flags do not apply to codex')
        if a.resume and a.ephemeral:
            p.error('--resume needs a persisted session; drop --ephemeral')
    cwd = a.cwd.expanduser().resolve(strict=True)
    if not cwd.is_dir():
        p.error('--cwd must be a directory')
    task = a.task_file.expanduser().resolve(strict=True).read_text(encoding='utf-8')
    if not task.strip():
        p.error('Task must not be empty')
    env = os.environ.copy()
    cli_path, cli_source = resolve_cli(a.provider, a.cli, env)
    deepseek_source = None
    if a.provider == 'deepseek':
        deepseek_source = deepseek_credential_source(env)
        if not deepseek_source:
            p.error('DeepSeek API key missing; export DEEPSEEK_API_KEY or save it in DeepSeek Harness Settings > Models')
    if a.provider == 'claude':
        # Restricted mode ignores ordinary settings. Preserve only trusted user auth/routing env,
        # never hooks, permissions, plugins or project settings. Existing process env wins.
        config_dir = Path(env.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude'))).expanduser()
        settings_path = config_dir / 'settings.json'
        if settings_path.is_file():
            configured_env = json.loads(settings_path.read_text(encoding='utf-8')).get('env', {})
            for key in ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL'):
                if isinstance(configured_env.get(key), str):
                    env.setdefault(key, configured_env[key])
        try:
            claude_api_host = claude_destination(env)
        except ValueError as exc:
            p.error(str(exc))
        env.pop('CLAUDECODE', None)  # Explicit, non-interactive subagent; never a nested interactive shell.
        env['CLAUDE_CODE_EFFORT_LEVEL'] = a.effort
        env['CLAUDE_CODE_DISABLE_AUTO_MEMORY'] = '1'
        env['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] = '1'
        tool_list = ','.join(selected_tools)
        cmd = [cli_path, '-p', '--model', a.model, '--effort', a.effort,
               '--output-format', 'stream-json',
               '--safe-mode', '--restricted', '--disable-slash-commands', '--setting-sources', '',
               '--settings', '{"fastMode":false}', '--tools', tool_list,
               '--permission-mode', 'dontAsk', '--permission-prompts', 'none',
               '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
               '--max-turns', str(a.max_turns)]
        if a.max_budget_usd is not None:
            cmd += ['--max-budget-usd', str(a.max_budget_usd)]
        if tool_list:
            cmd += ['--allowedTools', tool_list]
        cmd += ['--verbose']
        if a.schema:
            schema = json.loads(a.schema.expanduser().resolve(strict=True).read_text(encoding='utf-8'))
            cmd += ['--json-schema', json.dumps(schema)]
        if a.resume:
            cmd += ['--resume', a.resume]
        cmd += ['--', task]
    elif a.provider == 'deepseek':
        patch_path = str(a.patch.expanduser().resolve(strict=True))
        cmd = [cli_path, 'headless', '--patch', patch_path, '--json']
        if a.resume:
            cmd += ['--session-id', a.resume]
        cmd += ['--', task]
    else:
        # `exec resume` takes no --sandbox/--cd, so sandbox is passed as config; cwd comes from Popen.
        cmd = [cli_path, 'exec']
        if a.resume:
            cmd += ['resume']
        cmd += ['--skip-git-repo-check', '--json', '--model', a.model,
                '-c', 'model_reasoning_effort=' + json.dumps(a.effort)]
        # Pin the write boundary so inherited config cannot add network or extra writable roots.
        cmd += ['-c', 'sandbox_mode=' + json.dumps(a.sandbox), '-c', 'approval_policy="never"',
                '-c', 'sandbox_workspace_write.network_access=false',
                '-c', 'sandbox_workspace_write.writable_roots=[]']
        if a.ephemeral:
            cmd += ['--ephemeral']
        if a.schema:
            cmd += ['--output-schema', str(a.schema.expanduser().resolve(strict=True))]
        if a.resume:
            cmd += [a.resume]
        cmd += ['--', task]
    if Path(cmd[0]).suffix.lower() in ('.cmd', '.bat'):
        p.error('Windows batch shims (.cmd/.bat) cannot receive multi-line task text: '
                'cmd.exe truncates or rewrites it. Pass --cli, set ' + CLI_ENV[a.provider]
                + ', or configure cli.' + a.provider + ' in config.json to point at the real .exe '
                '(for example the codex.exe in the vendor directory under '
                'node_modules\\@openai\\codex for npm installs, or claude.exe for a native '
                'Claude Code install).')
    if not Path(cmd[0]).is_file():
        p.error('CLI missing: ' + cmd[0] + '; pass --cli, set ' + CLI_ENV[a.provider]
                + ', or configure cli.' + a.provider + ' in config.json')
    name = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + a.provider + '-' + uuid.uuid4().hex[:8]
    run = a.runs_dir.expanduser().resolve() / name
    run.mkdir(parents=True, mode=0o700)
    (run / 'task.txt').write_text(task, encoding='utf-8')
    meta = {'provider': a.provider, 'cwd': str(cwd), 'timeout_seconds': a.timeout,
            'idle_timeout_seconds': a.idle_timeout, 'resume': a.resume, 'cli_path': cli_path,
            'cli_source': cli_source, 'command_without_task': cmd[:-1], 'run_dir': str(run)}
    if a.provider == 'deepseek':
        meta.update(entrypoint=cli_source, credential_source=deepseek_source)
        if a.patch.expanduser().resolve() == DSH_DEFAULT_PATCH.resolve():
            meta.update(config_provider='deepseek-official', config_model='deepseek-flash',
                        config_reasoning_effort='high', config_api_host='api.deepseek.com')
    if a.provider == 'claude':
        meta.update(requested_model=a.model, requested_effort=a.effort,
                    max_budget_usd=a.max_budget_usd, max_turns=a.max_turns,
                    tools=selected_tools, restricted=True, safe_mode=True,
                    fast_mode=False, auto_memory_disabled=True, api_host=claude_api_host)
    elif a.provider == 'codex':
        meta['requested_model'] = a.model
        meta['requested_effort'] = a.effort
        meta['sandbox'] = a.sandbox
        meta['ephemeral'] = a.ephemeral
    save(run / 'request.json', meta)
    start = time.monotonic()
    state = 'finished'
    rc = None
    with (run / 'stdout.log').open('w') as out, (run / 'stderr.log').open('w') as err:
        try:
            proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                    stdout=out, stderr=err, **popen_group_kwargs())
            meta['pid'] = proc.pid
            meta['process_group_id'] = proc.pid
            save(run / 'request.json', meta)
            print(json.dumps({'started': True, 'pid': proc.pid, 'run_dir': str(run)}), flush=True)
            try:
                rc = wait_with_idle(proc, run, a.timeout, a.idle_timeout)
                if rc is None:
                    state = 'idle_timeout'
                    stop_group(proc)
                    rc = proc.returncode
            except subprocess.TimeoutExpired:
                state = 'timeout'
                stop_group(proc)
                rc = proc.returncode
            except KeyboardInterrupt:
                state = 'cancelled'
                stop_group(proc)
                rc = proc.returncode
        except OSError as exc:
            state = 'launch_error'
            meta['launch_error'] = str(exc)
    summary = {**meta, 'state': state, 'exit_code': rc, 'elapsed_seconds': round(time.monotonic() - start, 2)}
    try:
        summary.update(parse_result(a.provider, (run / 'stdout.log').read_text(encoding='utf-8', errors='replace')))
    except (ValueError, TypeError, KeyError) as exc:
        summary['parse_error'] = str(exc)
    if a.provider == 'codex' and a.schema and isinstance(summary.get('result'), str):
        try:
            summary['structured_output'] = json.loads(summary['result'])
        except json.JSONDecodeError:
            pass
    summary['transport_ok'] = state == 'finished' and rc == 0 and summary.get('cli_reported_success') is True
    summary['handoff_ok'] = summary['transport_ok'] and not summary.get('permission_denials')
    if a.provider == 'claude':
        reported = summary.get('reported_models', [])
        if reported and set(reported) != {a.model}:
            contract_error(summary, 'CLI model reports differ from the requested Claude model; inspect routing')
        expected_tools = set(selected_tools) | ({'StructuredOutput'} if a.schema else set())
        if set(summary.get('reported_tools') or []) - expected_tools:
            contract_error(summary, 'CLI reported unexpected Claude tools')
        if summary.get('reported_mcp_servers'):
            contract_error(summary, 'CLI reported unexpected MCP servers')
        if summary.get('reported_fast_mode') not in (None, 'off'):
            contract_error(summary, 'CLI reported fast mode enabled')
    if a.schema and summary.get('structured_output') is None:
        contract_error(summary, 'Requested structured_output is missing')
    structured = summary.get('structured_output')
    if isinstance(structured, dict) and structured.get('ok') is False:
        contract_error(summary, 'Worker explicitly reported ok=false')
    summary['acceptance_required'] = True
    save(run / 'summary.json', summary)
    (run / 'exit-code.txt').write_text(str(rc) + '\n')
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)
    return 0 if summary['handoff_ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
