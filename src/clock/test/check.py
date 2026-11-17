#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
"""check.py <clock binary> - runs clock on pseudo terminals and reads what it writes through a
small model of a terminal (only the sequences clock is allowed to use).

Checked for many window sizes and every option and key: nothing is written outside the window
and nothing scrolls; the lit cells are exactly the current time in the 3x5 digits, as large as
the window allows and centred; the text line is the date (and AM/PM); a window that is too small
gets the time as plain text; the picture follows a resize and ticks; the terminal is restored
after q, Ctrl+C, SIGTERM and SIGHUP. The digit shapes are written out again here on purpose:
the test must not share the program's table."""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

FONT = {
    '0': ["###", "# #", "# #", "# #", "###"],
    '1': [" # ", "## ", " # ", " # ", "###"],
    '2': ["###", "  #", "###", "#  ", "###"],
    '3': ["###", "  #", "###", "  #", "###"],
    '4': ["# #", "# #", "###", "  #", "  #"],
    '5': ["###", "#  ", "###", "  #", "###"],
    '6': ["###", "#  ", "###", "# #", "###"],
    '7': ["###", "  #", "  #", "  #", "  #"],
    '8': ["###", "# #", "###", "# #", "###"],
    '9': ["###", "# #", "###", "  #", "###"],
    ':': [" ", "#", " ", "#", " "],
}


def face_rows(face):
    """the face as five strings of '#' and ' ', one dark column between the glyphs"""
    return [" ".join(FONT[ch][r] for ch in face) for r in range(5)]


class Screen:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.cell = [[(' ', None)] * cols for _ in range(rows)]
        self.y = self.x = 0
        self.attr = None
        self.alt = self.hidden = False
        self.errors = []
        self.rest = b''

    def err(self, what):
        if what not in self.errors:
            self.errors.append(what)

    def feed(self, data):
        data = self.rest + data
        self.rest = b''
        i = 0
        while i < len(data):
            c = data[i]
            if c == 0x1b:
                j = i + 2
                while j < len(data) and not 0x40 <= data[j] <= 0x7e:
                    j += 1
                if j >= len(data):
                    self.rest = data[i:]     # cut off in the middle: wait for the rest
                    return
                if data[i + 1:i + 2] != b'[':
                    self.err("an escape sequence that is not CSI")
                self.csi(data[i + 2:j].decode('ascii', 'replace'), chr(data[j]))
                i = j + 1
                continue
            if c == 13:
                self.x = 0
            elif c == 10:
                if self.y == self.rows - 1:
                    self.err("scrolled: a line feed on the last row")
                else:
                    self.y += 1
            elif 32 <= c < 127:
                if self.x >= self.cols:
                    self.err("wrote past the last column")
                else:
                    self.cell[self.y][self.x] = (chr(c), self.attr)
                    self.x += 1
            else:
                self.err("byte %d" % c)
            i += 1

    def csi(self, par, final):
        if final == 'H' and par == '':
            self.y = self.x = 0
        elif final == 'K' and par == '':
            if self.x >= self.cols:
                self.err("erase to the end of a full row (would take its last cell)")
            if self.attr is not None:
                self.err("erase with an attribute set")
            for x in range(self.x, self.cols):
                self.cell[self.y][x] = (' ', None)
        elif final == 'J' and par == '2':
            self.cell = [[(' ', None)] * self.cols for _ in range(self.rows)]
        elif final == 'm' and par == '0':
            self.attr = None
        elif final == 'm' and par == '7':
            self.attr = 'rev'
        elif final == 'm' and len(par) == 2 and par[0] == '4' and par[1] in '1234567':
            self.attr = 'bg' + par[1]
        elif final in 'hl' and par == '?1049':
            self.alt = final == 'h'
        elif final in 'hl' and par == '?25':
            self.hidden = final == 'l'
        else:
            self.err("unexpected sequence ESC [ %s %s" % (par, final))


def setsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))


class Run:
    def __init__(self, binary, rows, cols, args=()):
        self.m, self.s = pty.openpty()
        setsize(self.s, rows, cols)
        self.before = termios.tcgetattr(self.s)
        env = dict(os.environ, LC_ALL='C', TERM='linux')
        self.p = subprocess.Popen([binary, *args], stdin=self.s, stdout=self.s, stderr=self.s,
                                  start_new_session=True, env=env,
                                  preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        self.scr = Screen(rows, cols)
        self.raw = b''

    def settle(self, quiet=0.2, limit=3.0):
        """read until the program has been silent for a moment; returns the bytes read"""
        got = b''
        end = time.time() + limit
        while time.time() < end:
            r, _, _ = select.select([self.m], [], [], quiet if got else limit)
            if not r:
                break
            try:
                d = os.read(self.m, 65536)
            except OSError:
                break
            if not d:
                break
            got += d
        self.raw += got
        self.scr.feed(got)
        return got

    def key(self, keys):
        os.write(self.m, keys)
        self.settle()

    def resize(self, rows, cols):
        self.scr = Screen(rows, cols)
        self.scr.alt = self.scr.hidden = True
        setsize(self.m, rows, cols)
        self.settle()

    def finish(self):
        end = time.time() + 3
        while self.p.poll() is None:              # keep reading: a full pty would block it
            if time.time() > end:
                self.p.kill()
                return "did not exit"
            self.settle(quiet=0.05, limit=0.05)
        rc = self.p.returncode
        self.settle(quiet=0.1, limit=0.3)
        after = termios.tcgetattr(self.s)
        os.close(self.m)
        os.close(self.s)
        if rc != 0:
            return "exit status %d: %s" % (rc, self.raw[-300:].decode('ascii', 'replace'))
        if after != self.before:
            return "terminal settings not restored"
        if not self.raw.endswith(b'\033[?25h\033[?1049l'):
            return "screen not restored at the end"
        return None


def faces_now(seconds, twelve, date):
    """(face, text) for the second before, this one and the next: the picture may be any of them"""
    out = []
    now = time.time()
    for d in (-1, 0, 1):
        tm = time.localtime(now + d)
        hour = tm.tm_hour
        if twelve:
            hour = hour % 12 or 12
        face = ("%d:%02d" if twelve else "%02d:%02d") % (hour, tm.tm_min)
        if seconds:
            face += ":%02d" % tm.tm_sec
        text = time.strftime("%A, %d %B %Y", tm) if date else ""
        if twelve:
            text += ("  " if text else "") + ("AM" if tm.tm_hour < 12 else "PM")
        out.append((face, text))
    return out


def check(scr, seconds=True, twelve=False, date=True, colour=0):
    """a list of what is wrong with the picture on scr (empty = right)"""
    bad = list(scr.errors)
    if scr.rest:
        bad.append("output ends inside an escape sequence")
    if not scr.alt or not scr.hidden:
        bad.append("not on the alternate screen with the cursor hidden")
    cands = faces_now(seconds, twelve, date)
    results = [picture(scr, face, text, colour) for face, text in cands]
    if [] not in results:
        bad += results[1]                          # report against the current second
    return bad


def picture(scr, face, text, colour):
    """what is wrong if the picture is meant to show this face and text"""
    bad = []
    rows, cols = scr.rows, scr.cols
    lit = {(y, x) for y in range(rows) for x in range(cols) if scr.cell[y][x][1] is not None}
    want = 'bg%d' % colour if colour else 'rev'
    if any(scr.cell[y][x] != (' ', want) for y, x in lit):
        bad.append("a lit cell that is not a space with attribute " + want)
    textrows = {y: "".join(c for c, _ in scr.cell[y]) for y in range(rows)
                if any(c != ' ' for c, _ in scr.cell[y])}
    fr = face_rows(face)
    w = len(fr[0])

    if cols < w or rows < 5:                       # too small for digits: plain text
        if lit:
            bad.append("digits drawn in a window that is too small for them")
        t = face[:cols]
        want_rows = {rows // 2: (" " * ((cols - len(t)) // 2) + t).ljust(cols)}
        if textrows != want_rows:
            bad.append("plain text: got %r, wanted %r" % (textrows, want_rows))
        return bad

    if not lit:
        return bad + ["no digits"]
    y0, y1 = min(y for y, _ in lit), max(y for y, _ in lit)
    if (y1 - y0 + 1) % 5:
        return bad + ["the digits are %d rows high, not a multiple of 5" % (y1 - y0 + 1)]
    sy = (y1 - y0 + 1) // 5
    found = None
    for sx in ([2 * sy, 1] if sy == 1 else [2 * sy]):
        exp = {(r * sy + dy, c * sx + dx) for r in range(5) for c in range(w) if fr[r][c] == '#'
               for dy in range(sy) for dx in range(sx)}
        ox = min(x for _, x in lit) - min(x for _, x in exp)
        if {(y + y0, x + ox) for y, x in exp} == lit:
            found = (sx, ox)
    if not found:
        return bad + ["the lit cells are not %s in the 3x5 digits" % face]
    sx, ox = found
    right = cols - (ox + w * sx)
    if ox < 0 or right < 0 or abs(ox - right) > 1:
        bad.append("digits not centred: %d columns left, %d right" % (ox, right))
    # the text: one row, below the digits, at a distance of half a cell's height (one row at
    # least, less where the window has no more), and centred like them
    lines = 2 if text and rows >= 7 else 0         # the least: an empty row and the text
    used = y1 - y0 + 1
    if lines:
        t = text[:cols]
        gap = min(max(1, sy // 2), rows - 5 * sy - 1)
        want_rows = {y1 + gap + 1: (" " * ((cols - len(t)) // 2) + t).ljust(cols)}
        used += gap + 1
    else:
        want_rows = {}
    if textrows != want_rows:
        bad.append("text: got %r, wanted %r" % (textrows, want_rows))
    below = rows - y0 - used
    if below < 0 or abs(y0 - below) > 1:
        bad.append("not centred vertically: %d rows above, %d below" % (y0, below))
    k = sy if sx == 2 * sy else 0                  # as large as the window allows
    if 2 * (k + 1) * w <= cols - 2 and 5 * (k + 1) + lines <= rows:
        bad.append("the digits could be larger (cell %dx%d in %dx%d)" % (sx, sy, cols, rows))
    return bad


failed = 0


def report(name, bad):
    global failed
    if bad:
        failed += 1
        print("FAIL %s: %s" % (name, "; ".join(bad) if isinstance(bad, list) else bad))


def main():
    binary = sys.argv[1]
    variants = [
        ((), {}),
        (('-s',), {'seconds': False}),
        (('-a',), {'twelve': True}),
        (('-d',), {'date': False}),
        (('-a', '-s', '-d'), {'seconds': False, 'twelve': True, 'date': False}),
        (('-c', '3'), {'colour': 3}),
    ]
    sizes = [(24, 80), (60, 200), (200, 500), (50, 57), (10, 17), (7, 56), (6, 56), (5, 56),
             (5, 29), (5, 27), (5, 26), (5, 17), (5, 16), (4, 80), (24, 54), (24, 55), (24, 56),
             (24, 57), (3, 5), (2, 8), (1, 8), (1, 1), (11, 36), (12, 36), (13, 38), (40, 40),
             (5, 23), (5, 22), (5, 13), (5, 12), (67, 240), (30, 100), (9, 60), (8, 120),
             (27, 300), (22, 250), (32, 330)]     # the last three: no room for the full distance to the text
    n = 0
    for rows, cols in sizes:
        for args, state in variants:
            r = Run(binary, rows, cols, args)
            r.settle()
            report("%dx%d %s" % (cols, rows, " ".join(args)), check(r.scr, **state))
            os.write(r.m, b'q')
            report("%dx%d %s quit" % (cols, rows, " ".join(args)), r.finish())
            n += 1
    print("sizes and options: %d runs" % n)

    # every kind of hour (midnight and noon are 12 on a 12-hour face): the time zone of the
    # clock and of this test is moved so that it is that hour now
    zone = os.environ.get('TZ')
    for want in (0, 1, 11, 12, 13, 23):
        os.environ['TZ'] = "TST%d" % ((time.gmtime().tm_hour - want) % 24)
        time.tzset()
        for args, state in variants[0], variants[2]:
            r = Run(binary, 24, 80, args)
            r.settle()
            report("hour %d %s" % (want, " ".join(args)), check(r.scr, **state))
            os.write(r.m, b'q')
            report("hour %d %s quit" % (want, " ".join(args)), r.finish())
    if zone is None:
        del os.environ['TZ']
    else:
        os.environ['TZ'] = zone
    time.tzset()
    print("hours: done")

    # keys
    r = Run(binary, 24, 80)
    r.settle()
    state = {'seconds': True, 'twelve': False, 'date': True, 'colour': 0}
    for key in b'sadccccccccasd':
        key = bytes([key])
        if key == b'c':
            state['colour'] = (state['colour'] + 1) % 8
        else:
            name = {b's': 'seconds', b'a': 'twelve', b'd': 'date'}[key]
            state[name] = not state[name]
        r.key(key)
        report("key %s -> %s" % (key.decode(), state), check(r.scr, **state))
    r.key(b'x\t5')                                  # keys without a meaning change nothing
    report("unknown keys", check(r.scr, **state))
    os.write(r.m, b'\033')
    report("Esc quits", r.finish())
    print("keys: done")

    # resize
    r = Run(binary, 24, 80)
    r.settle()
    for rows, cols in [(60, 200), (3, 10), (24, 80), (5, 27), (7, 300), (100, 30)]:
        r.resize(rows, cols)
        report("resize to %dx%d" % (cols, rows), check(r.scr))
    os.write(r.m, b'Q')
    report("resize quit", r.finish())
    print("resize: done")

    # it ticks; without seconds nothing is written until the minute changes
    r = Run(binary, 24, 80)
    r.settle()
    for i in range(3):
        report("tick %d" % i, check(r.scr))
        time.sleep(1.0)
        r.settle()
    report("tick 3", check(r.scr))
    r.key(b's')
    if time.localtime().tm_sec < 56:
        time.sleep(2.5)
        got = r.settle(quiet=0.1, limit=0.2)
        report("no seconds: quiet", ["%d bytes written although nothing changed" % len(got)] if got else None)
    os.write(r.m, b'q')
    report("tick quit", r.finish())
    print("ticking: done")

    # every way out restores the terminal and exits 0
    for name, how in [("Ctrl+C", lambda r: os.write(r.m, b'\x03')),
                      ("SIGTERM", lambda r: r.p.send_signal(signal.SIGTERM)),
                      ("SIGHUP", lambda r: r.p.send_signal(signal.SIGHUP)),
                      ("SIGINT", lambda r: r.p.send_signal(signal.SIGINT))]:
        r = Run(binary, 24, 80)
        r.settle()
        how(r)
        report(name, r.finish())
    r = Run(binary, 24, 80)                         # the terminal goes away
    r.settle()
    os.close(r.m)
    os.close(r.s)
    try:
        if r.p.wait(timeout=3) != 0:
            report("terminal closed", "exit status %d" % r.p.returncode)
    except subprocess.TimeoutExpired:
        r.p.kill()
        report("terminal closed", "still running")
    print("ways out: done")

    # wrong use
    for args in (['-x'], ['-c', '8'], ['-c', '12'], ['-c', ''], ['word'], ['-s', 'word']):
        p = subprocess.run([binary, *args], stdin=subprocess.DEVNULL, capture_output=True)
        if p.returncode != 1 or b'usage: clock' not in p.stderr or p.stdout:
            report("clock " + " ".join(args), "status %d, %r" % (p.returncode, p.stderr[:80]))
    p = subprocess.run([binary], stdin=subprocess.DEVNULL, capture_output=True)
    if p.returncode != 1 or p.stderr != b'clock: not a terminal\n' or p.stdout:
        report("no terminal", "status %d, %r %r" % (p.returncode, p.stderr[:80], p.stdout[:40]))
    print("wrong use: done")

    print("FAILED: %d" % failed if failed else "all right")
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
