#!/usr/bin/env python3
"""Prepare/review or install only the design-feedback user integrations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time


def write(path, raw, mode=0o600):
    path.parent.mkdir(parents=True,exist_ok=True)
    if path.is_symlink(): raise ValueError('refusing symlink destination: '+str(path))
    fd,temp=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f:
            os.fchmod(f.fileno(),mode); f.write(raw); f.flush(); os.fsync(f.fileno())
        os.replace(temp,path)
    finally:
        if os.path.exists(temp): os.unlink(temp)


def merged_hooks(data,command,codex):
    data=json.loads(json.dumps(data)); events=data.setdefault('hooks',{})
    for event in ('SessionStart','UserPromptSubmit','Stop'):
        groups=events.setdefault(event,[])
        existing=[h for group in groups for h in group.get('hooks',[]) if 'design_feedback.py' in h.get('command','')]
        if len(existing)>1: raise ValueError('multiple design-feedback handlers')
        handler=dict(type='command',command=command,timeout=10)
        if codex and event!='Stop': handler['additionalContextLimit']=3500
        if existing:
            existing[0].clear(); existing[0].update(handler)
        else: groups.append(dict(hooks=[handler]))
    return data


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--home',type=Path,required=True)
    p.add_argument('--user-home',type=Path,default=Path.home())
    p.add_argument('--guidance-checkout',type=Path,required=True)
    p.add_argument('--guideline-path',required=True)
    p.add_argument('--case-dir',required=True)
    p.add_argument('--artifact-root',action='append',default=[])
    p.add_argument('--retrieval-scripts'); p.add_argument('--retrieval-lab'); p.add_argument('--retrieval-command')
    p.add_argument('--apply',action='store_true'); p.add_argument('--start-worker',action='store_true')
    a=p.parse_args(); home=a.home.expanduser().resolve(); user=a.user_home.expanduser().resolve()
    home.mkdir(parents=True,exist_ok=True,mode=0o700); os.chmod(home,0o700)
    source=Path(__file__).parent
    files={name:(source/name).read_bytes() for name in ('design_feedback.py','skills/design-feedback/SKILL.md')}
    version=hashlib.sha256(b''.join(files.values())).hexdigest()[:16]
    release=home/'releases'/version
    cfg=dict(schema_version=1,guidance_checkout=str(a.guidance_checkout.resolve()),guideline_path=a.guideline_path,
        case_dir=a.case_dir,publish_mode='trunk-direct',artifact_roots=a.artifact_root,
        retrieval_scripts=a.retrieval_scripts,retrieval_lab=a.retrieval_lab,retrieval_command=a.retrieval_command,
        refresh_before_recover=False,recover_registered_only=True,source_release=version)
    prior_profile=home/'profile.json'
    if prior_profile.is_symlink(): raise ValueError('profile symlink')
    previous=json.loads(prior_profile.read_text(encoding='utf-8')) if prior_profile.exists() else {}
    cfg['started_at']=previous.get('started_at',time.time())
    launcher='#!'+sys.executable+'\nimport os,sys\nos.execv('+repr(sys.executable)+', ['+repr(sys.executable)+', '+repr(str(release/'design_feedback.py'))+', "--home", '+repr(str(home))+']+sys.argv[1:])\n'
    destinations={home/'profile.json':(json.dumps(cfg,ensure_ascii=False,indent=2)+'\n').encode()}
    for relative in ('.agents/skills/design-feedback/SKILL.md','.claude/skills/design-feedback/SKILL.md'):
        destinations[user/relative]=files['skills/design-feedback/SKILL.md']
    destinations[user/'.local/bin/design-feedback']=launcher.encode()
    expected={}
    for codex,relative in ((True,'.codex/hooks.json'),(False,'.claude/settings.json')):
        path=user/relative
        if path.is_symlink(): raise ValueError('hook config is symlink')
        data=json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
        expected[path]=path.read_bytes() if path.exists() else None
        command=shlex.join([sys.executable,str(release/'design_feedback.py'),'--home',str(home),'hook','--harness','codex' if codex else 'claude-code'])
        updated=merged_hooks(data,command,codex)
        destinations[path]=(json.dumps(updated,ensure_ascii=False,indent=2)+'\n').encode()
    for relative in ('.codex/AGENTS.md','.claude/CLAUDE.md'):
        path=user/relative
        if path.is_symlink(): raise ValueError('instruction file is symlink')
        text=path.read_text(encoding='utf-8') if path.exists() else ''
        expected[path]=path.read_bytes() if path.exists() else None
        begin='<!-- design-feedback:instructions -->'; end='<!-- /design-feedback:instructions -->'
        block=begin+'\n画面・UIの制作前と、本人がその画面へ反応したときは `design-feedback` スキルを使う。共有指針と用途に合う事例を取り出し、評価は画面の版・理由・適用範囲と組で記録する。手順とコマンドはスキルを正本とし、未確認の一般化は候補に残す。\n'+end
        if begin in text:
            if text.count(begin)!=1 or text.count(end)!=1: raise ValueError('instruction markers invalid')
            text=text[:text.index(begin)]+block+text[text.index(end)+len(end):]
        else: text=text.rstrip()+'\n\n'+block+'\n'
        destinations[path]=text.encode()
    job=dict(Label='io.agents-harnesses.design-feedback',ProgramArguments=[sys.executable,str(release/'design_feedback.py'),'--home',str(home),'sweep'],
        StartInterval=300,RunAtLoad=True,ProcessType='Background',WorkingDirectory=str(home),
        StandardOutPath=str(home/'worker.log'),StandardErrorPath=str(home/'worker-error.log'),
        EnvironmentVariables=dict(PATH='/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'))
    job_path=user/'Library/LaunchAgents/io.agents-harnesses.design-feedback.plist'
    destinations[job_path]=plistlib.dumps(job)
    expected[job_path]=job_path.read_bytes() if job_path.exists() else None
    for path in destinations:
        if path.is_symlink(): raise ValueError('destination symlink')
        expected.setdefault(path,path.read_bytes() if path.exists() else None)
    plan=dict(version=version,applied=False,codex_hook_trust_required=True,native_session_acceptance_pending=True,
        destinations=[str(x) for x in destinations],profile=cfg)
    # The review plan contains only our handlers and digests, never other settings.
    candidate=home/'prepared'/version; candidate.mkdir(parents=True,exist_ok=True,mode=0o700)
    changes=[]
    for path,raw in destinations.items():
        item=dict(path=str(path),after_sha256=hashlib.sha256(raw).hexdigest())
        if path in (user/'.codex/hooks.json',user/'.claude/settings.json'):
            data=json.loads(raw)
            item['new_handlers']={event:[h for group in groups for h in group.get('hooks',[]) if 'design_feedback.py' in h.get('command','')] for event,groups in data.get('hooks',{}).items() if any('design_feedback.py' in h.get('command','') for g in groups for h in g.get('hooks',[]))}
        changes.append(item)
    write(candidate/'changes.json',(json.dumps(changes,ensure_ascii=False,indent=2)+'\n').encode())
    write(candidate/'plan.json',(json.dumps(plan,ensure_ascii=False,indent=2)+'\n').encode())
    if not a.apply:
        print(json.dumps(dict(status='prepared',plan=str(candidate/'plan.json')),ensure_ascii=False)); return
    for name,raw in files.items():
        target=release/name
        if target.exists() and target.read_bytes()!=raw: raise ValueError('immutable release mismatch')
        if not target.exists(): write(target,raw)
    backup=home/'backups'/str(time.time_ns()); backup.mkdir(parents=True,mode=0o700)
    manifest={}
    # Validate every baseline before making the first runtime config change.
    for path in destinations:
        if (path.read_bytes() if path.exists() else None)!=expected[path]: raise ValueError('configuration changed concurrently: '+str(path))
    for path,raw in destinations.items():
        if path.exists():
            original=path.read_bytes(); saved=backup/hashlib.sha256(str(path).encode()).hexdigest()
            write(saved,original); manifest[str(path)]=dict(backup=str(saved),sha256=hashlib.sha256(original).hexdigest())
        else: manifest[str(path)]=dict(backup=None)
    changed=[]
    try:
        for path,raw in destinations.items():
            write(path,raw,0o700 if path==user/'.local/bin/design-feedback' else 0o600); changed.append(path)
    except Exception:
        for path in reversed(changed):
            if path.read_bytes()!=destinations[path]: continue
            old=expected[path]
            if old is None: path.unlink()
            else: write(path,old,0o700 if path==user/'.local/bin/design-feedback' else 0o600)
        raise
    write(backup/'manifest.json',(json.dumps(manifest,indent=2)+'\n').encode())
    plan.update(applied=True,backup=str(backup),installed_at=time.time())
    if a.start_worker:
        plan['worker_loaded']=False
        if sys.platform!='darwin': plan['worker_error']='launchd is available only on macOS'
        else:
            try:
                domain='gui/'+str(os.getuid())
                subprocess.run(['/bin/launchctl','bootout',domain+'/'+job['Label']],capture_output=True,check=False)
                r=subprocess.run(['/bin/launchctl','bootstrap',domain,str(job_path)],capture_output=True,text=True,check=False)
                plan['worker_loaded']=r.returncode==0
                if r.returncode: plan['worker_error']=r.stderr.strip()[:300]
            except OSError as e: plan['worker_error']=str(e)[:300]
    write(home/'installation.json',(json.dumps(plan,ensure_ascii=False,indent=2)+'\n').encode())
    print(json.dumps(dict(status='installed',receipt=str(home/'installation.json'),codex_hook_trust_required=True),ensure_ascii=False))


if __name__=='__main__': main()
