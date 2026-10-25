import json
from pathlib import Path
import sys
import tempfile
import subprocess
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import retrieval_lab as lab
import retrieval_live as live
import retrieval_supplement as supplement
import retrieval_context as context
import retrieval_followup as followup
import retrieval_reuse as reuse
from test_retrieval_opportunities import msg

class SupplementTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name).resolve();self.logs=self.base/'logs';self.logs.mkdir();self.root=self.base/'lab'
        for n,text in enumerate(['anchor','anchor scope','anchor scope scope','anchor scope scope scope']):
            self.write(str(n),str(n),[msg(text,100)])
        self.write('current','caller',[msg('Investigate anchor',200),msg('Checking',201,'assistant'),msg('I already said anchor',220)])
        lab.create_lab(self.root,live.export_live([('codex',self.logs)],since=0))
        with patch('time.time',return_value=205):
            self.parent=lab.search_corrections(self.root,'anchor','resume',task='scope',need='scope',session_id='caller')
        self.pid=self.parent['request_id']
    def write(self,name,sid,records):
        (self.logs/(name+'.jsonl')).write_text(''.join(json.dumps(x)+'\n' for x in [dict(type='session_meta',payload=dict(id=sid)),*records]))
    def miss(self):
        with patch('time.time',return_value=206):lab.context_use(self.root,self.pid,'not_applicable',[],'Not found',decision_match='not_found')
    def open(self,when=207):
        with patch('time.time',return_value=when):return supplement.open_supplement(self.root,self.pid)
    def test_gate_and_idempotence_and_primary_unchanged(self):
        with self.assertRaises(ValueError):self.open()
        before=lab.context_report(self.root)['supplements']
        self.assertEqual(before['candidate_exposures'],0)
        self.assertEqual(before['all_attempt_candidate_exposures'],3)
        self.miss();c=self.open();self.assertEqual(len(c['hits']),1)
        self.assertEqual(c['hits'][0]['utterance']['text'],'anchor')
        self.assertGreater(c['supplement']['scope_rank'],3)
        self.assertIn(c['supplement']['query_rank'],(1,2,3))
        self.assertEqual(c['supplement']['primary_source_read_count'],0)
        self.assertEqual(self.open()['request_id'],c['request_id'])
        self.assertEqual(lab.context_inspect(self.root,self.pid)['result'],self.parent)
        report=lab.context_report(self.root)
        self.assertEqual(report['searches'],2)
        self.assertEqual(report['supplements']['candidate_exposures'],1)
        self.assertEqual(report['supplements']['all_attempt_candidate_exposures'],4)
        self.assertLessEqual(c['supplement']['preview_characters'],480)
        with self.assertRaises(ValueError):supplement.open_supplement(self.root,c['request_id'])
    def test_snapshot_is_parent_and_reject_version_drift(self):
        self.miss();old=self.parent['snapshot_id']
        self.write('new','new',[msg('new anchor scope',150)])
        lab.publish_snapshot(self.root,live.export_live([('codex',self.logs)],since=0))
        self.assertNotEqual(lab._snapshot(self.root)['snapshot_id'],old)
        with patch.object(context,'VERSION','future'):
            with self.assertRaises(ValueError):self.open()
        self.assertEqual(self.open()['snapshot_id'],old)
    def test_found_partial_unknown_do_not_unlock(self):
        for match in ['unknown','found','partial']:
            citation=self.parent['hits'][0]['citation_id'];lab.read_citation(self.root,citation,self.pid)
            lab.context_use(self.root,self.pid,'not_applicable',[citation],'Other reason',decision_match=match)
            with self.assertRaises(ValueError):self.open()
    def test_read_use_and_human_followup_link_and_late_report(self):
        self.miss();c=self.open();cid=c['hits'][0]['citation_id'];rid=c['request_id']
        with self.assertRaises(ValueError):lab.context_use(self.root,rid,'applied',[cid],'Use answer',decision_match='found')
        with patch('time.time',return_value=208):
            read=lab.read_citation(self.root,cid,rid)
            lab.context_use(self.root,rid,'applied',[cid],'Use answer',decision_match='found')
        with patch('time.time',return_value=215):followup.run(self.root,lab._snapshot(self.root),dict(since=0))
        pending=followup.report(self.root)['review_cases'][0]['supplements']
        self.assertFalse(pending['actual_followup_observed'])
        self.assertIsNone(pending['records'][0]['reported_before_followup'])
        with patch('time.time',return_value=230):followup.run(self.root,lab._snapshot(self.root),dict(since=0))
        packet=followup.report(self.root)['review_cases'][0];record=packet['supplements']['records'][0]
        self.assertEqual(packet['followups'][0]['timestamp'],220)
        self.assertEqual(packet['need']['request_ids'],[self.pid,rid]);self.assertTrue(record['reported_before_followup'])
        self.assertEqual(record['source_returned_bytes'],len(read['text'].encode()))
        self.assertEqual(lab.context_report(self.root)['decision_needs']['found_on'],{'supplement':1})
        case_id=next(iter(self._case_ids()))
        fixture=reuse.freeze(self.root,rid,case_id);self.assertTrue(reuse.replay(self.root,fixture)['all_targets_found'])
        with patch('time.time',return_value=225):lab.context_use(self.root,rid,'applied',[cid],'Late update',decision_match='found')
        with patch('time.time',return_value=240):followup.run(self.root,lab._snapshot(self.root),dict(since=0))
        self.assertFalse(followup.report(self.root)['review_cases'][0]['supplements']['records'][0]['reported_before_followup'])
    def _case_ids(self):
        with lab._connect(self.root) as db:return [x[0] for x in db.execute('SELECT case_id FROM recall_followup_heads')]
    def test_retry_remains_separate_and_no_supplement_after_retry(self):
        self.miss();c=self.open()
        with self.assertRaises(ValueError):lab.search_corrections(self.root,'anchor','resume',retry_of=c['request_id'],session_id='caller')
        lab.search_corrections(self.root,'other','resume',retry_of=self.pid,session_id='caller')
        self.assertEqual(self.open()['request_id'],c['request_id'])
    def test_empty_is_frozen_and_retry_blocks_new_supplement(self):
        parent=lab.search_corrections(self.root,'anchor','resume',need='anchor',session_id='caller')
        pid=parent['request_id'];lab.context_use(self.root,pid,'not_applicable',[],'No applicable decision',decision_match='not_found')
        child=supplement.open_supplement(self.root,pid)
        self.assertEqual(child['hits'],[]);self.assertEqual(child['supplement']['preview_characters'],0)
        self.assertEqual(supplement.open_supplement(self.root,pid)['request_id'],child['request_id'])
        self.miss();lab.search_corrections(self.root,'other','resume',retry_of=self.pid,session_id='caller')
        with self.assertRaises(ValueError):self.open()

    def test_installed_entry_cli_records_one_child(self):
        self.miss()
        command=[sys.executable,str(Path(lab.__file__).with_name('retrieval_refresh.py')),
                 '--lab',str(self.root),'context-supplement',self.pid]
        first=json.loads(subprocess.check_output(command,text=True))
        second=json.loads(subprocess.check_output(command,text=True))
        self.assertEqual(first['request_id'],second['request_id'])
        self.assertTrue(second['replayed'])
        self.assertEqual(lab.context_report(self.root)['supplements']['requests'],1)

    def test_excerpt_offsets_and_no_overlap(self):
        message=dict(text='x'*400+'needle'+'z'*400,citation_id='ref',line=1)
        e=supplement.excerpt(message,{'needle':1});self.assertIn('needle',e['text']);self.assertEqual(e['text'],message['text'][e['excerpt_start']:e['excerpt_end']]);self.assertLessEqual(len(e['text']),240)
        snapshot=lab._snapshot(self.root);primary=context.retrieve(snapshot,'anchor',3)['hits']
        self.assertEqual(supplement.select(snapshot,'anchor',primary),[])
if __name__=='__main__':unittest.main()
