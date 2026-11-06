#!/usr/bin/env python3
"""Project-local delivery: audit -> checks -> explicit commit -> push -> verify.

Uses only Python's standard library, Git, gh and the existing Swift toolchain.
Never stages files implicitly, force-pushes, runs the App, or reads Keychain.
"""
import argparse
import datetime
import io
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import zipfile

EXPECTED_REPO = 'mandycency-prog/knowledge-spine-releases'
EXPECTED_URL = 'https://github.com/' + EXPECTED_REPO + '.git'
DEFAULT_VISIBILITY = 'PUBLIC'
MAX_BLOB = 50 * 1024 * 1024
PATTERNS = {
    'GitHub token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{35,})\b'),
    'API key': re.compile(rb'\bsk-(?:proj-|ant-api\d+-)?[A-Za-z0-9_-]{24,}'),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'AWS access key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
}
DENIED_DIRS = {'.build', 'dist', 'node_modules', '.venv', 'venv', '__pycache__',
               '.codex', '.agents', 'Recovery', '旧资料归档', 'Sessions', 'Recordings', 'Processing'}
DENIED_SUFFIXES = {'.wav', '.m4a', '.mp3', '.mp4', '.aac', '.flac', '.pt', '.gguf',
                   '.sqlite', '.sqlite3', '.db', '.log', '.p12', '.pfx', '.pem', '.key', '.docx', '.pdf', '.kspine', '.dmg', '.bundle',
                   '.zip', '.tar', '.gz', '.xz', '.aiff', '.aif', '.caf',
                   '.png', '.jpg', '.jpeg', '.webp', '.heic', '.tif', '.tiff', '.gif', '.bmp'}
DENIED_NAMES = {'database.json', 'config.json', 'credentials.json', '.openai_key',
                'id_rsa', 'id_ed25519', 'cookies', 'login data', 'build_product_requirements.py'}


class SyncError(RuntimeError):
    pass


def path_problem(name):
    p = PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts:
        return 'path escapes repository'
    if any(x in DENIED_DIRS or x.endswith('.app') for x in p.parts):
        return 'local data/build directory'
    if p.name.lower() in DENIED_NAMES or p.name == '.env' or p.name.startswith('.env.'):
        return 'local configuration or credentials'
    if p.suffix.lower() in DENIED_SUFFIXES:
        return 'recording, model, database or credential file'
    if name.startswith('Recovery/') and p.suffix.lower() == '.json':
        return 'private recovery snapshot'
    return None


def content_problems(name, data):
    problems = []
    if str(Path.home()).encode() + b'/' in data:
        problems.append('private developer home path')
    for label, pattern in PATTERNS.items():
        if pattern.search(data):
            problems.append(label)  # Never print the matched credential.
    if name.endswith('.docx'):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                for info in archive.infolist():
                    if info.filename.endswith('.xml'):
                        if info.file_size > MAX_BLOB:
                            problems.append('oversized document member')
                            continue
                        inner = archive.read(info)
                        for label, pattern in PATTERNS.items():
                            if pattern.search(inner):
                                problems.append(label + ' in document')
        except (zipfile.BadZipFile, RuntimeError):
            problems.append('unreadable document')
    return sorted(set(problems))


PRIVATE_TEXT_FIELDS = {'originalText', 'correctedText', 'userEditedText', 'text',
                       'aiSummary', 'summary', 'explanation', 'focusedStudyQuestion',
                       'note', 'extractedText', 'analysisError'}


def normalized(value):
    return re.sub(r'[\W_]+', '', value).casefold()


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def make_private_guard(sessions):
    fingerprints = {}
    def add(value):
        value = normalized(value)
        if len(value) >= 2:
            fingerprints.setdefault(str(len(value)), set()).add(digest(value))
    def walk(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if isinstance(item, str) and re.fullmatch(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', item): add(item)
                if key in {'title', 'sourceName', 'filename', 'fileName'} and isinstance(item, str) and len(normalized(item)) >= 12:
                    add(item)
                if key in PRIVATE_TEXT_FIELDS and isinstance(item, str):
                    text = normalized(item)
                    for i in range(0, max(0, len(text) - 19), 5): add(text[i:i + 20])
                elif isinstance(item, (dict, list)): walk(item)
        elif isinstance(value, list):
            for item in value: walk(item)
    for session in sessions:
        add(session.get('title', ''))
        for part in re.split(r'[|｜:：/\s—-]+', session.get('title', '')):
            if len(part) >= 2: add(part)
        walk(session)
    return {'version': 1, 'fingerprints': {k: sorted(v) for k, v in fingerprints.items()}}


def private_content_problems(name, data, guard):
    text = data.decode('utf-8', errors='replace')
    if name.endswith('.json'):
        try:
            def values(item):
                if isinstance(item, str): return [item]
                if isinstance(item, dict): return [v for x in item.values() for v in values(x)]
                if isinstance(item, list): return [v for x in item for v in values(x)]
                return []
            text += '\n' + '\n'.join(values(json.loads(text)))
        except ValueError: pass
    text = normalized(text)
    for length, hashes in guard['fingerprints'].items():
        width, blocked = int(length), set(hashes)
        if any(digest(text[i:i + width]) in blocked for i in range(max(0, len(text) - width + 1))):
            return ['private-use content fingerprint (value redacted)']
    return []


class Repository:
    def __init__(self, root):
        self.root = Path(root).resolve()

    def call(self, args, check=True, timeout=180, input=None):
        try:
            result = subprocess.run(args, cwd=self.root, input=input,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise SyncError(str(exc)) from exc
        if check and result.returncode:
            diagnostic = result.stderr[-2400:]
            for pattern in PATTERNS.values():
                diagnostic = pattern.sub(b'[redacted]', diagnostic)
            raise SyncError('%s failed (exit %s); local work is preserved\n%s' %
                            (' '.join(args[:2]), result.returncode, diagnostic.decode(errors='replace')))
        return result

    def git(self, *args, **kwargs):
        return self.call(['git', '--no-optional-locks', *args], **kwargs).stdout

    def text(self, *args):
        return self.git(*args).decode().strip()

    def state_path(self):
        p = Path(self.text('rev-parse', '--git-path', 'knowledge-spine-sync.json'))
        return p if p.is_absolute() else self.root / p

    def save_state(self, status, **extra):
        p = self.state_path()
        state = {'status': status, 'time': datetime.datetime.now(datetime.timezone.utc).isoformat(), **extra}
        temp = p.with_suffix('.tmp')
        temp.write_text(json.dumps(state, ensure_ascii=False, indent=2))
        temp.replace(p)

    def guard_path(self):
        return self.state_path().parent / 'knowledge-spine-private-guard.json'

    def write_guard(self, sessions):
        p = self.guard_path()
        p.write_text(json.dumps(make_private_guard(sessions), ensure_ascii=False))
        p.chmod(0o600)

    def private_database_path(self):
        return Path.home() / 'Library/Application Support/直播与课程知识骨架/database.json'

    def refresh_guard(self):
        database = self.private_database_path()
        if not database.is_file():
            return
        sessions = json.loads(database.read_text()).get('sessions', [])
        guard = make_private_guard(sessions)
        if self.guard_path().is_file():
            previous = json.loads(self.guard_path().read_text())
            for width, hashes in previous['fingerprints'].items():
                guard['fingerprints'][width] = sorted(set(guard['fingerprints'].get(width, [])) | set(hashes))
        target = self.guard_path()
        temporary = target.with_suffix('.tmp')
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            json.dump(guard, output)
        temporary.chmod(0o600)
        temporary.replace(target)

    def audit(self, index=False, extra_refs=(), extra_metadata=()):
        self.refresh_guard()
        if not self.guard_path().exists():
            raise SyncError('Local privacy guard missing; run install before auditing')
        guard = json.loads(self.guard_path().read_text())
        if index:
            entries = []
            for item in self.git('ls-files', '--stage', '-z').split(b'\0'):
                if not item:
                    continue
                meta, name = item.split(b'\t', 1)
                mode, oid, stage = meta.split()
                if stage != b'0':
                    raise SyncError('Unresolved index conflict')
                entries.append((mode.decode(), oid.decode(), name.decode()))
        else:
            entries = []
            if self.approved_visibility() == 'PUBLIC':
                # Local private archive branches are not publication inputs.
                # The pre-push hook adds every actual outgoing object below.
                current = self.call(['git', 'symbolic-ref', '--quiet', 'HEAD'], check=False).stdout.decode().strip()
                refs = [current or 'HEAD']
                for tag in self.text('for-each-ref', '--format=%(refname)', 'refs/tags').splitlines():
                    target = self.call(['git', 'rev-parse', tag + '^{commit}'], check=False)
                    if target.returncode == 0 and self.call(
                            ['git', 'merge-base', '--is-ancestor', target.stdout.decode().strip(), 'HEAD'],
                            check=False).returncode == 0:
                        refs.append(tag)
            else:
                refs = self.text('for-each-ref', '--format=%(refname)', 'refs/heads', 'refs/tags').splitlines()
            refs.extend(extra_refs)
            if not refs:
                raise SyncError('No committed version to audit')
            seen = set()
            metadata = [value.encode() for value in extra_metadata]
            for ref in refs:
                metadata.append(ref.encode())
                if self.text('cat-file', '-t', ref) == 'tag':
                    metadata.append(self.git('cat-file', 'tag', ref))
            # Check paths in every historical tree, including renamed/reused blobs.
            for commit in self.text('rev-list', *refs).splitlines():
                metadata.append(self.git('cat-file', 'commit', commit))
                for item in self.git('ls-tree', '-rz', commit).split(b'\0'):
                    if not item:
                        continue
                    meta, name = item.split(b'\t', 1)
                    mode, kind, oid = meta.split()
                    entry = (mode.decode(), oid.decode(), name.decode())
                    if entry not in seen:
                        seen.add(entry)
                        entries.append(entry)
        errors, checked = [], set()
        if not index:
            for item in metadata:
                for problem in content_problems('metadata', item) + private_content_problems('metadata', item, guard):
                    errors.append('commit/tag/ref metadata: ' + problem)
        for mode, oid, name in entries:
            issue = path_problem(name)
            if issue:
                errors.append('%s: %s' % (name, issue))
            if mode != '100644' and mode != '100755':
                errors.append('%s: symlink/submodule or unsupported entry' % name)
                continue
            if oid in checked:
                continue
            checked.add(oid)
            size = int(self.text('cat-file', '-s', oid))
            if size > MAX_BLOB:
                errors.append('%s: exceeds 50 MiB source limit' % name)
                continue
            data = self.git('cat-file', 'blob', oid)
            for problem in content_problems(name, data) + private_content_problems(name, data, guard):
                errors.append('%s: %s' % (name, problem))
        if errors:
            raise SyncError('Audit blocked (paths only, credentials redacted):\n' + '\n'.join(sorted(set(errors))))
        print('Audit passed: %d unique blobs, %d historical path entries' % (len(checked), len(entries)))
        return len(checked)

    def approved_visibility(self):
        result = self.call(['git', 'config', '--local', '--get',
                            'knowledgeSpine.approvedVisibility'], check=False)
        value = result.stdout.decode().strip().upper() or DEFAULT_VISIBILITY
        if value not in {'PRIVATE', 'PUBLIC'}:
            raise SyncError('Approved visibility must be PRIVATE or PUBLIC')
        return value

    def assert_destination(self):
        # Validate effective fetch/push URLs: URL rewrites must not redirect uploads.
        for flag in ([], ['--push']):
            url = self.text('remote', 'get-url', *flag, '--all', 'origin')
            if url != EXPECTED_URL:
                raise SyncError('origin differs from the approved repository')
        approved = self.approved_visibility()
        meta = json.loads(self.call(['gh', 'repo', 'view', EXPECTED_REPO, '--json',
                                     'nameWithOwner,visibility,isArchived']).stdout)
        if meta['nameWithOwner'].lower() != EXPECTED_REPO.lower() or meta['visibility'] != approved or meta['isArchived']:
            raise SyncError('Destination must be the approved, active %s repository' % approved)

    def branch(self):
        branch = self.text('symbolic-ref', '--quiet', '--short', 'HEAD')
        if not branch:
            raise SyncError('Detached HEAD; choose a branch before publishing')
        return branch

    def remote_head(self, branch):
        output = self.text('ls-remote', '--heads', 'origin', 'refs/heads/' + branch)
        return output.split()[0] if output else None

    def sync(self):
        branch = self.branch()
        head = self.text('rev-parse', 'HEAD')
        self.save_state('pending', branch=branch, commit=head)
        try:
            self.assert_destination()
            self.audit()
            self.call(['git', 'push', '--set-upstream', 'origin', 'HEAD:refs/heads/' + branch], timeout=180)
            if self.remote_head(branch) != head:
                raise SyncError('Remote verification mismatch')
            self.save_state('synced', branch=branch, commit=head, repository=EXPECTED_REPO)
            print('SYNCED %s %s %s' % (EXPECTED_REPO, branch, head))
        except Exception as exc:
            self.save_state('pending', branch=branch, commit=head, error=str(exc))
            raise

    def install(self):
        existing = self.call(['git', 'config', '--get', 'core.hooksPath'], check=False).stdout.decode().strip()
        if existing and existing != '.githooks':
            raise SyncError('Existing hooksPath must be reviewed; refusing to replace it')
        for name in ('pre-commit', 'post-commit', 'pre-push'):
            (self.root / '.githooks' / name).chmod(0o755)
        self.git('config', '--local', 'core.hooksPath', '.githooks')
        self.git('config', '--local', 'knowledgeSpine.autoSync', 'true')
        self.git('config', '--local', 'knowledgeSpine.approvedVisibility', self.approved_visibility())
        if not self.guard_path().is_file(): self.write_guard([])
        self.refresh_guard()
        print('Installed: commit/push audit, local-only privacy fingerprints and automatic sync')

    def checks(self):
        self.git('diff', '--check')
        commands = [
            [sys.executable, '-m', 'unittest', 'discover', '-s', 'Tests', '-p', 'test_*.py'],
            ['swift', 'build', '--scratch-path', '.build/repo-sync-check', '-c', 'release'],
            ['.build/repo-sync-check/release/KnowledgeSpineSelfTest'],
        ]
        for command in commands:
            print('Checking: ' + ' '.join(command), flush=True)
            result = self.call(command, check=False, timeout=900)
            if result.returncode:
                # Existing tests use synthetic inputs. Full diagnostic output stays local.
                log = self.root / '.build/repo-sync-logs/check.log'
                log.parent.mkdir(parents=True, exist_ok=True)
                log.write_bytes(result.stdout + result.stderr)
                raise SyncError('Checks failed; diagnostics saved to %s' % log)
        print('Delivery checks passed (synthetic tests; App not launched)')

    def finish(self, message, paths):
        self.assert_destination()
        self.install()
        staged = self.git('diff', '--cached', '--name-only', '-z')
        if staged:
            raise SyncError('Index already contains changes; review them before delivery')
        if not paths:
            raise SyncError('Explicit reviewed file paths are required; no automatic add-all')
        for name in paths:
            if path_problem(name):
                raise SyncError('Refusing local data path: ' + name)
            candidate = (self.root / name).resolve()
            if self.root not in candidate.parents or candidate.is_dir():
                raise SyncError('Supply individual repository files, not directories: ' + name)
        # Audit existing history before checks; staged additions are audited before commit.
        self.audit()
        self.checks()
        self.git('add', '--', *paths)
        self.audit(index=True)
        result = self.call(['git', 'diff', '--cached', '--quiet'], check=False)
        if result.returncode == 0:
            raise SyncError('No selected changes to commit; use sync/status for an existing commit')
        self.call(['git', 'commit', '-m', message], timeout=900)
        # The hook pushes automatically. Independently verify; retry if it failed.
        if self.remote_head(self.branch()) != self.text('rev-parse', 'HEAD'):
            self.sync()
        self.status(require_synced=True)

    def status(self, require_synced=False):
        branch = self.branch()
        self.assert_destination()
        local = self.text('rev-parse', 'HEAD')
        remote = self.remote_head(branch)
        changes = self.git('status', '--porcelain', '-z').split(b'\0')
        dirty = any(changes)
        result = {'repository': EXPECTED_REPO, 'visibility': self.approved_visibility(), 'branch': branch,
                  'local': local, 'remote': remote, 'synced': local == remote,
                  'uncommitted_changes': dirty,
                  'auto_sync_enabled': self.call(['git', 'config', '--bool', '--get', 'knowledgeSpine.autoSync'], check=False).stdout.strip() == b'true',
                  'privacy_guard_installed': self.guard_path().is_file(),
                  'hooks_installed': self.call(['git', 'config', '--get', 'core.hooksPath'], check=False).stdout.strip() == b'.githooks'}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if require_synced and (local != remote or dirty or not result['auto_sync_enabled'] or not result['privacy_guard_installed']):
            raise SyncError('Delivery is incomplete: unsynced commit, uncommitted files or inactive sync/privacy guard')
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('install')
    audit = sub.add_parser('audit')
    audit.add_argument('--index', action='store_true')
    sub.add_parser('sync')
    guard = sub.add_parser('guard-push')
    guard.add_argument('remote')
    status = sub.add_parser('status')
    status.add_argument('--require-synced', action='store_true')
    sub.add_parser('check')
    finish = sub.add_parser('finish')
    finish.add_argument('-m', '--message', required=True)
    finish.add_argument('paths', nargs='+')
    args = parser.parse_args()
    root = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()
    repo = Repository(root)
    try:
        if args.command == 'install': repo.install()
        elif args.command == 'audit': repo.audit(index=args.index)
        elif args.command == 'sync': repo.sync()
        elif args.command == 'guard-push':
            if args.remote != 'origin': raise SyncError('Only the approved origin is permitted')
            repo.assert_destination()
            outgoing = []
            ref_names = []
            for line in sys.stdin:
                parts = line.split()
                if len(parts) != 4: raise SyncError('Invalid push update')
                local_ref, local_oid, remote_ref, remote_oid = parts
                if local_oid == '0' * 40 or not remote_ref.startswith(('refs/heads/', 'refs/tags/')):
                    raise SyncError('Ref deletion or hidden-ref push is not permitted')
                outgoing.append(local_oid)
                ref_names.extend([local_ref, remote_ref])
            repo.audit(extra_refs=outgoing, extra_metadata=ref_names)
        elif args.command == 'check': repo.checks()
        elif args.command == 'status': repo.status(args.require_synced)
        elif args.command == 'finish': repo.finish(args.message, args.paths)
    except (SyncError, ValueError, KeyError, OSError) as exc:
        print('NOT SYNCED / DELIVERY BLOCKED: ' + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
