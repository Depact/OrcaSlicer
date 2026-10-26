import re, os

replacements = [
    # ptr() -> p_u8L() bad rename
    (r'\.p_u8L\(\)', '.ptr()'),
    # get_mesh_shared_p_u8L() -> get_mesh_shared_ptr()
    (r'get_mesh_shared_p_u8L\(\)', 'get_mesh_shared_ptr()'),
    # get_convex_hull_shared_p_u8L() -> get_convex_hull_shared_ptr()
    (r'get_convex_hull_shared_p_u8L\(\)', 'get_convex_hull_shared_ptr()'),
    # optp_u8L -> optptr
    (r'optp_u8L', 'optptr'),
    # mesh_p_u8L -> mesh_ptr
    (r'mesh_p_u8L\(\)', 'mesh_ptr()'),
    # shared_p_u8L -> shared_ptr
    (r'shared_p_u8L\(\)', 'shared_ptr()'),
    # get_ptr -> p_u8L bad rename (from AnyPtr)
    (r'\bget_p_u8L\b', 'get_ptr'),
    # AnyP_u8L -> AnyPtr
    (r'\bAnyP_u8L\b', 'AnyPtr'),
    # clonable_p_u8L -> clonable_ptr
    (r'\bclonable_p_u8L\b', 'clonable_ptr'),
    # image_p_u8L -> image_ptr
    (r'\bimage_p_u8L\b', 'image_ptr'),
    # blinks_p_u8L -> blink_ptr? check original
    (r'\bblink_p_u8L\b', 'blink_ptr'),
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