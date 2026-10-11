#!/usr/bin/env python3
"""treediff.py A B – compare two directory trees like diff -r, with file names
compared in Unicode NFC form.

macOS lists the names of a FUSE-T (NFS) volume in decomposed form (NFD), so
"Città" on the volume and "Città" in a local directory differ byte by byte
while being the same name.  Exit status 0 if the trees match, 1 otherwise.
"""

import os
import sys
import unicodedata


def listing(root):
    """{nfc relative path: ('dir', None) | ('file', real path)}"""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            key = unicodedata.normalize('NFC', os.path.normpath(os.path.join(rel, name)))
            out[key] = ('dir', None) if os.path.isdir(path) else ('file', path)
    return out


def same_content(a, b):
    with open(a, 'rb') as fa, open(b, 'rb') as fb:
        while True:
            ca, cb = fa.read(65536), fb.read(65536)
            if ca != cb:
                return False
            if not ca:
                return True


def main():
    a, b = sys.argv[1], sys.argv[2]
    la, lb = listing(a), listing(b)
    differ = False
    for key in sorted(set(la) | set(lb)):
        if key not in lb:
            print(f'Only in {a}: {key}')
        elif key not in la:
            print(f'Only in {b}: {key}')
        elif la[key][0] != lb[key][0]:
            print(f'{key}: directory in one tree, file in the other')
        elif la[key][0] == 'file' and not same_content(la[key][1], lb[key][1]):
            print(f'Files {a}/{key} and {b}/{key} differ')
        else:
            continue
        differ = True
    return 1 if differ else 0


if __name__ == '__main__':
    sys.exit(main())
