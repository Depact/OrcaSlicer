import re, os

replacements = [
    # shared_p_u8L -> shared_ptr
    (r'shared_p_u8L', 'shared_ptr'),
    # std::weak_p_u8L -> std::weak_ptr
    (r'std::weak_p_u8L', 'std::weak_ptr'),
]

for root, dirs, files in os.walk('src'):
    for f in files:
        if f.endswith(('.cpp', '.hpp', '.h', '.c')):
            path = os.path.join(root, f)
            try:
                with open(path, 'r', encoding='utf-8', errors='ignore') as fp:
                    content = fp.read()
                original = content
                for pat, repl in replacements:
                    content = re.sub(pat, repl, content)
                if content != original:
                    with open(path, 'w', encoding='utf-8') as fp:
                        fp.write(content)
                    print(f'Fixed: {path}')
            except Exception as e:
                pass

print('Done')