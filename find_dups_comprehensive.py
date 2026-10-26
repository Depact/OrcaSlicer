import re, os, json

strings_L = {}
strings_u8L = {}

for root, dirs, files in os.walk('src'):
    for f in files:
        if f.endswith(('.cpp', '.hpp', '.h', '.c')):
            path = os.path.join(root, f)
            try:
                with open(path, 'r', encoding='utf-8', errors='ignore') as fp:
                    content = fp.read()
                for m in re.findall(r'\bL\(["\']([^"\']+)["\']\)', content):
                    strings_L.setdefault(m, []).append(path)
                for m in re.findall(r'_u8L\(["\']([^"\']+)["\']\)', content):
                    strings_u8L.setdefault(m, []).append(path)
            except:
                pass

common = set(strings_L.keys()) & set(strings_u8L.keys())
dups = []
for s in sorted(common):
    if len(s) > 10:
        dups.append({
            'string': s,
            'L_files': strings_L[s],
            'u8L_files': strings_u8L[s]
        })

with open('duplicates.json', 'w', encoding='utf-8') as f:
    json.dump(dups, f, indent=2)

print(f'Found {len(dups)} duplicate strings')
for d in dups:
    print(d['string'][:80])
    print('  L:', d['L_files'][:3])
    print('  _u8L:', d['u8L_files'][:3])
    print()