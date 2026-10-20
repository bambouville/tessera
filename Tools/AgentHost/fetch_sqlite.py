#!/usr/bin/env python3
"""Build-machine-only fetch of the exact public SQLite source; never host bootstrap."""
import argparse
import hashlib
import io
from pathlib import Path
import urllib.request
import zipfile
from build_artifacts import SQLITE_SOURCE_HASH, SQLITE_HEADER_HASH

ARCHIVE_HASH = '628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path)
    args=parser.parse_args()
    directory=args.directory.resolve()
    expected={'sqlite3.c':SQLITE_SOURCE_HASH,'sqlite3.h':SQLITE_HEADER_HASH}
    if directory.exists():
        if all((directory/name).is_file() and not (directory/name).is_symlink() and
               hashlib.sha256((directory/name).read_bytes()).hexdigest()==digest for name,digest in expected.items()):
            print(directory); return
        raise SystemExit('Refusing to overwrite an existing unverified SQLite source directory')
    with urllib.request.urlopen('https://sqlite.org/2026/sqlite-amalgamation-3530400.zip',timeout=30) as response:
        archive=response.read(4*1024*1024+1)
    if len(archive)>4*1024*1024 or hashlib.sha3_256(archive).hexdigest()!=ARCHIVE_HASH:
        raise SystemExit('SQLite archive checksum mismatch')
    outputs={}
    with zipfile.ZipFile(io.BytesIO(archive)) as source:
        for name,digest in expected.items():
            entry=source.getinfo('sqlite-amalgamation-3530400/'+name)
            if entry.file_size>12*1024*1024: raise SystemExit('SQLite source size limit')
            data=source.read(entry)
            if hashlib.sha256(data).hexdigest()!=digest: raise SystemExit('SQLite source checksum mismatch')
            outputs[name]=data
    directory.mkdir(parents=True)
    for name,data in outputs.items(): (directory/name).write_bytes(data)
    print(directory)


if __name__=='__main__': main()
