#!/usr/bin/python3
"""
make-mod.py - writes waffle.mod, a small 4-channel ProTracker module made from
scratch (synthesized samples, no third-party music): the demo song of the
Waffle ModPlayer, put on the demo floppy by make-examples.sh.

  docs/examples/make-mod.py [output.mod]
"""

import math
import random
import struct
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else 'waffle.mod'
rng = random.Random(1985)      # same file every time

# ── Samples: signed 8-bit; a looped single cycle sounds C at note C ─────────
def cycle(fn, n):
    return [max(-128, min(127, round(fn(i / n) * 127))) for i in range(n)]

square   = cycle(lambda t: 0.55 if t < 0.5 else -0.55, 32)
triangle = cycle(lambda t: 4 * t - 1 if t < 0.5 else 3 - 4 * t, 64)    # an octave lower
pulse    = cycle(lambda t: 0.45 if t < 0.25 else -0.45, 32)

def kick():
    out, phase = [], 0.0
    for i in range(1800):
        f = 160 * math.exp(-i / 280) + 45        # pitch sweep down
        phase += f / 8287
        out.append(round(math.sin(2 * math.pi * phase) * 127 * math.exp(-i / 900)))
    return out

def noise(length, decay):
    return [round(rng.uniform(-1, 1) * 127 * math.exp(-i / decay)) for i in range(length)]

# (name, data, volume, looped)
SAMPLES = [
    ('square lead',  square,          48, True),
    ('triangle bass', triangle,       64, True),
    ('kick',         kick(),          64, False),
    ('snare',        noise(2400, 500), 50, False),
    ('hihat',        noise(500, 90),   30, False),
    ('pulse chords', pulse,           34, True),
]

# ── Notes: ProTracker periods, octaves 1-3 ───────────────────────────────────
PERIODS = [856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
           428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
           214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113]
NAMES = ['C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-']

def period(note):            # "A-2" -> period
    return PERIODS[NAMES.index(note[:2]) + 12 * (int(note[2]) - 1)]

def cell(note=None, sample=0, effect=0, param=0):
    p = period(note) if note else 0
    return bytes([(sample & 0xF0) | (p >> 8), p & 0xFF, ((sample & 0x0F) << 4) | effect, param])

EMPTY = cell()

# ── The song: A minor, F, C, G; arpeggio chords (effect 0xy) as on the Amiga ─
CHORDS = [('A-1', 0x37), ('F-1', 0x47), ('C-2', 0x47), ('G-1', 0x47)]
MELODY = [
    'E-3 . . . C-3 . D-3 . E-3 . . . A-2 . . . C-3 . B-2 . A-2 . G-2 . A-2 . . . . . . .',
    'F-2 . A-2 . C-3 . . . A-2 . C-3 . F-3 . . . E-3 . D-3 . C-3 . . . A-2 . . . . . . .',
    'G-2 . C-3 . E-3 . . . G-3 . . . E-3 . C-3 . D-3 . E-3 . G-3 . . . E-3 . . . . . . .',
    'D-3 . . . B-2 . G-2 . B-2 . D-3 . G-3 . . . F-3 . D-3 . B-2 . . . G-2 . . . . . . .',
]

def pattern(n, lead=True):
    root, arp = CHORDS[n]
    melody = MELODY[n].split()
    rows = []
    for r in range(64):
        # lead: the melody, played twice (32 rows each), a bit louder the second time
        m = melody[r % 32] if lead else '.'
        c0 = cell(m, 1, 0xC, 40 if r < 32 else 52) if m != '.' else EMPTY
        # bass: the root on every beat, the octave above on the off-beats
        if r % 4 == 0:
            c1 = cell(root, 2)
        elif r % 4 == 2:
            c1 = cell(root[:2] + str(int(root[2]) + 1), 2, 0xC, 40)
        else:
            c1 = EMPTY
        # drums: kick on 1 and 3 (and a push before 3), snare on 2 and 4, hihat in between
        if r % 16 in (0, 6, 8):
            c2 = cell('C-2', 3)
        elif r % 16 in (4, 12):
            c2 = cell('C-2', 4)
        elif r % 2 == 0:
            c2 = cell('C-3', 5)
        else:
            c2 = EMPTY
        # chords: the chord as an arpeggio, the effect repeated on every row to keep it going
        if r % 16 == 0:
            c3 = cell(root[:2] + str(int(root[2]) + 1), 6, 0x0, arp)
        else:
            c3 = cell(None, 0, 0x0, arp)
        rows.append(c0 + c1 + c2 + c3)
    return b''.join(rows)

patterns = [pattern(i, lead=False) for i in range(4)] + [pattern(i) for i in range(4)]
order = [4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7]      # theme, break without the lead, theme

# ── Write the module ─────────────────────────────────────────────────────────
mod = bytearray(b'waffle-fuse demo'.ljust(20, b'\0'))
for i in range(31):
    if i < len(SAMPLES):
        name, data, vol, looped = SAMPLES[i]
        words = len(data) // 2
        loop = (0, words) if looped else (0, 1)
        mod += name.encode().ljust(22, b'\0') + struct.pack('>HBBHH', words, 0, vol, *loop)
    else:
        mod += b'\0' * 22 + struct.pack('>HBBHH', 0, 0, 0, 0, 1)
mod += bytes([len(order), 127]) + bytes(order).ljust(128, b'\0') + b'M.K.'
for p in patterns:
    mod += p
for _, data, _, looped in SAMPLES:
    if not looped:
        data = [0, 0] + data[2:]     # one-shot samples start with silence (ProTracker)
    mod += bytes((v & 0xFF) for v in data[: len(data) // 2 * 2])

with open(OUT, 'wb') as f:
    f.write(mod)
print(f'{OUT}: {len(mod)} bytes, {len(order)} positions, {len(patterns)} patterns')
