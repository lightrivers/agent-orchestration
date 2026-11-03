import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('worker', str(Path(__file__).resolve().parents[1] / 'scripts' / 'run_worker.py'))
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

class RunnerTests(unittest.TestCase):
 def setUp(self):
  self.config_tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.config_tmp.cleanup)
  self.config_home=Path(self.config_tmp.name)
  self.routing=patch.dict(os.environ,{'AGENT_ORCH_HOME':str(self.config_home),
   'AGENT_ORCH_DEEPSEEK_CLI':'','AGENT_ORCH_CODEX_CLI':'','AGENT_ORCH_CLAUDE_CLI':'',
   'ANTHROPIC_BASE_URL':'https://relay.example.com',
   'CLAUDE_CODE_USE_BEDROCK':'0','CLAUDE_CODE_USE_VERTEX':'0','CLAUDE_CODE_USE_FOUNDRY':'0'})
  self.routing.start(); self.addCleanup(self.routing.stop)
 def test_default_models(self):
  self.assertEqual(m.default_model('codex'),'gpt-6-astra')
  self.assertEqual(m.default_model('claude'),'claude-opus-5-5')
 def test_resolve_cli_explicit_source(self):
  with tempfile.TemporaryDirectory() as tmp:
   cli=Path(tmp)/'explicit-cli'
   self.assertEqual(m.resolve_cli('codex',explicit=cli,env={}),(str(cli),'explicit-cli'))
 def test_resolve_cli_env_source(self):
  with tempfile.TemporaryDirectory() as tmp:
   cli=Path(tmp)/'env-cli'
   with patch.dict(os.environ,{'AGENT_ORCH_HOME':tmp,'AGENT_ORCH_CODEX_CLI':str(cli)}):
    self.assertEqual(m.resolve_cli('codex'),(str(cli),'env'))
 def test_resolve_cli_config_source(self):
  with tempfile.TemporaryDirectory() as tmp:
   cli=Path(tmp)/'config-cli'
   (Path(tmp)/'config.json').write_text(json.dumps({'cli':{'claude':str(cli)}}))
   with patch.dict(os.environ,{'AGENT_ORCH_HOME':tmp,'AGENT_ORCH_CLAUDE_CLI':''}):
    self.assertEqual(m.resolve_cli('claude'),(str(cli),'config'))
 def test_resolve_cli_builtin_default_source(self):
  with tempfile.TemporaryDirectory() as tmp:
   default=Path(tmp)/'default-cli'
   with patch.dict(os.environ,{'AGENT_ORCH_HOME':tmp,'AGENT_ORCH_DEEPSEEK_CLI':'','AGENT_ORCH_CODEX_CLI':''}), \
     patch.object(m,'DSH_DESKTOP_CLI',str(default)),patch.object(m,'CODEX',str(default)):
    self.assertEqual(m.resolve_cli('deepseek'),(str(default),'desktop-managed-cli'))
    self.assertEqual(m.resolve_cli('codex'),(str(default),'default'))
 def test_resolve_cli_skips_broken_config(self):
  with tempfile.TemporaryDirectory() as tmp:
   (Path(tmp)/'config.json').write_text('{not valid json')
   default=Path(tmp)/'default-cli'
   with patch.dict(os.environ,{'AGENT_ORCH_HOME':tmp,'AGENT_ORCH_CODEX_CLI':''}),patch.object(m,'CODEX',str(default)):
    self.assertEqual(m.resolve_cli('codex'),(str(default),'default'))
 def test_resolve_cli_empty_values_are_unset(self):
  with tempfile.TemporaryDirectory() as tmp:
   config=Path(tmp)/'config.json'; cli=Path(tmp)/'config-cli'
   config.write_text(json.dumps({'cli':{'codex':''}}))
   with patch.dict(os.environ,{'AGENT_ORCH_HOME':tmp,'AGENT_ORCH_CODEX_CLI':''}), \
     patch.object(m,'CODEX',str(Path(tmp)/'default-cli')):
    self.assertEqual(m.resolve_cli('codex'),(str(Path(tmp)/'default-cli'),'default'))
    config.write_text(json.dumps({'cli':{'codex':str(cli)}}))
    self.assertEqual(m.resolve_cli('codex'),(str(cli),'config'))
 def test_codex_requires_completed_turn_and_final_message(self):
  events=[{'type':'thread.started','thread_id':'offline-thread'},
          {'type':'item.completed','item':{'type':'agent_message','text':'{"ok":true}'}},
          {'type':'turn.completed','usage':{'input_tokens':10,'output_tokens':3}}]
  summary=m.parse_result('codex','\n'.join(map(json.dumps,events)))
  self.assertTrue(summary['cli_reported_success'])
  self.assertEqual(summary['session_id'],'offline-thread')
  self.assertEqual(summary['usage']['output_tokens'],3)
  events.insert(1,{'type':'error','message':'Reconnecting... 1/5 (stream disconnected)'})
  ok=m.parse_result('codex','\n'.join(map(json.dumps,events)))
  self.assertTrue(ok['cli_reported_success']); self.assertEqual(ok['reconnects'],1)
  self.assertFalse(m.parse_result('codex','\n'.join(map(json.dumps,events+[{'type':'error','message':'fatal'}])))['cli_reported_success'])
  events.append({'type':'turn.failed','error':{'message':'synthetic failure'}})
  self.assertFalse(m.parse_result('codex','\n'.join(map(json.dumps,events)))['cli_reported_success'])
 def test_claude_parser_accepts_json_array_and_lines(self):
  good={'type':'result','is_error':False,'subtype':'success','result':'done'}
  for value in (json.dumps(good), json.dumps([{'type':'message'},good,{'type':'trailer'}]), json.dumps({'type':'message'})+'\n'+json.dumps(good)):
   self.assertTrue(m.parse_result('claude',value)['cli_reported_success'])
  self.assertFalse(m.parse_result('claude',json.dumps({'type':'result','subtype':'error','is_error':True}))['cli_reported_success'])
  with self.assertRaises(ValueError): m.parse_result('claude','[]')
  with self.assertRaises(ValueError): m.parse_result('claude','not json')
 def test_removed_flags_and_providers_are_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); cli,task=self._fake(root,self.CODEX_OK)
   common=['--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli)]
   for args in [['codebuddy']+common, ['codex']+common+['--sandbox','none'], ['codex']+common+['--network'],
    ['claude']+common+['--skip-permissions'], ['claude']+common+['--stream']]:
    with self.subTest(args=args[:1]+args[-2:]),self.assertRaises(SystemExit),contextlib.redirect_stderr(io.StringIO()):
     self._run(args)
   self.assertFalse((root/'seen-args.json').exists())
 def test_dsh_final_does_not_prove_success(self):
  for kind, expected in [('completed',True),('aborted',False),('error',False)]:
   data=[{'type':'status','phase':'turn_end','reason':{'kind':kind}},{'type':'final','text':'hello'}]
   self.assertEqual(m.parse_result('dsh','\n'.join(map(json.dumps,data)))['cli_reported_success'],expected)
 def test_timeout_and_empty_output(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve()
   cli=root/'fake-cli'
   cli.write_text('#!/usr/bin/python3\nimport time\ntime.sleep(30)\n')
   cli.chmod(0o700)
   task=root/'task.txt'; task.write_text('synthetic local test; no external call')
   args=['run_worker.py','codex','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli),'--timeout','0.1']
   with patch.object(sys,'argv',args),contextlib.redirect_stdout(io.StringIO()):
    self.assertEqual(m.main(),1)
   result=json.loads(next((root/'runs').glob('*/summary.json')).read_text())
   self.assertEqual(result['state'],'timeout')
   self.assertFalse(result['handoff_ok'])
   with self.assertRaises(ProcessLookupError): os.kill(result['pid'],0)

 def _fake(self, root, body):
  cli=root/'fake-cli'; cli.write_text('#!/usr/bin/python3\n'+body); cli.chmod(0o700)
  task=root/'task.txt'; task.write_text('offline check')
  return cli, task
 def _run(self, args):
  with patch.object(sys,'argv',['run_worker.py']+args),contextlib.redirect_stdout(io.StringIO()):
   return m.main()
 CODEX_OK=('import json,sys\nfrom pathlib import Path\nPath("seen-args.json").write_text(json.dumps(sys.argv[1:]))\n'
  'for e in [{"type":"thread.started","thread_id":"t1"},{"type":"item.completed","item":{"type":"agent_message","text":"{\\"ok\\":true}"}},{"type":"turn.completed","usage":{}}]: print(json.dumps(e))\n')
 def test_codex_default_is_workspace_write_persisted_with_long_timeout(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); cli,task=self._fake(root,self.CODEX_OK)
   self.assertEqual(self._run(['codex','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli)]),0)
   argv=json.loads((root/'seen-args.json').read_text())
   self.assertNotIn('--dangerously-bypass-approvals-and-sandbox',argv)
   self.assertIn('sandbox_mode="workspace-write"',argv)
   self.assertIn('sandbox_workspace_write.network_access=false',argv)
   self.assertIn('sandbox_workspace_write.writable_roots=[]',argv)
   self.assertNotIn('--ephemeral',argv)
   self.assertEqual(argv[argv.index('--model')+1],'gpt-6-astra')
   self.assertIn('model_reasoning_effort="high"',argv)
   r=json.loads(next((root/'runs').glob('*/summary.json')).read_text())
   self.assertEqual(r['timeout_seconds'],3600); self.assertEqual(r['session_id'],'t1')
 def test_codex_readonly_resume_and_schema(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); cli,task=self._fake(root,self.CODEX_OK)
   schema=root/'s.json'; schema.write_text('{"type":"object"}')
   self.assertEqual(self._run(['codex','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli),
     '--sandbox','read-only','--resume','t1','--schema',str(schema),'--model','gpt-6-astra']),0)
   argv=json.loads((root/'seen-args.json').read_text())
   self.assertEqual(argv[:2],['exec','resume'])
   self.assertIn('sandbox_mode="read-only"',argv)
   self.assertNotIn('--dangerously-bypass-approvals-and-sandbox',argv)
   self.assertEqual(argv[argv.index('--')-1],'t1')
   self.assertIn('--output-schema',argv)
   self.assertEqual(argv[argv.index('--model')+1],'gpt-6-astra')
   r=json.loads(next((root/'runs').glob('*/summary.json')).read_text())
   self.assertEqual(r['structured_output'],{'ok':True})
 def test_codex_resume_rejects_ephemeral(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); cli,task=self._fake(root,self.CODEX_OK)
   with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
    self._run(['codex','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli),'--resume','t1','--ephemeral'])
 def test_idle_timeout_stops_silent_worker(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); cli,task=self._fake(root,'import time\nprint("x",flush=True)\ntime.sleep(30)\n')
   self.assertEqual(self._run(['codex','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli),'--idle-timeout','2']),1)
   r=json.loads(next((root/'runs').glob('*/summary.json')).read_text())
   self.assertEqual(r['state'],'idle_timeout'); self.assertLess(r['elapsed_seconds'],10)
   with self.assertRaises(ProcessLookupError): os.kill(r['pid'],0)
 def test_deepseek_defaults_to_task_patch(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); cli,task=self._fake(root,'import json,os,sys\nfrom pathlib import Path\nPath("seen-args.json").write_text(json.dumps(sys.argv[1:]))\nPath("seen-env.json").write_text(json.dumps({"has_key":bool(os.environ.get("DEEPSEEK_API_KEY"))}))\n')
   with patch.dict(os.environ,{'DEEPSEEK_API_KEY':'fixture-only-key'}):
    self._run(['deepseek','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli)])
   argv=json.loads((root/'seen-args.json').read_text())
   self.assertTrue(argv[argv.index('--patch')+1].endswith('dsh-task.patch.yml'))
   self.assertEqual(json.loads((root/'seen-env.json').read_text()),{'has_key':True})
   request=json.loads(next((root/'runs').glob('*/request.json')).read_text())
   self.assertEqual(request['entrypoint'],'explicit-cli')
   self.assertEqual(request['credential_source'],'launch-environment')
   self.assertEqual(request['config_provider'],'deepseek-official')
   self.assertEqual(request['config_model'],'deepseek-flash')
   self.assertEqual(request['config_reasoning_effort'],'high')
   self.assertEqual(request['config_api_host'],'api.deepseek.com')
   for name in ('request.json','summary.json','stdout.log','stderr.log'):
    self.assertNotIn('fixture-only-key',(next((root/'runs').glob('*/'+name))).read_text())
  patch_text=(Path(__file__).resolve().parents[1]/'scripts'/'dsh-task.patch.yml').read_text()
  for expected in ('baseURL: https://api.deepseek.com/anthropic',
                   'provider: deepseek-official', 'model: deepseek-flash',
                   'reasoningEffort: high'):
   self.assertIn(expected,patch_text)
  self.assertNotIn('api.codekey.ai',patch_text)

 def test_deepseek_uses_desktop_managed_cli_by_default(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); cli,task=self._fake(root,'import json,sys\nfrom pathlib import Path\nPath("seen-args.json").write_text(json.dumps(sys.argv[1:]))\n')
   with patch.object(m,'DSH_DESKTOP_CLI',str(cli)), patch.dict(os.environ,{'DEEPSEEK_API_KEY':'fixture-only-key'}):
    self._run(['deepseek','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs')])
   request=json.loads(next((root/'runs').glob('*/request.json')).read_text())
   self.assertEqual(request['entrypoint'],'desktop-managed-cli')
   argv=json.loads((root/'seen-args.json').read_text())
   self.assertEqual(argv[0],'headless')

 def test_deepseek_loads_saved_credential_without_logging_it(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); credential_file=root/'.credentials.yaml'
   credential_file.write_text('version: 1\nrefs:\n  DEEPSEEK_API_KEY: stored-test-key\n')
   env={'DSH_HOME':str(root),'PATH':os.environ.get('PATH','')}
   result=m.subprocess.CompletedProcess(args=['ruby'],returncode=0,stdout='stored-test-key',stderr='')
   with patch.object(m.shutil,'which',return_value='/usr/bin/ruby'),patch.object(m.subprocess,'run',return_value=result) as reader:
    source=m.deepseek_credential_source(env)
   self.assertEqual(source,'dsh-credentials-file')
   self.assertEqual(env['DEEPSEEK_API_KEY'],'stored-test-key')
   self.assertTrue(reader.call_args.kwargs['capture_output'])
   self.assertNotIn('stored-test-key',str(reader.call_args.args))

 CLAUDE_OK=('import json,os,sys\nfrom pathlib import Path\n'
  'Path("seen-args.json").write_text(json.dumps(sys.argv[1:]))\n'
  'Path("seen-env.json").write_text(json.dumps({"effort":os.environ.get("CLAUDE_CODE_EFFORT_LEVEL"),"nested":os.environ.get("CLAUDECODE"),"auto_memory":os.environ.get("CLAUDE_CODE_DISABLE_AUTO_MEMORY")}))\n'
  'print(json.dumps({"type":"system","subtype":"init","model":"claude-opus-5-5"}))\n'
  'print(json.dumps({"type":"result","subtype":"success","is_error":False,"session_id":"c1","result":"review complete","modelUsage":{"claude-opus-5-5":{"inputTokens":10,"outputTokens":3}},"total_cost_usd":0.01,"num_turns":1}))\n')
 def test_claude_default_is_bounded_opus_medium_without_tools(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); cli,task=self._fake(root,self.CLAUDE_OK)
   with patch.dict(os.environ,{'CLAUDECODE':'1','CLAUDE_CODE_EFFORT_LEVEL':'high'}):
    self.assertEqual(self._run(['claude','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli)]),0)
   argv=json.loads((root/'seen-args.json').read_text())
   for flag,value in [('--model','claude-opus-5-5'),('--effort','medium'),('--max-turns','6'),('--tools',''),('--permission-mode','dontAsk'),('--permission-prompts','none'),('--setting-sources','')]:
    self.assertEqual(argv[argv.index(flag)+1],value)
   for flag in ['--safe-mode','--restricted','--strict-mcp-config','--disable-slash-commands']:
    self.assertIn(flag,argv)
   self.assertNotIn('--fallback-model',argv); self.assertNotIn('--dangerously-skip-permissions',argv)
   self.assertEqual(json.loads(argv[argv.index('--settings')+1]),{'fastMode':False})
   self.assertEqual(json.loads(argv[argv.index('--mcp-config')+1]),{'mcpServers':{}})
   env=json.loads((root/'seen-env.json').read_text())
   self.assertEqual(env,{'effort':'medium','nested':None,'auto_memory':'1'})
   r=json.loads(next((root/'runs').glob('*/summary.json')).read_text())
   self.assertEqual(r['requested_model'],'claude-opus-5-5'); self.assertEqual(r['requested_effort'],'medium')
   self.assertEqual(r['reported_models'],['claude-opus-5-5']); self.assertIsNone(r['max_budget_usd']); self.assertNotIn('--max-budget-usd',argv)
   self.assertEqual(r['session_id'],'c1'); self.assertEqual(r['reported_cost_usd'],0.01)
   self.assertEqual(r['api_host'],'relay.example.com')
 def test_claude_read_tools_resume_stream_and_schema(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve()
   body=self.CLAUDE_OK.replace('"result":"review complete"','"result":"review complete","structured_output":{"ok":true}')
   # The body is Python source, so JSON true must be Python True.
   cli,task=self._fake(root,body.replace('"ok":true','"ok":True'))
   schema=root/'schema.json'; schema.write_text('{"type":"object"}')
   self.assertEqual(self._run(['claude','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli),
    '--tools','Read,Glob,Grep','--schema',str(schema),'--resume','c1','--max-budget-usd','1','--max-turns','3']),0)
   argv=json.loads((root/'seen-args.json').read_text())
   self.assertEqual(argv[argv.index('--allowedTools')+1],'Read,Glob,Grep')
   self.assertEqual(argv[argv.index('--resume')+1],'c1'); self.assertIn('--verbose',argv)
   self.assertEqual(argv[argv.index('--output-format')+1],'stream-json')
   self.assertEqual(json.loads(argv[argv.index('--json-schema')+1]),{'type':'object'})
   r=json.loads(next((root/'runs').glob('*/summary.json')).read_text())
   self.assertEqual(argv[argv.index('--max-budget-usd')+1],'1.0')
   self.assertEqual(r['structured_output'],{'ok':True}); self.assertEqual(r['max_budget_usd'],1)
 def test_claude_rejects_write_execution_bypass_and_invalid_budget(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); cli,task=self._fake(root,self.CLAUDE_OK)
   base=['claude','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli)]
   for flags in [['--tools','Write'],['--tools','Bash'],['--tools','Agent'],['--tools','default'],
    ['--patch','unused'],
    ['--max-budget-usd','0'],['--max-budget-usd','-1'],['--max-budget-usd','nan'],['--max-budget-usd','inf']]:
    with self.subTest(flags=flags),self.assertRaises(SystemExit),contextlib.redirect_stderr(io.StringIO()):
     self._run(base+flags)
   self.assertFalse((root/'seen-args.json').exists())
 def test_claude_errors_limits_and_permission_denials_are_not_success(self):
  for subtype in ['error_max_budget_usd','error_max_turns','error_during_execution']:
   data={'type':'result','subtype':subtype,'is_error':True,'errors':['stopped']}
   self.assertFalse(m.parse_result('claude',json.dumps(data))['cli_reported_success'])
  self.assertFalse(m.parse_result('claude',json.dumps({'type':'result','subtype':'success','is_error':False}))['cli_reported_success'])
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve()
   body=self.CLAUDE_OK.replace('"result":"review complete"','"result":"review complete","permission_denials":[{"tool_name":"Read"}]')
   cli,task=self._fake(root,body)
   self.assertEqual(self._run(['claude','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli)]),1)
   r=json.loads(next((root/'runs').glob('*/summary.json')).read_text())
   self.assertTrue(r['transport_ok']); self.assertFalse(r['handoff_ok'])
 def test_claude_result_only_reports_model_and_counts_builtin_retries(self):
  data=[{'type':'system','subtype':'api_retry','attempt':1},
   {'type':'result','subtype':'success','is_error':False,'result':'done',
    'modelUsage':{'claude-opus-5-5':{'inputTokens':100}},'total_cost_usd':0.1}]
  r=m.parse_result('claude','\n'.join(map(json.dumps,data)))
  self.assertEqual(r['reported_models'],['claude-opus-5-5']); self.assertEqual(r['api_retries'],1)
  self.assertTrue(r['cli_reported_success'])
 def test_claude_unexpected_model_tools_mcp_or_fast_mode_fail_handoff(self):
  scenarios=[self.CLAUDE_OK.replace('claude-opus-5-5','different-model'),
   self.CLAUDE_OK.replace('"subtype":"init","model"','"subtype":"init","tools":["Bash"],"model"'),
   self.CLAUDE_OK.replace('"subtype":"init","model"','"subtype":"init","mcp_servers":[{"name":"unwanted"}],"model"'),
   self.CLAUDE_OK.replace('"subtype":"success","is_error"','"subtype":"success","fast_mode_state":"on","is_error"')]
  for body in scenarios:
   with self.subTest(body=body),tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp).resolve(); cli,task=self._fake(root,body)
    self.assertEqual(self._run(['claude','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli)]),1)
    r=json.loads(next((root/'runs').glob('*/summary.json')).read_text())
    self.assertTrue(r['transport_ok']); self.assertFalse(r['handoff_ok'])
    self.assertIn('contract_error',r)
 def test_claude_destination_accepts_any_https_relay_but_rejects_unsafe_urls(self):
  self.assertEqual(m.claude_destination({'ANTHROPIC_BASE_URL':'https://relay.example.com'}),'relay.example.com')
  self.assertEqual(m.claude_destination({'ANTHROPIC_BASE_URL':'https://relay.example:8443/v1/'}),'relay.example')
  self.assertEqual(m.claude_destination({}),'api.anthropic.com')
  for url in ['http://relay.example.com', 'https://relay.example.com:invalid', 'https://', 'ftp://relay.example',
   'https://user:secret@relay.example.com', 'https://relay.example.com/?token=secret', 'https://relay.example.com/#private']:
   with self.subTest(url=url),self.assertRaises(ValueError) as caught:
    m.claude_destination({'ANTHROPIC_BASE_URL':url})
   self.assertNotIn('secret',str(caught.exception)); self.assertNotIn('private',str(caught.exception))
  for key in ['CLAUDE_CODE_USE_BEDROCK','CLAUDE_CODE_USE_VERTEX','CLAUDE_CODE_USE_FOUNDRY']:
   with self.subTest(key=key),self.assertRaises(ValueError):
    m.claude_destination({'ANTHROPIC_BASE_URL':'https://relay.example.com',key:'1'})
 def test_claude_insecure_destination_never_launches_cli(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp).resolve(); cli,task=self._fake(root,self.CLAUDE_OK)
   with patch.dict(os.environ,{'ANTHROPIC_BASE_URL':'http://other.example'}),self.assertRaises(SystemExit),contextlib.redirect_stderr(io.StringIO()):
    self._run(['claude','--cwd',str(root),'--task-file',str(task),'--runs-dir',str(root/'runs'),'--cli',str(cli)])
   self.assertFalse((root/'seen-args.json').exists()); self.assertFalse((root/'runs').exists())
 def test_contract_errors_accumulate_without_overwriting(self):
  summary={'handoff_ok':True}
  m.contract_error(summary,'wrong model'); m.contract_error(summary,'wrong tools')
  self.assertEqual(summary['contract_errors'],['wrong model','wrong tools'])
  self.assertEqual(summary['contract_error'],'wrong model; wrong tools')
  self.assertFalse(summary['handoff_ok'])

if __name__=='__main__': unittest.main(verbosity=2)
