"""All integration fixtures use disposable Git repos and synthetic data only."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'scripts' / 'repo_sync.py'
spec = importlib.util.spec_from_file_location('repo_sync', MODULE)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class GitFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='knowledge-spine-sync-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'source'
        self.root.mkdir()
        self.bare = self.base / 'remote.git'
        self.run_git(self.base, 'init', '--bare', str(self.bare))
        self.run_git(self.root, 'init', '-b', 'main')
        self.run_git(self.root, 'config', 'user.name', 'Synthetic Test')
        self.run_git(self.root, 'config', 'user.email', 'test@example.invalid')
        self.run_git(self.root, 'config', 'core.hooksPath', str(self.base / 'no-hooks'))
        self.run_git(self.root, 'remote', 'add', 'origin', str(self.bare))
        self.repo = sync.Repository(self.root)
        private_path_patch = patch.object(self.repo, 'private_database_path', return_value=self.base / 'private-db.json')
        private_path_patch.start()
        self.addCleanup(private_path_patch.stop)
        self.repo.write_guard([])
        self.run_git(self.root, 'config', 'knowledgeSpine.autoSync', 'true')
        self.commit('README.txt', 'synthetic fixture\n')

    def run_git(self, cwd, *args, check=True):
        return subprocess.run(['git', *args], cwd=cwd, check=check, capture_output=True, text=True)

    def commit(self, name, content):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        self.run_git(self.root, 'add', '--', name)
        self.run_git(self.root, 'commit', '-m', 'Synthetic test commit')

    def test_clean_source_history_passes(self):
        self.assertEqual(self.repo.audit(), 1)

    def test_staged_private_database_is_rejected(self):
        p = self.root / 'database.json'
        p.write_text('{"synthetic": true}')
        self.run_git(self.root, 'add', 'database.json')
        with self.assertRaisesRegex(sync.SyncError, 'local configuration'):
            self.repo.audit(index=True)

    def test_secret_removed_from_latest_commit_is_still_rejected_in_history(self):
        key = 'gh' + 'p_' + 'Z' * 36
        self.commit('old.txt', key)
        self.run_git(self.root, 'rm', 'old.txt')
        self.run_git(self.root, 'commit', '-m', 'Remove synthetic secret')
        with self.assertRaisesRegex(sync.SyncError, 'GitHub token') as caught:
            self.repo.audit()
        self.assertNotIn(key, str(caught.exception))

    def test_renamed_private_path_is_checked_even_for_reused_blob(self):
        self.commit('database.json', 'synthetic fixture\n')
        self.run_git(self.root, 'rm', 'database.json')
        self.run_git(self.root, 'commit', '-m', 'Remove private fixture')
        with self.assertRaisesRegex(sync.SyncError, 'database.json'):
            self.repo.audit()

    def test_success_push_is_verified_against_real_remote_ref(self):
        with patch.object(self.repo, 'assert_destination'):
            self.repo.sync()
        local = self.repo.text('rev-parse', 'HEAD')
        self.assertEqual(self.repo.remote_head('main'), local)
        self.assertEqual(json.loads(self.repo.state_path().read_text())['status'], 'synced')
        clone = self.base / 'clone'
        self.run_git(self.base, 'clone', str(self.bare), str(clone))
        self.assertEqual((clone / 'README.txt').read_text(), 'synthetic fixture\n')

    def test_rejected_push_preserves_commit_and_records_pending(self):
        with patch.object(self.repo, 'assert_destination'):
            self.repo.sync()
        other = self.base / 'other'
        self.run_git(self.base, 'clone', str(self.bare), str(other))
        self.run_git(other, 'config', 'user.name', 'Other Synthetic Test')
        self.run_git(other, 'config', 'user.email', 'other@example.invalid')
        (other / 'other.txt').write_text('synthetic other change')
        self.run_git(other, 'add', 'other.txt')
        self.run_git(other, 'commit', '-m', 'Other side')
        self.run_git(other, 'push', 'origin', 'main')
        remote_before = self.repo.remote_head('main')
        self.commit('local.txt', 'preserve me')
        head_before = self.repo.text('rev-parse', 'HEAD')
        with patch.object(self.repo, 'assert_destination'), self.assertRaises(sync.SyncError):
            self.repo.sync()
        self.assertEqual(self.repo.text('rev-parse', 'HEAD'), head_before)
        self.assertEqual(self.repo.remote_head('main'), remote_before)
        self.assertEqual((self.root / 'local.txt').read_text(), 'preserve me')
        self.assertEqual(json.loads(self.repo.state_path().read_text())['status'], 'pending')

    def test_changed_destination_is_rejected_before_upload(self):
        with self.assertRaisesRegex(sync.SyncError, 'approved repository'):
            self.repo.assert_destination()

    def test_public_repository_requires_matching_approved_visibility(self):
        self.run_git(self.root, 'config', 'knowledgeSpine.approvedVisibility', 'PRIVATE')
        self.run_git(self.root, 'remote', 'set-url', 'origin', sync.EXPECTED_URL)
        original = self.repo.call
        def call(args, **kwargs):
            if args[0] == 'gh':
                return subprocess.CompletedProcess(args, 0, json.dumps({
                    'nameWithOwner': sync.EXPECTED_REPO, 'visibility': 'PUBLIC', 'isArchived': False
                }).encode(), b'')
            return original(args, **kwargs)
        with patch.object(self.repo, 'call', side_effect=call), self.assertRaisesRegex(sync.SyncError, 'PRIVATE'):
            self.repo.assert_destination()

    def test_uncommitted_work_cannot_be_reported_as_complete(self):
        with patch.object(self.repo, 'assert_destination'):
            self.repo.sync()
            (self.root / 'uncommitted.txt').write_text('synthetic')
            with self.assertRaisesRegex(sync.SyncError, 'incomplete'):
                self.repo.status(require_synced=True)

    def test_finish_never_sweeps_preexisting_staged_changes(self):
        (self.root / 'unrelated.txt').write_text('synthetic unrelated work')
        self.run_git(self.root, 'add', 'unrelated.txt')
        with patch.object(self.repo, 'assert_destination'), patch.object(self.repo, 'install'), self.assertRaisesRegex(sync.SyncError, 'Index already'):
            self.repo.finish('Do not sweep', ['README.txt'])
        self.assertEqual(self.repo.text('diff', '--cached', '--name-only'), 'unrelated.txt')

    def test_finish_checks_then_commits_only_selected_files_and_verifies(self):
        (self.root / 'selected.txt').write_text('synthetic selected change')
        with patch.object(self.repo, 'assert_destination'), patch.object(self.repo, 'install'), patch.object(self.repo, 'checks') as checks:
            self.repo.finish('Deliver selected change', ['selected.txt'])
        checks.assert_called_once()
        self.assertEqual(self.repo.text('log', '-1', '--format=%s'), 'Deliver selected change')
        self.assertEqual(self.repo.remote_head('main'), self.repo.text('rev-parse', 'HEAD'))

    def test_failed_checks_prevent_staging_commit_and_push(self):
        (self.root / 'selected.txt').write_text('synthetic selected change')
        before = self.repo.text('rev-parse', 'HEAD')
        with patch.object(self.repo, 'assert_destination'), patch.object(self.repo, 'install'), patch.object(self.repo, 'checks', side_effect=sync.SyncError('synthetic check failure')):
            with self.assertRaisesRegex(sync.SyncError, 'synthetic check failure'):
                self.repo.finish('Never publish', ['selected.txt'])
        self.assertEqual(self.repo.text('rev-parse', 'HEAD'), before)
        self.assertEqual(self.repo.text('diff', '--cached', '--name-only'), '')
        self.assertIsNone(self.repo.remote_head('main'))

    def test_private_usage_note_in_readme_is_blocked_without_echoing_text(self):
        title = 'Synthetic Private ' + 'Lecture Title'
        self.repo.write_guard([{'title': title}])
        (self.root / 'README.txt').write_text('Today I used ' + title)
        self.run_git(self.root, 'add', 'README.txt')
        with self.assertRaisesRegex(sync.SyncError, 'private-use content') as caught: self.repo.audit(index=True)
        self.assertNotIn(title, str(caught.exception))
        self.assertNotIn(title, self.repo.guard_path().read_text())

    def test_private_fragment_and_json_escapes_are_blocked(self):
        text = 'Private synthetic passage that must remain on this machine alone'
        self.repo.write_guard([{'transcript': [{'originalText': text}]}])
        (self.root / 'fixture.json').write_text(json.dumps({'sample': text}, ensure_ascii=True))
        self.run_git(self.root, 'add', 'fixture.json')
        with self.assertRaisesRegex(sync.SyncError, 'private-use content'): self.repo.audit(index=True)

    def test_development_record_is_blocked_even_without_secret(self):
        p = self.root / 'Recovery' / 'note.md';p.parent.mkdir();p.write_text('Synthetic note')
        self.run_git(self.root, 'add', 'Recovery/note.md')
        with self.assertRaisesRegex(sync.SyncError, 'local data/build directory'): self.repo.audit(index=True)

    def test_guard_does_not_store_private_text(self):
        text = 'Synthetic personal text which must not be stored in this guard'
        self.repo.write_guard([{'title': 'Synthetic title', 'transcript': [{'originalText': text}]}])
        stored = self.repo.guard_path().read_text()
        self.assertNotIn(text, stored);self.assertNotIn('Synthetic title', stored)
        self.assertIn('fingerprints', stored)

    def test_actual_outgoing_hidden_checkpoint_is_also_audited(self):
        p = self.root / 'Recovery' / 'private.md'; p.parent.mkdir()
        p.write_text('Synthetic private checkpoint')
        self.run_git(self.root, 'add', 'Recovery/private.md')
        tree = self.repo.text('write-tree')
        oid = self.repo.call(['git', 'commit-tree', tree, '-p', 'HEAD'], input=b'Synthetic checkpoint\n').stdout.decode().strip()
        self.run_git(self.root, 'update-ref', 'refs/codex/test-checkpoint', oid)
        self.run_git(self.root, 'reset', '--mixed', 'HEAD')
        self.repo.audit()
        with self.assertRaisesRegex(sync.SyncError, 'Recovery/private.md'):
            self.repo.audit(extra_refs=[oid])

    def test_new_private_session_is_blocked_without_reinstalling(self):
        title = 'SyntheticNewPrivateLecture'
        self.repo.private_database_path().write_text(json.dumps({'sessions': [{'title': title}]}))
        self.commit('README.txt', 'Used ' + title)
        with self.assertRaisesRegex(sync.SyncError, 'private-use content'):
            self.repo.audit()
        self.repo.private_database_path().write_text(json.dumps({'sessions': []}))
        with self.assertRaisesRegex(sync.SyncError, 'private-use content'):
            self.repo.audit()
        self.assertNotIn(title, self.repo.guard_path().read_text())

    def test_private_commit_message_is_blocked_before_push(self):
        title = 'SyntheticHiddenLectureName'
        self.repo.write_guard([{'title': title}])
        self.run_git(self.root, 'commit', '--allow-empty', '-m', 'Review ' + title)
        with self.assertRaisesRegex(sync.SyncError, 'commit/tag/ref metadata') as caught:
            self.repo.audit()
        self.assertNotIn(title, str(caught.exception))

    def test_private_annotated_tag_is_blocked_before_push(self):
        title = 'SyntheticHiddenLectureName'
        self.repo.write_guard([{'title': title}])
        self.run_git(self.root, 'tag', '-a', 'synthetic-v1', '-m', title)
        with self.assertRaisesRegex(sync.SyncError, 'commit/tag/ref metadata'):
            self.repo.audit()

    def test_install_does_not_replace_foreign_hooks(self):
        with self.assertRaisesRegex(sync.SyncError, 'Existing hooksPath'):
            self.repo.install()

    def test_do_not_stage_directories_or_outside_paths(self):
        with patch.object(self.repo, 'assert_destination'), patch.object(self.repo, 'install'):
            for name in ('../outside.txt', '.', 'Recordings/sample.txt'):
                with self.subTest(name=name), self.assertRaises(sync.SyncError):
                    self.repo.finish('No implicit staging', [name])


    def test_public_policy_accepts_only_the_approved_public_repository(self):
        self.run_git(self.root, 'remote', 'set-url', 'origin', sync.EXPECTED_URL)
        self.run_git(self.root, 'config', 'knowledgeSpine.approvedVisibility', 'PUBLIC')
        original = self.repo.call
        meta = {'nameWithOwner': sync.EXPECTED_REPO, 'visibility': 'PUBLIC', 'isArchived': False}
        def call(args, **kwargs):
            if args[0] == 'gh':
                return subprocess.CompletedProcess(args, 0, json.dumps(meta).encode(), b'')
            return original(args, **kwargs)
        with patch.object(self.repo, 'call', side_effect=call):
            self.repo.assert_destination()
            for key, value in [('nameWithOwner', 'synthetic/other'), ('visibility', 'PRIVATE'), ('isArchived', True)]:
                changed = dict(meta); meta[key] = value
                with self.assertRaises(sync.SyncError): self.repo.assert_destination()
                meta.clear(); meta.update(changed)
        self.run_git(self.root, 'remote', 'set-url', '--push', 'origin', 'https://example.invalid/wrong.git')
        with self.assertRaisesRegex(sync.SyncError, 'approved repository'): self.repo.assert_destination()

    def test_public_is_default_for_new_clones_and_invalid_policy_is_rejected(self):
        self.assertEqual(self.repo.approved_visibility(), 'PUBLIC')
        self.run_git(self.root, 'config', 'knowledgeSpine.approvedVisibility', 'unknown')
        with self.assertRaisesRegex(sync.SyncError, 'PRIVATE or PUBLIC'): self.repo.approved_visibility()

    def test_public_sync_still_rejects_image_notes_and_recognized_text(self):
        for field in ('note', 'extractedText'):
            private = 'Synthetic confidential visual passage for local privacy testing only'
            self.repo.write_guard([{'images': [{field: private}]}])
            (self.root / 'README.txt').write_text(private)
            self.run_git(self.root, 'add', 'README.txt')
            with self.assertRaisesRegex(sync.SyncError, 'private-use content') as caught:
                self.repo.audit(index=True)
            self.assertNotIn(private, str(caught.exception))

    def test_personal_exports_and_raw_images_are_not_source(self):
        for name in ('saved.kspine', 'course.pdf', 'backup.zip', 'screenshot.PNG', 'voice.aiff'):
            with self.subTest(name=name): self.assertIsNotNone(sync.path_problem(name))


    def test_local_private_archive_is_not_published_but_outgoing_archive_is_blocked(self):
        p = self.root / 'Recovery' / 'archive.txt'; p.parent.mkdir()
        p.write_text('Synthetic private archive')
        self.run_git(self.root, 'add', 'Recovery/archive.txt')
        tree = self.repo.text('write-tree')
        oid = self.repo.call(['git', 'commit-tree', tree, '-p', 'HEAD'], input=b'Synthetic private archive\n').stdout.decode().strip()
        self.run_git(self.root, 'update-ref', 'refs/heads/private-history', oid)
        self.run_git(self.root, 'reset', '--mixed', 'HEAD')
        self.repo.audit()
        with self.assertRaisesRegex(sync.SyncError, 'Recovery/archive.txt'):
            self.repo.audit(extra_refs=[oid])

    def test_personal_home_paths_cannot_be_published(self):
        personal = str(Path.home()) + '/synthetic-private-file'
        self.assertIn('private developer home path', sync.content_problems('README.md', personal.encode()))


    def test_actual_outgoing_ref_name_cannot_contain_private_title(self):
        title = 'SyntheticPrivateOutgoingRefTitle'
        self.repo.write_guard([{'title': title}])
        with self.assertRaisesRegex(sync.SyncError, 'commit/tag/ref metadata') as caught:
            self.repo.audit(extra_metadata=['refs/heads/' + title])
        self.assertNotIn(title, str(caught.exception))


    def test_private_legacy_tags_are_retained_but_not_implicitly_published(self):
        p = self.root / 'Recovery' / 'tag-archive.txt'; p.parent.mkdir()
        p.write_text('Synthetic private tag archive')
        self.run_git(self.root, 'add', 'Recovery/tag-archive.txt')
        tree = self.repo.text('write-tree')
        oid = self.repo.call(['git', 'commit-tree', tree, '-p', 'HEAD'], input=b'Synthetic archive tag\n').stdout.decode().strip()
        self.run_git(self.root, 'tag', '-a', 'private-archive-tag', oid, '-m', 'Synthetic private tag')
        self.run_git(self.root, 'reset', '--mixed', 'HEAD')
        self.repo.audit()
        with self.assertRaisesRegex(sync.SyncError, 'Recovery/tag-archive.txt'):
            self.repo.audit(extra_refs=['refs/tags/private-archive-tag'])
        self.assertIn('private-archive-tag', self.repo.text('tag', '--list'))


if __name__ == '__main__':
    unittest.main()
