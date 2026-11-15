#!/usr/bin/env bash
# Opt-in real Linux VT/getty regression in a throwaway RAM-only x86 guest.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CERALIVE_ATTENTION_VM_KERNEL:?provide a readable native x86 Linux kernel}"
: "${CERALIVE_ATTENTION_QEMU:?provide qemu-system-x86_64}"
: "${CERALIVE_ATTENTION_VM_OUTPUT:?provide an existing empty evidence directory}"
[[ -r $CERALIVE_ATTENTION_VM_KERNEL && -d $CERALIVE_ATTENTION_VM_OUTPUT ]]
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root
mkdir -p "$root"
python3 - "$root" <<'PY'
from pathlib import Path
import shutil
import os
import shlex
import subprocess
import sys
import sysconfig
root=Path(sys.argv[1])
def copy(path):
    target=root/str(path).lstrip('/')
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(path,target,follow_symlinks=True)
stdlib=Path(sysconfig.get_path('stdlib'))
shutil.copytree(stdlib,root/str(stdlib).lstrip('/'),ignore=shutil.ignore_patterns('__pycache__','test','site-packages'))
bins=['/bin/busybox','/usr/bin/python3','/usr/sbin/agetty','/usr/bin/setfont','/usr/bin/chvt','/usr/bin/fgconsole']
for binary in bins:
    copy(Path(binary))
for binary in [*bins,*map(str,(root/str(stdlib).lstrip('/')).rglob('*.so'))]:
    for word in subprocess.run(['ldd',binary],capture_output=True,text=True,check=False).stdout.split():
        if word.startswith('/') and Path(word).is_file():
            copy(Path(word))
modules=root/'modules'
modules.mkdir()
loads=[]
for index, source in enumerate(shlex.split(os.environ.get('CERALIVE_ATTENTION_VM_MODULES',''))):
    destination=modules/(str(index)+'.ko')
    if source.endswith('.zst'):
        with destination.open('wb') as output:
            subprocess.run(['zstd','-dc',source],stdout=output,check=True)
    else:
        shutil.copy2(source,destination)
    loads.append('/bin/busybox insmod /modules/'+destination.name)
(root/'load-modules.sh').write_text('\n'.join(loads)+'\n')
copy(Path('/usr/share/consolefonts/Lat15-TerminusBold32x16.psf.gz'))
shutil.copy2('mkosi/runtime/ceralive-attention.py',root/'attention.py')
for folder in ['dev','proc','sys','run','tmp','etc','bin']:
    (root/folder).mkdir(exist_ok=True)
for name in ['sh','mount','poweroff','login']:
    (root/'bin'/name).symlink_to('/bin/busybox')
(root/'etc/passwd').write_text('root:x:0:0:Root:/:/bin/sh\n')
(root/'etc/shadow').write_text('root::0:0:99999:7:::\n')
PY
cat >"$root/init" <<'INIT'
#!/bin/sh
/bin/mount -t devtmpfs devtmpfs /dev
/bin/mount -t proc proc /proc
/bin/mount -t sysfs sysfs /sys
/bin/mount -t tmpfs tmpfs /run
exec </dev/console >/dev/console 2>&1
/bin/sh /load-modules.sh
/usr/bin/python3 /test.py
/bin/poweroff -f
INIT
chmod +x "$root/init"
cat >"$root/test.py" <<'PY'
import base64
import importlib.util
import json
import subprocess
from pathlib import Path
import time
spec=importlib.util.spec_from_file_location('attention','/attention.py')
a=importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
owner=a.Console()
top=dict(severity='fatal',line='The card is not ready.',fix='Check the card.',detail='Synthetic storage refusal.')
gettys=[]
def cmd(*args):
    return subprocess.run(args,capture_output=True,text=True,check=True).stdout.strip()
def capture(stage):
    value={'stage':stage,'vt':cmd('fgconsole')}
    for number in (1,8):
        value['vcs'+str(number)]=base64.b64encode(Path('/dev/vcs'+str(number)).read_bytes()).decode()
        value['geometry'+str(number)]=list(Path('/dev/vcsa'+str(number)).read_bytes()[:4])
    print('ATTENTION-VM '+json.dumps(value),flush=True)
try:
    # Allocate both consoles, record their native geometry and font.
    Path('/dev/tty1').write_text('')
    Path('/dev/tty8').write_text('')
    cmd('chvt','1')
    cmd('setfont','-C','/dev/tty8','-O','/run/before.psf')
    baseline=Path('/run/before.psf').read_bytes()
    geometry=Path('/dev/vcsa1').read_bytes()[:2]
    diagnostic_geometry=Path('/dev/vcsa8').read_bytes()[:2]
    owner.update(top)
    capture('fatal-before-getty')
    assert Path('/dev/vcsa8').read_bytes()[:2]!=diagnostic_geometry, 'guest needs framebuffer support for the large bitmap font'
    for tty in ('tty1','tty2'):
        gettys.append(subprocess.Popen(['/usr/sbin/agetty','--noissue','--nohostname',tty,'115200','linux']))
    time.sleep(10)  # Reproduce the late-getty window with actual getty processes.
    owner.update(top)
    capture('fatal-after-late-getty')
    assert b'The card is not ready.' in Path('/dev/vcs8').read_bytes()
    assert b'login:' in Path('/dev/vcs1').read_bytes()
    assert Path('/dev/vcsa1').read_bytes()[:2]==geometry
    cmd('chvt','1')
    owner.update(top)
    capture('login-while-fatal')
    assert cmd('fgconsole')=='1'
    assert b'login:' in Path('/dev/vcs1').read_bytes()
    cmd('chvt','8')
    owner.update(top|dict(severity='info'))
    capture('info-handback')
    assert cmd('fgconsole')=='1'
    cmd('setfont','-C','/dev/tty8','-O','/run/after.psf')
    assert Path('/run/after.psf').read_bytes()==baseline
    assert Path('/dev/vcsa8').read_bytes()[:2]==diagnostic_geometry
    assert b'login:' in Path('/dev/vcs1').read_bytes()
    assert Path('/dev/vcsa1').read_bytes()[:2]==geometry
    owner.update(top|dict(severity='critical'))
    owner.release()
    capture('stop-handback')
    assert cmd('fgconsole')=='1'
    print('ATTENTION-VM PASS',flush=True)
finally:
    owner.release()
    for process in gettys:
        process.terminate()
PY
(cd "$root"; find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -1) >"$work/initrd.gz"
args=()
if [[ -n ${CERALIVE_ATTENTION_QEMU_DATA:-} ]]; then args+=(-L "$CERALIVE_ATTENTION_QEMU_DATA"); fi
timeout 120 "$CERALIVE_ATTENTION_QEMU" "${args[@]}" -machine pc -accel tcg -m 512 -smp 1 \
  -kernel "$CERALIVE_ATTENTION_VM_KERNEL" -initrd "$work/initrd.gz" \
  -append 'console=tty0 console=ttyS0 quiet panic=-1' \
  -display none -serial stdio -monitor none -nic none -no-reboot >"$CERALIVE_ATTENTION_VM_OUTPUT/serial.log" 2>&1
python3 - "$CERALIVE_ATTENTION_VM_OUTPUT" <<'PY'
import base64
import json
from pathlib import Path
import sys
root=Path(sys.argv[1])
log=(root/'serial.log').read_text(errors='replace')
assert 'ATTENTION-VM PASS' in log, log[-4000:]
for line in log.splitlines():
    if line.startswith('ATTENTION-VM {'):
        item=json.loads(line.removeprefix('ATTENTION-VM '))
        for key in ('vcs1','vcs8'):
            (root/(item['stage']+'-'+key+'.txt')).write_bytes(base64.b64decode(item[key]))
        (root/(item['stage']+'.json')).write_text(json.dumps(item))
print('real VT/getty startup race, reachable login, text/font hand-back: PASS')
PY
