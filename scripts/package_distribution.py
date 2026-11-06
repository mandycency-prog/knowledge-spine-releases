#!/usr/bin/env python3
"""Assemble only declared code and freshly prepared vendor runtime, never user data."""
import argparse,hashlib,json,os,plistlib,shutil,stat,subprocess
from pathlib import Path
BACKEND = ['local_pipeline.py','quote_evidence.py','source_bound_map.py','stage_synthesis.py',
 'branch_expansion.py','focused_study.py','model_lease.py','remote_model.py','transcript_proofreader.py',
 'punctuation_formatter.py','live_worker.py','audio_context.py','apple_speech.py','image_analysis.py']
MODEL_SHA='ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e'
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
 return h.hexdigest()
def execute(*args):subprocess.run(args,check=True,stdout=subprocess.DEVNULL)
def main():
 p=argparse.ArgumentParser(description=__doc__)
 for name in ['runtime','ffmpeg','model','ffmpeg-source','build-dir','output']:p.add_argument('--'+name,required=True,type=Path)
 p.add_argument('--build-number',help='Override the build identifier; the release version comes from Info.plist')
 args=p.parse_args();root=Path(__file__).resolve().parents[1]
 assert not args.output.exists(),'Output must be new'
 assert sha(args.model)==MODEL_SHA,'Whisper public model hash mismatch'
 app=args.output/'直播与课程知识骨架测试版.app';contents=app/'Contents';resources=contents/'Resources'
 (contents/'MacOS').mkdir(parents=True);(resources/'Backend').mkdir(parents=True)
 for name in BACKEND:shutil.copyfile(root/'Backend'/name,resources/'Backend'/name)
 for name in ['KnowledgeSpineApp','KnowledgeSpineAppleSpeech']:
  target=contents/'MacOS'/name;shutil.copyfile(args.build_dir/name,target);target.chmod(0o755);execute('strip','-S',str(target))
 info=plistlib.loads((root/'AppBundle/Info.plist').read_bytes())
 info.update(CFBundleIdentifier='com.local.knowledgespine.preview',CFBundleDisplayName='直播与课程知识骨架测试版',
  CFBundleName='直播与课程知识骨架测试版',CFBundleVersion=args.build_number or info['CFBundleVersion'],
  KnowledgeSpineDistributionPreview=True)
 (contents/'Info.plist').write_bytes(plistlib.dumps(info))
 runtime=resources/'Runtime';shutil.copytree(args.runtime,runtime,symlinks=True,
  ignore=shutil.ignore_patterns('__pycache__','*.pyc','*.pyo'))
 # CMake installs an unused CLI helper library linked to the build host's OpenSSL.
 # Python bindings use llama_cpp/lib; do not redistribute that CLI-only helper.
 for extra in (runtime/'lib/python3.11/site-packages/lib').glob('libllama-common*'):
  extra.unlink()
 launcher=runtime/'bin/runtime-python'
 launcher.write_text('''#!/bin/sh
runtime_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
unset PYTHONHOME PYTHONPATH PYTHONUSERBASE
export SSL_CERT_FILE="$runtime_root/lib/python3.11/site-packages/certifi/cacert.pem"
exec "$runtime_root/bin/python3.11" -E -s -B "$@"
''');launcher.chmod(0o755)
 # Console entry points installed by pip contain build-machine shebangs. The app uses its launcher only.
 for item in (runtime/'bin').iterdir():
  if item.is_file() and not item.is_symlink() and item.name!='runtime-python':
   with item.open('rb') as f:header=f.read(256)
   if header.startswith(b'#!') and b'/Users/' in header.split(b'\n')[0]:item.unlink()
 (resources/'Tools').mkdir();shutil.copyfile(args.ffmpeg,resources/'Tools/ffmpeg');(resources/'Tools/ffmpeg').chmod(0o755)
 (resources/'Models').mkdir();shutil.copyfile(args.model,resources/'Models/base.pt')
 notices=resources/'ThirdPartyNotices';notices.mkdir()
 shutil.copyfile(args.ffmpeg_source,notices/args.ffmpeg_source.name)
 source_root=args.ffmpeg.parent
 for n in ['COPYING.LGPLv2.1','COPYING.LGPLv3','LICENSE.md']:
  if (source_root/n).exists():shutil.copyfile(source_root/n,notices/('FFmpeg-'+n))
 # Upstream dependency notices remain alongside installed packages and Python stdlib.
 whisper_license=runtime/'lib/python3.11/site-packages/openai_whisper-20250625.dist-info/licenses/LICENSE'
 if not whisper_license.exists():whisper_license=runtime/'lib/python3.11/site-packages/openai_whisper-20250625.dist-info/LICENSE'
 if whisper_license.exists():shutil.copyfile(whisper_license,notices/'Whisper-LICENSE')
 (notices/'README.txt').write_text('Python license: Runtime/lib/python3.11/LICENSE.txt\nPython packages: Runtime/lib/python3.11/site-packages/*.dist-info (licenses and METADATA).\nWhisper code/model: https://github.com/openai/whisper, MIT.\nFFmpeg: unmodified official source archive included; LGPL build, no GPL/nonfree options.\n')
 files=sorted(x for x in contents.rglob('*') if x.is_file() and not x.is_symlink())
 magic={b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'}
 native=[]
 for x in files:
  with x.open('rb') as f:head=f.read(4)
  if head in magic:native.append(x)
 for x in sorted(native,key=lambda x:len(x.parts),reverse=True):execute('codesign','--force','--sign','-',str(x))
 execute('codesign','--force','--sign','-',str(app));execute('codesign','--verify','--deep','--strict',str(app))
 inventory={str(x.relative_to(app)):sha(x) for x in app.rglob('*') if x.is_file() and not x.is_symlink()}
 (args.output/'bundle-inventory.json').write_text(json.dumps(inventory,indent=2))
 print(app)
if __name__=='__main__':main()
