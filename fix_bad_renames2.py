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
    # set_layer_tools_p_u8L -> set_layer_tools_ptr
    (r'set_layer_tools_p_u8L', 'set_layer_tools_ptr'),
    # get_ignored_contours_p_u8L -> get_ignored_contours_ptr
    (r'get_ignored_contours_p_u8L', 'get_ignored_contours_ptr'),
    # raycaster_p_u8L -> raycaster_ptr
    (r'raycaster_p_u8L', 'raycaster_ptr'),
    # png_get_io_p_u8L -> png_get_io_ptr
    (r'png_get_io_p_u8L', 'png_get_io_ptr'),
    # boost::weak_p_u8L -> boost::weak_ptr
    (r'boost::weak_p_u8L', 'boost::weak_ptr'),
    # decoded.p_u8L -> decoded.ptr
    (r'decoded\.p_u8L\(', 'decoded.ptr('),
    # get_custom_ctrl_with_blinking_p_u8L -> get_custom_ctrl_with_blinking_ptr
    (r'get_custom_ctrl_with_blinking_p_u8L', 'get_custom_ctrl_with_blinking_ptr'),
    # get_blink_p_u8L -> get_blink_ptr
    (r'get_blink_p_u8L', 'get_blink_ptr'),
    # immutable_object_p_u8L -> immutable_object_ptr
    (r'immutable_object_p_u8L', 'immutable_object_ptr'),
    # get_attribute_value_charp_u8L -> get_attribute_value_charptr
    (r'get_attribute_value_charp_u8L', 'get_attribute_value_charptr'),
    # bbs_get_attribute_value_charp_u8L -> bbs_get_attribute_value_charptr
    (r'bbs_get_attribute_value_charp_u8L', 'bbs_get_attribute_value_charptr'),
    # m_p_u8L -> m_ptr
    (r'\bm_p_u8L\b', 'm_ptr'),
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