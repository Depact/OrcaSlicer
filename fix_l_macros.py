import re

# Fix PlaceholderParser.cpp
with open('src/libslic3r/PlaceholderParser.cpp', 'r', encoding='utf-8') as f:
    content = f.read()

# Replace L("...") with _u8L("...") for error messages
# Pattern: L("...") where it's used in throw_exception, throw_if_not_numeric, etc.
content = re.sub(r'\bL\("([^"]+)"\)', r'_u8L("\1")', content)

with open('src/libslic3r/PlaceholderParser.cpp', 'w', encoding='utf-8') as f:
    f.write(content)

print('Fixed PlaceholderParser.cpp')

# Fix CadDocument.cpp
with open('src/libslic3r/CAD/CadDocument.cpp', 'r', encoding='utf-8') as f:
    content = f.read()

# Change L("thread: ...") to _u8L("thread: ...")
content = re.sub(r'\bL\("([^"]+)"\)', r'_u8L("\1")', content)

# Also remove the explicit I18N::translate(why) call since _u8L already translates
content = content.replace('Slic3r::I18N::translate(why)', 'why')

with open('src/libslic3r/CAD/CadDocument.cpp', 'w', encoding='utf-8') as f:
    f.write(content)

print('Fixed CadDocument.cpp')

# Fix AppConfig.cpp
with open('src/libslic3r/AppConfig.cpp', 'r', encoding='utf-8') as f:
    content = f.read()

content = re.sub(r'\bL\("([^"]+)"\)', r'_u8L("\1")', content)

with open('src/libslic3r/AppConfig.cpp', 'w', encoding='utf-8') as f:
    f.write(content)

print('Fixed AppConfig.cpp')