"""Verify read-only inventory of the real three-slot file layout."""
from pathlib import Path
import hashlib
import json
import struct
import subprocess
import tempfile

root=Path(__file__).resolve().parents[2]
source=(root/'mcu/components/snapshot/snapshot.c').read_text()
first=source.index('typedef struct {\n    unsigned entries, files;')
functions=source[first:source.index('static void worker(',first)]
prefix='''#include "slot.h"
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
'''
with tempfile.TemporaryDirectory() as directory:
    tmp=Path(directory)
    data=tmp/'SNAP'
    data.mkdir()
    for slot in range(1,4):
        for game in range(2):
            identity=bytes([0x1b,3,3,0xca,0x77,0x88,0x99,game])
            folder=data if slot==1 else data/f'SLOT{slot}'/identity[:4].hex().upper()
            folder.mkdir(parents=True,exist_ok=True)
            for generation in range(2):
                filename=folder/(identity[4:].hex().upper()+f'.S{generation}')
                filename.write_bytes(b'CSS\2'+identity+struct.pack('>I',generation+7)+b'payload')
    (data/'ignored.txt').write_text('test')
    (data/'12345678.S0').write_bytes(b'short')
    before={f.relative_to(data).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in data.rglob('*') if f.is_file()}
    c=tmp/'files.c'
    c.write_text(prefix+functions+'\nint main(int argc, char **argv) { return argc==2 ? list_snapshot_files(argv[1]) : 9; }\n')
    binary=tmp/'files'
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-I'+str(root/'mcu/components/snapshot'),str(c),'-o',str(binary)],check=True)
    out=subprocess.check_output([str(binary),str(data)],text=True)
    lines=[json.loads(s) for s in out.splitlines()]
    assert len(lines)==14,lines
    files=lines[:-1]
    assert lines[-1]['files']==13 and not lines[-1]['limited'] and lines[-1]['result']==0
    assert sum(f['css2_header'] for f in files)==12
    assert {f['identity'] for f in files if f['css2_header']}=={'1b0303ca77889900','1b0303ca77889901'}
    assert {f['generation'] for f in files if f['css2_header']}=={7,8}
    after={f.relative_to(data).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in data.rglob('*') if f.is_file()}
    assert before==after
    missing=tmp/'missing'
    empty=json.loads(subprocess.check_output([str(binary),str(missing)],text=True))
    assert empty['files']==0 and empty['result']==0 and not missing.exists()
    print('PASS read-only snapshot file inventory: 3 slots, 2 identities, 2 generations, short header, missing root, unchanged names and content; ASan/UBSan')
