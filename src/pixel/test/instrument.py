import sys
s = open(sys.argv[1]).read()
out, i = [], 0
while True:
    j = s.find('grid[', i)
    if j < 0: out.append(s[i:]); break
    if j > 0 and (s[j-1].isalnum() or s[j-1] == '_'):   # pgrid etc.
        out.append(s[i:j+5]); i = j + 5; continue
    out.append(s[i:j]); k, depth = j + 5, 1
    while depth:
        depth += {'[': 1, ']': -1}.get(s[k], 0); k += 1
    out.append('(*gchk(' + s[j+5:k-1] + '))'); i = k
s = ''.join(out)
s = s.replace('static struct cell *grid;', 'static struct cell *grid;\nstatic struct cell *gchk(long i) { if (i < 0 || i >= (long)rows * cols) { fprintf(stderr, "OUT OF BOUNDS %ld (rows %d cols %d)\\n", i, rows, cols); abort(); } return &grid[i]; }')
open(sys.argv[2], 'w').write(s)
