import re, sys
src = open(sys.argv[1], encoding='utf-8').read()

# Strip comments and string literals so names inside them cannot create false hits.
s = re.sub(r'--\[\[.*?\]\]', lambda m: '\n'*m.group(0).count('\n'), src, flags=re.S)
s = re.sub(r'--[^\n]*', '', s)
# NOTE the \n exclusions: without them an unbalanced quote lets the match run across lines and
# silently renumbers the file, which made an earlier version of this check report nothing.
s = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', s)
s = re.sub(r"'(?:\\.|[^'\\\n])*'", "''", s)
lines = s.split('\n')

# First declaration line for each file-level local.
decl = {}
for i, ln in enumerate(lines, 1):
    # FILE-LEVEL only (no leading whitespace). Locals declared inside a function are
    # block-scoped and a use "before" them elsewhere is not the bug being looked for.
    m = re.match(r'local\s+function\s+([A-Za-z_][A-Za-z0-9_]*)', ln) or \
        re.match(r'local\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|$)', ln)
    if m and m.group(1) not in decl:
        decl[m.group(1)] = i

bad = []
for name, dline in decl.items():
    pat = re.compile(r'\b%s\b' % re.escape(name))
    for i, ln in enumerate(lines[:dline-1], 1):
        if pat.search(ln):
            bad.append((name, i, dline))
            break

if bad:
    print("ERROR: local used before its declaration (compiles to a nil global at runtime):")
    for name, use, dline in sorted(bad, key=lambda b: b[1]):
        print("   '%s' used on line %d but declared on line %d" % (name, use, dline))
    sys.exit(1)
print("scope check: no local is used before it is declared")
