import re, os
strings_L = {}
strings_u8L = {}
for root, dirs, files in os.walk('src'):
    for f in files:
        if f.endswith(('.cpp', '.hpp', '.h', '.c')):
            path = os.path.join(root, f)
            try:
                with open(path, 'r', encoding='utf-8', errors='ignore') as fp:
                    content = fp.read()
                for m in re.findall(r'\bL\([\"\']([^\"\']+)[\"\']\)', content):
                    strings_L.setdefault(m, []).append(path)
                for m in re.findall(r'_u8L\([\"\']([^\"\']+)[\"\']\)', content):
                    strings_u8L.setdefault(m, []).append(path)
            except:
                pass
common = set(strings_L.keys()) & set(strings_u8L.keys())
for s in sorted(common):
    if len(s) > 10:
        print(s)
        print('  L:', strings_L[s])
        print('  _u8L:', strings_u8L[s])
        print()