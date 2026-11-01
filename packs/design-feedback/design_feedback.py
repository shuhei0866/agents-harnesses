#!/usr/bin/env python3
"""Local design-feedback capture, context, and serial Git projection. No model calls."""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import time

VERSION = 1
UNSET = object()
DESIGN = re.compile(r'design|mockup|dashboard|\bUI\b|layout|デザイン|画面|モック|配置|余白|配色|見やす|見づら|キャッチコピー|アフォーダンス|図表', re.I)
REACTION = re.compile(r'見やす|見づら|分かり[やづに]|わかり[やづに]|邪魔|使い[やづに]|しづら|好き|嫌|いい|良い|悪い|(?:左|右|上|下)(?:の方|側|に置|へ移)|やめ|不要|残し|詰め|OK|better|worse|prefer|hard to|keep|remove', re.I)
UNRELATED_CREATION = re.compile(r'案内文|メール(?:の|を|本文)|小説|議事録|翻訳|文章(?:の|を)|translate|write (?:an? )?(?:email|story|essay)',re.I)
MACHINE = re.compile(r'^\s*(?:\[design-feedback\]|<heartbeat\b|<system-reminder>|<subagent_notification>|<task-notification>|# AGENTS\.md|<environment_context>|Stop hook feedback:|This session is being continued|You are a continuing discussion partner|Base directory for this skill:)')
CASE_FIELDS = {'event_id','key','summary','reason','inferred_reason','purpose','scope','tags','authority','generalization','guideline_action','conditions','artifact_id','supersedes','exception_of','safe_to_share'}
BEGIN = '<!-- design-feedback:begin -->'
END = '<!-- design-feedback:end -->'


def digest(value):
    raw = value if isinstance(value, bytes) else json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()
    return hashlib.sha256(raw).hexdigest()


def default_home():
    return Path(os.environ.get('DESIGN_FEEDBACK_HOME', Path.home()/'.local/share/agents-harnesses/design-feedback')).expanduser()


def profile(home):
    p = home/'profile.json'
    if p.is_symlink():
        raise ValueError('profile must not be a symlink')
    return json.loads(p.read_text()) if p.exists() else {}


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name+'.'+str(os.getpid())+'.tmp')
    raw = value if isinstance(value, bytes) else (json.dumps(value, ensure_ascii=False, indent=2)+'\n').encode()
    with open(temp, 'xb') as f:
        os.chmod(temp, 0o600); f.write(raw); f.flush(); os.fsync(f.fileno())
    os.replace(temp, path)


@contextlib.contextmanager
def database(home):
    if home.is_symlink():
        raise ValueError('state home must not be a symlink')
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(home, 0o700)
    p = home/'feedback.sqlite3'
    if p.is_symlink():
        raise ValueError('database must not be a symlink')
    db = sqlite3.connect(p, timeout=5); db.row_factory = sqlite3.Row
    os.chmod(p, 0o600)
    db.executescript('''
    CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, session TEXT, turn TEXT,
      harness TEXT, project TEXT, created REAL, text TEXT, source TEXT, artifacts TEXT,
      disposition TEXT DEFAULT 'pending', note TEXT DEFAULT '', reminded INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS exhibits(id TEXT PRIMARY KEY, session TEXT, project TEXT,
      created REAL, label TEXT, original TEXT, sha256 TEXT, snapshot TEXT, presented INTEGER);
    CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, project TEXT, active_until REAL,
      transcript TEXT, harness TEXT, last_event TEXT);
    CREATE TABLE IF NOT EXISTS cases(id TEXT PRIMARY KEY, event_id TEXT, payload TEXT,
      created REAL, delivered TEXT);
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    ''')
    try:
        yield db
        db.commit()
    finally:
        db.close()


def meta(db, key, value=UNSET):
    if value is not UNSET:
        db.execute('INSERT OR REPLACE INTO meta VALUES(?,?)', (key,json.dumps(value)))
    row=db.execute('SELECT value FROM meta WHERE key=?',(key,)).fetchone()
    return json.loads(row[0]) if row else None


def git(cwd, *args):
    r=subprocess.run(['git','-C',str(cwd),*args],capture_output=True,text=True,timeout=45)
    if r.returncode:
        raise RuntimeError('git '+args[0]+' failed: '+r.stderr.strip()[:300])
    return r.stdout.strip()


def project_id(cwd):
    p=Path(cwd).expanduser().resolve()
    try:
        key=git(p,'config','--get','remote.origin.url')
        key=re.sub(r'^git@([^:]+):',r'https://\1/',key).removesuffix('.git')
    except (RuntimeError, OSError):
        key=str(p)
    return digest(key)[:24]


def session_id(payload):
    return str(payload.get('session_id') or os.environ.get('CODEX_THREAD_ID') or os.environ.get('CLAUDE_SESSION_ID') or '')


def capture(db, payload, harness, text, source=None, force=False):
    sid=session_id(payload)
    if not sid:
        return None
    if text.lstrip().startswith('You are a continuing discussion partner.'):
        meta(db,'excluded_session:'+sid,'agent_consultation')
    if meta(db,'excluded_session:'+sid) or payload.get('agent_id') or payload.get('is_sidechain'):
        return None
    if not text.strip() or MACHINE.search(text) or len(text)>32000:
        return None
    project=project_id(payload.get('cwd',os.getcwd()))
    prior=db.execute('SELECT * FROM sessions WHERE id=?',(sid,)).fetchone()
    active=bool(prior and prior['active_until']>time.time())
    relevant=bool(DESIGN.search(text)) or (active and len(text)<2000 and REACTION.search(text) and not UNRELATED_CREATION.search(text))
    if not relevant and not force:
        return None
    source_version=None
    transcript=payload.get('transcript_path')
    if transcript:
        try:
            st=Path(transcript).stat(); source_version=[st.st_size,st.st_mtime_ns]
        except OSError: pass
    turn=str(payload.get('turn_id') or payload.get('uuid') or digest([text,source_version]))
    eid='evt-'+digest([harness,sid,turn,digest(text)])[:32]
    artifacts=[r['id'] for r in db.execute('SELECT id FROM exhibits WHERE session=? AND presented=1 AND created>? ORDER BY created DESC LIMIT 4',(sid,time.time()-86400))]
    # Only the latest presentation group belongs to a new reaction.
    if artifacts:
        newest=db.execute('SELECT created FROM exhibits WHERE id=?',(artifacts[0],)).fetchone()[0]
        artifacts=[x for x in artifacts if newest-db.execute('SELECT created FROM exhibits WHERE id=?',(x,)).fetchone()[0]<120]
    source=source or dict(kind='hook',session_id=sid,turn_id=turn,transcript=payload.get('transcript_path'))
    db.execute('INSERT OR IGNORE INTO events(id,session,turn,harness,project,created,text,source,artifacts) VALUES(?,?,?,?,?,?,?,?,?)',
        (eid,sid,turn,harness,project,time.time(),text,json.dumps(source),json.dumps(artifacts)))
    db.execute('INSERT OR REPLACE INTO sessions VALUES(?,?,?,?,?,?)',(sid,project,time.time()+14400,payload.get('transcript_path'),harness,eid))
    if meta(db,'capture_started_at') is None: meta(db,'capture_started_at',time.time())
    return eid


def session_env():
    return os.environ.get('CODEX_THREAD_ID') or os.environ.get('CLAUDE_SESSION_ID') or ''


def exhibit(home, db, cfg, filename, label, sid, cwd, presented=True):
    path=Path(filename).expanduser()
    if path.is_symlink():
        raise ValueError('exhibit must not be a symlink')
    path=path.resolve()
    roots=[Path(x).expanduser().resolve() for x in cfg.get('artifact_roots',[])]+[Path(cwd).resolve()]
    if not any(path.is_relative_to(r) for r in roots) or path.suffix.lower() not in ('.html','.png','.jpg','.jpeg','.webp','.svg'):
        raise ValueError('exhibit outside configured artifact roots or unsupported type')
    if not path.is_file() or path.stat().st_size>5_000_000:
        raise ValueError('exhibit unavailable or exceeds 5 MB')
    raw=path.read_bytes(); sha=digest(raw); aid='art-'+digest([sid,str(path),sha,label])[:32]
    dest=home/'artifacts'/(aid+path.suffix.lower())
    if not dest.exists(): atomic(dest,raw)
    os.chmod(dest.parent,0o700)
    db.execute('INSERT OR IGNORE INTO exhibits VALUES(?,?,?,?,?,?,?,?,?)',(aid,sid,project_id(cwd),time.time(),label,str(path),sha,str(dest),int(presented)))
    if presented: db.execute('UPDATE exhibits SET created=?,presented=1 WHERE id=?',(time.time(),aid))
    return dict(artifact_id=aid,sha256=sha,snapshot=str(dest),presented=presented)


def record(db, value):
    if not isinstance(value,dict) or set(value)-CASE_FIELDS:
        raise ValueError('unknown case fields')
    event=db.execute('SELECT * FROM events WHERE id=?',(value.get('event_id'),)).fetchone()
    if not event: raise ValueError('captured event not found')
    for name in ('summary','purpose','conditions'):
        if not isinstance(value.get(name),str) or not value[name].strip() or len(value[name])>1200:
            raise ValueError('invalid '+name)
    for name in ('reason','inferred_reason'):
        if value.get(name) is not None and (not isinstance(value[name],str) or len(value[name])>1200):
            raise ValueError('invalid '+name)
    if value.get('scope') not in ('common','project') or value.get('authority') not in ('user_explicit','candidate'):
        raise ValueError('invalid scope or authority')
    if value['scope']=='project' and value['authority']=='user_explicit' and event['project']=='unassigned':
        raise ValueError('verify original project with source and assign-project before accepting')
    if value.get('generalization','none') not in ('none','explicit','proposed'):
        raise ValueError('invalid generalization')
    if value.get('guideline_action','evidence') not in ('evidence','add'):
        raise ValueError('invalid guideline action')
    if value['scope']=='common' and value['authority']=='user_explicit' and value.get('generalization')!='explicit':
        raise ValueError('common accepted case requires explicit generalization')
    if value.get('guideline_action')=='add' and not (value['scope']=='common' and value['authority']=='user_explicit' and value.get('generalization')=='explicit'):
        raise ValueError('only explicit common policy can change managed guidance')
    for name in ('tags','supersedes','exception_of'):
        if not isinstance(value.get(name,[]),list) or len(value.get(name,[]))>20 or any(not isinstance(x,str) or len(x)>100 for x in value.get(name,[])):
            raise ValueError('invalid '+name)
    if not isinstance(value.get('safe_to_share'),bool): raise ValueError('safe_to_share must be explicit')
    key=value.get('key','decision')
    if not isinstance(key,str) or not re.fullmatch(r'[a-z0-9_-]{1,64}',key): raise ValueError('invalid key')
    aid=value.get('artifact_id'); bound=json.loads(event['artifacts'])
    if aid is None and len(bound)==1: aid=bound[0]
    if aid and aid not in bound: raise ValueError('artifact was not bound at feedback time')
    art=db.execute('SELECT * FROM exhibits WHERE id=?',(aid,)).fetchone() if aid else None
    cid='df-'+digest([event['id'],key])[:32]
    data={k:value.get(k) for k in ('summary','reason','inferred_reason','purpose','scope','conditions','authority')}
    data.update(schema_version=VERSION,id=cid,project=event['project'] if value['scope']=='project' else None,
        tags=value.get('tags',[]),generalization=value.get('generalization','none'),guideline_action=value.get('guideline_action','evidence'),
        source=dict(event_id=event['id'],text_sha256=digest(event['text']),harness=event['harness']),
        artifact=dict(id=aid,sha256=art['sha256'],label=art['label']) if art else None,
        artifact_status='bound' if art else 'unresolved',supersedes=value.get('supersedes',[]),exception_of=value.get('exception_of',[]),
        safe_to_share=value['safe_to_share'],observed_at=dt.datetime.fromtimestamp(event['created'],dt.timezone.utc).isoformat())
    raw=json.dumps(data,sort_keys=True,ensure_ascii=False)
    old=db.execute('SELECT payload FROM cases WHERE id=?',(cid,)).fetchone()
    if old and old[0]!=raw: raise ValueError('case is immutable; record a new key and supersedes link')
    for relation in data['supersedes']+data['exception_of']:
        if not re.fullmatch(r'df-[a-f0-9]{32}',relation): raise ValueError('invalid case relation')
    db.execute('INSERT OR IGNORE INTO cases VALUES(?,?,?,?,NULL)',(cid,event['id'],raw,time.time()))
    db.execute("UPDATE events SET disposition='recorded' WHERE id=?",(event['id'],))
    return dict(case_id=cid,delivery='queued' if data['safe_to_share'] else 'private_only')


def all_cases(db,cfg):
    result={r['id']:json.loads(r['payload']) for r in db.execute('SELECT id,payload FROM cases')}
    repo=cfg.get('guidance_checkout')
    if repo:
        case_dir=relative(cfg.get('case_dir','docs/design-feedback/cases'))
        try:
            proc=subprocess.run(['git','-C',str(repo),'archive','origin/main','--',case_dir],capture_output=True,timeout=5)
            if proc.returncode==0 and len(proc.stdout)<=20_000_000:
                with tarfile.open(fileobj=io.BytesIO(proc.stdout)) as archive:
                    for entry in archive.getmembers()[:3000]:
                        if entry.isfile() and entry.name.endswith('.json') and entry.size<20000:
                            c=json.load(archive.extractfile(entry)); result.setdefault(c['id'],c)
        except (RuntimeError,ValueError,OSError):
            pass
    return list(result.values())


def context(db,cfg,query,cwd,sid=''):
    project=project_id(cwd); terms=set(re.findall(r'[a-z][a-z0-9_-]+|[一-龥ぁ-んァ-ン]{2,}',query.lower()))
    cases=all_cases(db,cfg)
    # Only an accepted, explicitly common correction can retire common guidance.
    retired=set()
    for c in cases:
        if c['authority']=='user_explicit' and (c['scope']=='common' or c.get('project')==project):
            retired.update(c.get('supersedes',[]))
    usable=[]
    for c in cases:
        if c['id'] in retired or c['authority']!='user_explicit' or (c['scope']=='project' and c.get('project')!=project): continue
        text=json.dumps(c,ensure_ascii=False).lower()
        score=sum(t in text for t in terms)+(2 if c.get('project')==project else 0)
        usable.append((score,c))
    chosen=[c for _,c in sorted(usable,key=lambda x:(x[0],x[1]['observed_at']),reverse=True)[:5]]
    pending=[dict(r) for r in db.execute("SELECT id,created,project FROM events WHERE disposition='pending' AND (session=? OR project=? OR project='unassigned') ORDER BY created DESC LIMIT 8",(sid,project))]
    return dict(session_id=sid or None,guideline=dict(checkout=cfg.get('guidance_checkout'),ref='origin/main',path=cfg.get('guideline_path')),
        cases=chosen,pending=pending,pipeline_health=dict(last_sweep=meta(db,'last_sweep'),publish_error=meta(db,'publish_error')),
        notice='Pending captures are unassessed. Current instructions and scoped exceptions take precedence.')


def relative(path):
    p=Path(path)
    if p.is_absolute() or '..' in p.parts or '.git' in p.parts or not p.parts: raise ValueError('unsafe repository-relative path')
    return p.as_posix()


def repo_target(checkout,name):
    rel=relative(name); path=checkout/rel
    if not path.resolve().is_relative_to(checkout.resolve()): raise ValueError('repository path escapes checkout')
    current=checkout
    for part in Path(rel).parts:
        current=current/part
        if current.is_symlink(): raise ValueError('repository path contains symlink')
    return path


def project_guidance(checkout,cfg):
    path=repo_target(checkout,cfg['guideline_path'])
    if path.is_symlink() or not path.is_file(): raise ValueError('canonical guideline missing')
    text=path.read_text(); cases=[]
    folder=repo_target(checkout,cfg['case_dir'])
    if folder.exists():
        for p in sorted(folder.glob('*.json')):
            if p.is_symlink(): raise ValueError('case symlink')
            cases.append(json.loads(p.read_text()))
    retired={x for c in cases if c['scope']=='common' and c['authority']=='user_explicit' for x in c.get('supersedes',[])}
    rules=[c for c in cases if c['id'] not in retired and c['scope']=='common' and c['authority']=='user_explicit' and c.get('guideline_action')=='add']
    lines=[BEGIN,'','## フィードバックから明示された共通方針','']
    for c in rules:
        rel=os.path.relpath(folder/(c['id']+'.json'),path.parent)
        clean=lambda s:' '.join(s.split()).replace('<!--','').replace('-->','')
        lines.append('- '+clean(c['summary'])+' 適用条件: '+clean(c['conditions'])+' ['+c['id']+']('+rel+')')
    lines+=['',END]
    block='\n'.join(lines)
    if BEGIN in text or END in text:
        if text.count(BEGIN)!=1 or text.count(END)!=1 or text.index(BEGIN)>text.index(END): raise ValueError('managed section malformed')
        text=text[:text.index(BEGIN)]+block+text[text.index(END)+len(END):]
    elif rules: text=text.rstrip()+'\n\n'+block+'\n'
    if text!=path.read_text(): path.write_text(text)


def publish(home,db,cfg):
    pending=[json.loads(r['payload']) for r in db.execute("SELECT payload FROM cases WHERE delivered IS NULL AND json_extract(payload,'$.safe_to_share')=1 ORDER BY created LIMIT 100")]
    if not pending and not cfg.get('guidance_checkout'): return dict(status='idle',published=0)
    if cfg.get('publish_mode')!='trunk-direct': raise ValueError('automatic publication requires configured trunk-direct owner')
    checkout=Path(cfg['guidance_checkout']).expanduser()
    if checkout.is_symlink(): raise ValueError('publisher checkout symlink')
    checkout=checkout.resolve()
    lock=home/'publish.lock'
    with open(lock,'a+') as f:
        os.chmod(lock,0o600)
        fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if git(checkout,'status','--porcelain'): raise ValueError('dedicated publisher checkout is dirty')
        git(checkout,'fetch','origin','main')
        # Only our dedicated queue commits may be rebased, never another working tree.
        ahead=git(checkout,'log','--format=%s','origin/main..HEAD').splitlines()
        if any(not s.startswith('design-feedback: ') for s in ahead): raise ValueError('foreign commits in publisher checkout')
        git(checkout,'rebase','origin/main')
        meta(db,'last_guidance_sync',dict(at=time.time(),revision=git(checkout,'rev-parse','origin/main')))
        if not pending: return dict(status='idle',published=0,guidance_synced=True)
        folder=repo_target(checkout,cfg['case_dir']); folder.mkdir(parents=True,exist_ok=True)
        for c in pending:
            p=folder/(c['id']+'.json')
            if p.is_symlink(): raise ValueError('case symlink')
            if p.exists() and json.loads(p.read_text())!=c: raise ValueError('published case collision')
            p.write_text(json.dumps(c,ensure_ascii=False,indent=2)+'\n')
        project_guidance(checkout,cfg)
        git(checkout,'add','--',relative(cfg['case_dir']),relative(cfg['guideline_path']))
        if git(checkout,'diff','--cached','--name-only'):
            git(checkout,'commit','-m','design-feedback: record scoped UI judgments')
        revision=git(checkout,'rev-parse','HEAD')
        git(checkout,'push','origin','HEAD:main')
        remote=git(checkout,'ls-remote','origin','refs/heads/main').split()[0]
        # The remote may advance immediately after our push; require ancestry, not equality.
        if remote!=revision:
            git(checkout,'fetch','origin','main'); git(checkout,'merge-base','--is-ancestor',revision,'origin/main')
        for c in pending: db.execute('UPDATE cases SET delivered=? WHERE id=?',(revision,c['id']))
        receipt=dict(status='published',published=len(pending),revision=revision,at=time.time())
        meta(db,'last_publish',receipt); meta(db,'publish_error',None)
        return receipt


def recover(db,cfg):
    """Read the existing normalized retrieval snapshot through its own lock/validator."""
    scripts=cfg.get('retrieval_scripts'); lab=cfg.get('retrieval_lab')
    if not scripts or not lab: return dict(status='not_configured')
    sys.path.insert(0,str(Path(scripts).expanduser()))
    from retrieval_lab import snapshot_lock, _snapshot
    from retrieval_opportunities import turns, user_text
    with snapshot_lock(Path(lab)):
        snapshot=_snapshot(Path(lab))
        if meta(db,'recovery_snapshot')==snapshot['snapshot_id']: return dict(status='unchanged',captures=0)
        items=turns(snapshot)
        count=0
        for item in items:
            observation=item.get('observation') or {}
            sid=observation.get('native_session_id')
            # Never invent a session/working directory or merge an unknown project.
            if not sid: continue
            session=db.execute('SELECT * FROM sessions WHERE id=?',(sid,)).fetchone()
            if session is None and cfg.get('recover_registered_only',True): continue
            when=observation.get('timestamp')
            if when is None or when<(meta(db,'capture_started_at') or cfg.get('started_at') or time.time())-600: continue
            u=item['utterance']; text=user_text(u['text'])
            # Existing prompt digests deduplicate hook and sweep captures despite different turn IDs.
            if db.execute('SELECT 1 FROM events WHERE session=? AND text=?',(sid,text)).fetchone(): continue
            if not DESIGN.search(text) or not REACTION.search(text): continue
            ref=dict(kind='recall',snapshot_id=snapshot['snapshot_id'],source_id=item['source_id'],citation_id=u['citation_id'],line=u['line'])
            if MACHINE.search(text): continue
            eid='evt-'+digest(['recall',sid,when,digest(text)])[:32]
            before=db.total_changes
            db.execute('INSERT OR IGNORE INTO events(id,session,turn,harness,project,created,text,source,artifacts) VALUES(?,?,?,?,?,?,?,?,?)',
                (eid,sid,'source-line-'+str(u['line']),session['harness'] if session else 'unknown',session['project'] if session else 'unassigned',when,text,json.dumps(ref),'[]'))
            count+=int(db.total_changes>before)
        meta(db,'recovery_snapshot',snapshot['snapshot_id'])
        report=snapshot.get('import_report',{})
        coverage={k:v for k,v in report.items() if k in ('deferred_sources','deferred_source_ids','missing_sources','mismatched_sources','bounded_windows','legacy_documents_skipped')}
        return dict(status='updated',captures=count,upstream_coverage=coverage,scope='registered_ui_sessions' if cfg.get('recover_registered_only',True) else 'unregistered_candidates_enabled')


def hook(home,db,cfg,payload,harness):
    event=payload.get('hook_event_name',''); sid=session_id(payload)
    if event=='UserPromptSubmit':
        eid=capture(db,payload,harness,str(payload.get('prompt','')))
        if not eid: return {}
        c=context(db,cfg,payload.get('prompt',''),payload.get('cwd',os.getcwd()),sid)
        message='[design-feedback] デザインの作業・反応を検出しました。design-feedback スキルを読み、指針と関連事例を参照してください。今回の捕捉ID: '+eid+'。本人の実際の評価なら画面版・理由・用途条件を record で保存し、制作依頼や仕組みの相談など評価でない発言は dismiss してください。AIの理由推測・単なるプレビュー選択を本人判断へ変換しない。\n'+json.dumps(c,ensure_ascii=False)
        return dict(hookSpecificOutput=dict(hookEventName=event,additionalContext=message[:10000]))
    if event=='Stop':
        last=payload.get('last_assistant_message') or ''
        for match in re.finditer(r'visualize(\{[^\n]+?\})',last):
            try:
                p=json.loads(match[1]); exhibit(home,db,cfg,p['path'],p.get('title') or Path(p['path']).stem,sid,payload.get('cwd',os.getcwd()))
            except (ValueError,OSError,KeyError): pass
        row=db.execute('SELECT e.* FROM events e JOIN sessions s ON e.id=s.last_event WHERE s.id=?',(sid,)).fetchone()
        if row and row['disposition']=='pending' and not row['reminded'] and not payload.get('stop_hook_active'):
            db.execute('UPDATE events SET reminded=1 WHERE id=?',(row['id'],))
            return dict(decision='block',reason='[design-feedback] 今回の捕捉 '+row['id']+' が未処理です。本人のデザイン評価なら出典と用途条件を record し、評価ではないなら理由付きで dismiss してください。推測で了承を作らず、記録のために本人へ聞き直さない。これは一度だけの記録確認です。')
    if event=='SessionStart':
        pending=db.execute("SELECT count(*) FROM events WHERE session=? AND disposition='pending'",(sid,)).fetchone()[0]
        if pending: return dict(hookSpecificOutput=dict(hookEventName=event,additionalContext='[design-feedback] この会話に未処理のデザイン候補が'+str(pending)+'件あります。関連するUI作業で design-feedback pending を確認してください。'))
    return {}


def main(argv=None):
    parser=argparse.ArgumentParser()
    parser.add_argument('--home',type=Path,default=default_home())
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('hook'); p.add_argument('--harness',choices=['codex','claude-code'],required=True)
    p=sub.add_parser('context'); p.add_argument('--query',default=''); p.add_argument('--cwd',default=os.getcwd()); p.add_argument('--session',default=session_env())
    p=sub.add_parser('exhibit'); p.add_argument('--file',required=True); p.add_argument('--label',required=True); p.add_argument('--session',default=session_env()); p.add_argument('--cwd',default=os.getcwd()); p.add_argument('--presented',action='store_true')
    p=sub.add_parser('record'); p.add_argument('--file',required=True)
    p=sub.add_parser('event'); p.add_argument('id')
    p=sub.add_parser('source'); p.add_argument('id')
    p=sub.add_parser('assign-project'); p.add_argument('id'); p.add_argument('--cwd',required=True); p.add_argument('--reason',required=True)
    p=sub.add_parser('dismiss'); p.add_argument('id'); p.add_argument('--reason',required=True)
    for name in ['pending','status','publish','sweep']: sub.add_parser(name)
    args=parser.parse_args(argv); home=args.home.expanduser()
    if home.is_symlink(): raise ValueError('state home symlink')
    home=home.resolve(); cfg=profile(home)
    with database(home) as db:
        try:
            if args.command=='hook': result=hook(home,db,cfg,json.load(sys.stdin),args.harness)
            elif args.command=='context': result=context(db,cfg,args.query,args.cwd,args.session)
            elif args.command=='exhibit':
                if not args.session: raise ValueError('session ID required')
                result=exhibit(home,db,cfg,args.file,args.label,args.session,args.cwd,args.presented)
            elif args.command=='record': result=record(db,json.loads(Path(args.file).read_text()))
            elif args.command=='dismiss':
                if not args.reason.strip(): raise ValueError('dismiss reason required')
                db.execute("UPDATE events SET disposition='dismissed',note=? WHERE id=? AND disposition='pending'",(args.reason[:500],args.id)); result=dict(disposition='dismissed')
            elif args.command in ('event','source'):
                row=db.execute('SELECT * FROM events WHERE id=?',(args.id,)).fetchone(); result=dict(row) if row else None
                if args.command=='source' and row:
                    ref=json.loads(row['source'])
                    if ref.get('kind')=='recall':
                        sys.path.insert(0,cfg['retrieval_scripts'])
                        from retrieval_lab import snapshot_lock, _snapshot
                        with snapshot_lock(Path(cfg['retrieval_lab'])):
                            snap=_snapshot(Path(cfg['retrieval_lab']),ref['snapshot_id'])
                            result['source_context']=next(d['text'] for d in snap['documents'] if d['citation_id']==ref['citation_id'])
            elif args.command=='assign-project':
                if not args.reason.strip(): raise ValueError('verified association reason required')
                db.execute("UPDATE events SET project=?,note=? WHERE id=? AND project='unassigned' AND disposition='pending'",(project_id(args.cwd),args.reason[:500],args.id))
                result=dict(project=project_id(args.cwd))
            elif args.command=='pending': result=[dict(r) for r in db.execute("SELECT id,session,created,project,source,artifacts FROM events WHERE disposition='pending' ORDER BY created DESC LIMIT 50")]
            elif args.command=='publish': result=publish(home,db,cfg)
            elif args.command=='sweep':
                result={}
                if cfg.get('refresh_before_recover') and cfg.get('retrieval_command'):
                    try:
                        r=subprocess.run([cfg['retrieval_command'],'refresh'],capture_output=True,text=True,timeout=60)
                        result['refresh']=dict(status='ok' if r.returncode==0 else 'failed',returncode=r.returncode)
                    except (OSError,subprocess.TimeoutExpired) as e: result['refresh']=dict(status='failed',error=type(e).__name__)
                try: result['recovery']=recover(db,cfg)
                except Exception as e: result['recovery']=dict(status='failed',error=str(e)[:300])
                result['delivery']=publish(home,db,cfg); meta(db,'last_sweep',dict(at=time.time(),result=result))
            elif args.command=='status': result=dict(events=dict(db.execute('SELECT disposition,count(*) FROM events GROUP BY disposition').fetchall()),cases=db.execute('SELECT count(*) FROM cases').fetchone()[0],undelivered=db.execute("SELECT count(*) FROM cases WHERE delivered IS NULL AND json_extract(payload,'$.safe_to_share')=1").fetchone()[0],last_publish=meta(db,'last_publish'),publish_error=meta(db,'publish_error'),last_sweep=meta(db,'last_sweep'))
        except Exception as e:
            meta(db,'publish_error',dict(at=time.time(),operation=args.command,error=str(e)[:300])); db.commit()
            if args.command=='hook': result={}
            else: raise
    print(json.dumps(result,ensure_ascii=False))


if __name__=='__main__':
    main()
