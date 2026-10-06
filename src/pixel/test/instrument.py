import sys
s = open(sys.argv[1]).read()

def checked(s, name, fn):   # name[...] -> (*fn(...)), with bracket matching
    out, i, pat = [], 0, name + '['
    while True:
        j = s.find(pat, i)
        if j < 0: out.append(s[i:]); return ''.join(out)
        if j > 0 and (s[j-1].isalnum() or s[j-1] == '_'):
            out.append(s[i:j+len(pat)]); i = j + len(pat); continue
        out.append(s[i:j]); k, depth = j + len(pat), 1
        while depth:
            depth += {'[': 1, ']': -1}.get(s[k], 0); k += 1
        out.append('(*' + fn + '(' + s[j+len(pat):k-1] + '))'); i = k

s = checked(s, 'grid', 'gchk')
s = checked(s, 'iters', 'ichk')
s = s.replace('static struct cell *grid;', 'static struct cell *grid;\nstatic struct cell *gchk(long i) { if (i < 0 || i >= (long)rows * cols) { fprintf(stderr, "OUT OF BOUNDS %ld (rows %d cols %d)\\n", i, rows, cols); abort(); } return &grid[i]; }')
s = s.replace('static int *iters;', 'static int *iters;\nstatic int *ichk(long i) { if (i < 0 || i >= (long)rows * cols) { fprintf(stderr, "OUT OF BOUNDS iters %ld\\n", i); abort(); } return &iters[i]; }')
open(sys.argv[2], 'w').write(s)
