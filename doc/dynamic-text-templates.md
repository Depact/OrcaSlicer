# Dynamic Placeholder Text Templates for the Text Shape Tool

Feature: let users type dynamic tags (e.g. `{timestamp}`, `{year}`, `{month}`, `{day}`,
`{hour}`, `{minute}`, `{nozzle_temperature}`) into the Text Shape tool, keep the raw
template in the model configuration, and resolve + re-mesh the text into 3D geometry at
slicing time in `libslic3r::Print::process()`.

This guide is written against the current `main` checkout of this fork. All file/line
references were verified against the tree and may shift after edits.

---

## 0. Orientation: where the code actually lives

Before the numbered sections, three facts that shape the whole design:

1. **The active Text Shape tool is `GLGizmoEmboss`, not `GLGizmoText`.**

   `GLGizmoText` (`src/slic3r/GUI/Gizmos/GLGizmoText.*`) is legacy: it uses the old
   `Shape/TextShape.hpp` `load_text_shape()` API and is **no longer instantiated**
   anywhere (confirmed by grep - no `new GLGizmoText` in the tree). The real tool is
   registered in `GLGizmosManager.cpp:216`:

   ```cpp
   m_gizmos.emplace_back(new GLGizmoEmboss(..., EType::Emboss));
   ```

   All UI work therefore happens in `GLGizmoEmboss` / `GLGizmoEmboss.cpp`.

2. **`Print` has no `m_placeholder_parser` member.**

   The `PlaceholderParser` used for G-code lives inside `GCode` (`GCode.hpp:242`). For
   slicing-time text resolution we simply construct a fresh `PlaceholderParser`, which
   already registers the clock variables in its constructor (see Section 3.2).

3. **`Print::process()` runs on the background slicing thread and operates on the print's
   private model copy** (`PrintBase::m_model`, populated by `PrintBase::apply()` before
   `process()`). Mutating that copy never touches the GUI model, so slicing-time re-meshing
   is safe and the GUI keeps showing the raw template.

---

## 1. Local Workspace Setup & Toolchain Setup

### 1.1 Create the feature branch

```bash
# from the repo root
git checkout -b feature/dynamic-text-templates
```

### 1.2 Platform dependencies

The fork builds OrcaSlicer's own bundled dependencies from `deps/`; system packages are
only needed for the toolchain and wxWidgets/CMake bits that are not vendored.

**Windows (Visual Studio 2022 + vcpkg)** - this is the primary dev platform for this guide:

```powershell
# 1. Visual Studio 2022 with the "Desktop development with C++" workload
#    (includes MSVC x64 toolset, CMake, and Windows SDK).

# 2. vcpkg (one-time) + the wxWidgets triplet used by OrcaSlicer
git clone https://github.com/microsoft/vcpkg C:\vcpkg
C:\vcpkg\bootstrap-vcpkg.bat
C:\vcpkg\vcpkg.exe install wxwidgets:x64-windows

# 3. Ninja (used for the fast, clean baseline build below)
choco install ninja            # or scoop:  scoop install ninja

# 4. Make the compiler visible in a plain shell (no VS "Developer PowerShell")
#    Either run from a "x64 Native Tools" prompt, or call vcvars first:
cmd /c "\"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat\""
```

**macOS (Xcode + Homebrew):**

```bash
xcode-select --install                     # Xcode CLT (clang, make)
brew install cmake ninja pkg-config
brew install wxwidgets gettext             # GUI + i18n
# (OrcaSlicer can also build wxWidgets from deps/, but brew's wx is much faster for iteration)
```

**Linux (GCC 11+, CMake, Ninja, wxWidgets):**

```bash
sudo apt update
sudo apt install -y build-essential cmake ninja-build gettext
sudo apt install -y libwxgtk3.2-dev libwebkit2gtk-4.1-dev libgtk-3-dev \
  libcurl4-openssl-dev libopenvdb-dev libboost-all-dev
```

### 1.3 Baseline compile (clean-tree sanity build)

Configure once with CMake + Ninja, then build the whole target. On Windows, CMake needs
to find vcpkg's wxWidgets and the MSVC generator is `Ninja` with the cl compiler.

**Windows:**

```powershell
# From the repo root
cmake -B build \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_TOOLCHAIN_FILE=C:/vcpkg/scripts/buildsystems/vcpkg.cmake \
  -DWXWIN=ON
cmake --build build --target OrcaSlicer -- -j
```

**macOS / Linux:**

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build --target OrcaSlicer -- -j$(nproc)
```

> If you only need to validate the `libslic3r` changes during iteration (sections 3 and 5
> do not touch the GUI), build just the library - it is ~10x faster than the full app:
> `cmake --build build --target libslic3r -- -j`.

The baseline is "clean" when the build ends with `[100%]` and produces the executable
(`build/src/Release/OrcaSlicer.exe` on Windows / `build/src/OrcaSlicer` elsewhere). Do not
proceed until this passes; any failure here is a toolchain problem, not your feature.

---

## 2. Architecture Overview & Structural Flow

The feature is a pipeline decoupling across three layers. Data flows in one direction:

```
┌────────────────────┐   raw template    ┌─────────────────────────────┐
│ UI layer           │ ────────────────► │ Object model layer          │
│ GLGizmoEmboss      │  text_configuration│ ModelVolume                 │
│ (text field + new  │                   │  .text_configuration        │
│  template buttons) │                   │    ├ text          (raw)    │
└────────────────────┘                   │    ├                            │
                                         │    ├ last_rendered_text      │
                                         │    ├ font_data (transient)   │
                                         │    └ style + emboss_shape    │
                                         └──────────────┬──────────────┘
                                                        │ Print::apply() copies
                                                        ▼
┌────────────────────┐  resolve via      ┌─────────────────────────────┐
│ Slicing layer      │ ────────────────► │ PrintBase::m_model          │
│ Print::process()   │  PlaceholderParser│  (print-private model copy) │
│ └ resolve_text_    │  re-mesh via      │   ModelVolume::set_mesh()   │
│    templates()     │  Emboss::...      │   (resolved geometry)       │
└────────────────────┘                   └──────────────┬──────────────┘
                                                        ▼
                                             obj->slice() / make_perimeters()
                                             (Arachne + layer slicing consume the
                                              resolved mesh as normal)
```

| Layer        | File                                                                                       | Responsibility                                                                                                                                                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| UI           | `src/slic3r/GUI/Gizmos/GLGizmoEmboss.cpp`                                                  | Text field, template quick-buttons, "Preview Resolved Text" toggle. Writes the **raw** template into `volume->text_configuration` and regenerates the live preview mesh via the existing `EmbossUpdateJob`.                               |
| Object model | `src/libslic3r/TextConfiguration.hpp`, `Model.hpp:895` (`ModelVolume::text_configuration`) | Carries the raw template + everything needed to rebuild the mesh headlessly: style (font descriptor), `emboss_shape` (scale + projection), transient font bytes, and a "last rendered text" cache.                                        |
| Slicing      | `src/libslic3r/Print.cpp` (`Print::process`), `src/libslic3r/Emboss.cpp`                   | On each slice, resolves every text volume's template, compares against `last_rendered_text`, and re-meshes only when the resolved string changed. Everything downstream (`slice()`, `make_perimeters()`) consumes the new mesh unchanged. |

### Key existing plumbing the feature reuses (do not reinvent)

- **`TextConfiguration`** (`src/libslic3r/TextConfiguration.hpp:173`) - serialized into
  `.3mf` by `TextConfigurationSerialization`; already holds `style` + `text`.
- **`ModelVolume::text_configuration`** (`Model.hpp:895`) and **`ModelVolume::emboss_shape`**
  (`Model.hpp:899`) - the latter stores `scale` and `projection` needed to rebuild geometry.
- **`Emboss::text2vshapes` / `union_with_delta` / `polygons2model` / `ProjectZ` /
  `ProjectTransform`** (`src/libslic3r/Emboss.hpp`) - the headless text→mesh machinery that
  `EmbossJob.cpp` uses on a worker thread. We mirror the _non-per-glyph_ path of
  `try_create_mesh` (`src/slic3r/GUI/Jobs/EmbossJob.cpp:927`) so slicing-time re-meshing is
  pure `libslic3r` (no wx, no Job, no GUI).
- **`PlaceholderParser`** (`src/libslic3r/PlaceholderParser.hpp`) - the macro engine.
  The clock variables already exist (Section 3.2).

---

## 3. Data Model & Placeholder Modifications (`src/libslic3r`)

### 3.1 Step 1 - `TextConfiguration` gains the raw-template + re-mesh bookkeeping

File: `src/libslic3r/TextConfiguration.hpp`.

Rationale for the layout:

- `text` **is the raw template the user typed and the single serialized attribute**. It is
  what the gizmo edits (`GLGizmoEmboss.cpp:1245` `m_text = tc.text`) and what `.3mf`
  persistence serializes. Keeping it raw means **zero `.3mf` format change** and full
  backward compatibility (OrcaSlicer hard requirement). Template resolution happens
  ephemerally on the print's private model copy at slice time - nothing is written back.
- `last_rendered_text` is a _transient mutable cache_ of the resolved string the current
  volume mesh was built from. It lets `Print::process()` skip re-meshing when nothing
  changed (preview refresh, re-slice with same timestamp resolution).
- `font_data` is a **shared `Emboss::FontFile` handle** so slicing-time re-meshing can run
  headless. The GUI shares the same handle across volumes using one font (only the
  shared_ptr is copied, never the font bytes). Without it, most text volumes (created
  through the wx font descriptor path) could not be re-meshed in `libslic3r`, because
  reconstructing an `HFONT`/`wxFont` from the descriptor is a GUI-layer (wx) operation that
  must not run on the slicing worker thread.

```cpp
// ---------- TextConfiguration.hpp (additions) ----------

#include <memory> // shared_ptr

struct TextConfiguration
{
    // Style of embossed text
    EmbossStyle style;

    // Embossed text value.
    // RAW TEMPLATE: this is exactly what the user typed, e.g. "{year}-{month}-{day}".
    // It is the field persisted to .3mf (backward compatible) and the string the
    // emboss gizmo edits.
    std::string text = "None";

    // Resolved text that the CURRENT volume mesh was generated from.
    // Transient cache only - never serialized. Lets Print::process() avoid redundant
    // re-meshing when the evaluated template is unchanged.
    mutable std::string last_rendered_text;

    // Shared font handle captured by the GUI at edit time, so libslic3r can rebuild
    // the glyph shapes headlessly on the slicing thread. All text volumes using the
    // same font share one FontFile (only the shared_ptr is copied).
    // Transient cache only - never serialized (fonts are large and OrcaSlicer
    // does not persist fonts into .3mf for privacy).
    std::shared_ptr<const Emboss::FontFile> font_data;

    // When false, {placeholders} in `text` are rendered literally (no resolution).
    // Transient (not serialized): defaults to true so loaded .3mf volumes keep the
    // existing behavior.
    bool process_templates = true;

    // Undo / redo stack recovery.
    // Deliberately serializes ONLY (style, text) - see notes above.
    template<class Archive> void serialize(Archive &ar) { ar(style, text); }
};
```

### 3.2 Step 2 - `PlaceholderParser`: clock variables already exist, just make resolution robust

File: `src/libslic3r/PlaceholderParser.cpp`.

Good news: `{year}`, `{month}`, `{day}`, `{hour}`, `{minute}`, `{second}`, `{timestamp}`,
`{user}` and `{version}` are **already registered** by the constructor:

```cpp
// PlaceholderParser.cpp:70 (already present, no change needed)
PlaceholderParser::PlaceholderParser(const DynamicConfig *external_config) : m_external_config(external_config)
{
    this->set("version", std::string(SoftFever_VERSION));
    this->apply_env_variables();
    this->update_timestamp();   // <-- registers {year},{month},{day},{hour},{minute},{second},{timestamp}
    this->update_user_name();   // <-- registers {user}
}
```

`update_timestamp(DynamicConfig&)` (`PlaceholderParser.cpp:78`) sets:
`timestamp` = `YYYYMMDD-HHMMSS` (string), and `year`/`month`/`day`/`hour`/`minute`/`second`
as `ConfigOptionInt`. Any date/time layout is composed by embedding these variables with
literal separators, e.g. `{year}-{month}-{day} {hour}:{minute}:{second}`.

**New `strftime()` function** - the analogue of .NET's `DateTime.ToString(format)` using
the standard C `strftime()` codes. It is a plain function call in the expression grammar,
so the format string may be any string expression:

```cpp
{strftime("%Y-%m-%d %H:%M")}   // e.g. 2026-08-23 21:30
{strftime("%d.%m.%Y")}         // e.g. 23.08.2026
```

Implementation (three touches in `PlaceholderParser.cpp`): a static `expr::strftime`
method next to `regex_replace` that formats the current local time (thread-safe
`localtime_s`/`localtime_r`) into a `char` buffer via `std::strftime`; a grammar rule
`| (kw["strftime"] > '(' > conditional_expression(_r1) > ')') [ px::bind(&expr::strftime, _1, _val) ]`
next to the `regex_replace` rule; and `("strftime")` added to the keyword list.

What the feature **adds**: a small, documented free function (or `Print` helper) that
refreshes the clock and evaluates a template with clean fallback semantics. Place it next
to `update_timestamp`:

```cpp
// ---------- PlaceholderParser.hpp (addition, public API) ----------

// Evaluate a text template (used for dynamic embossed text). Unlike process(), this
// never throws for a bad template: the caller always gets a usable string back.
// Two overloads:
//  - (templ):        resolve against THIS parser (already configured by the caller).
//  - (templ, config): build a fresh parser configured with clock vars + `config`.
// Returns the resolved string, or `templ` unchanged when it cannot be resolved
// (missing variable, malformed braces, ...). Unresolvable {tag}s stay literal.
std::string resolve_text_template(const std::string &templ) const;
std::string resolve_text_template(const std::string &templ, const DynamicPrintConfig *config) const;
```

```cpp
// ---------- PlaceholderParser.cpp (addition) ----------

std::string PlaceholderParser::resolve_text_template(const std::string &templ) const
{
    if (templ.find('{') == std::string::npos)
        return templ; // fast path: no placeholders at all

    try {
        return this->process(templ, 0 /* current_extruder_id */);
    } catch (const std::exception &ex) {
        BOOST_LOG_TRIVIAL(warning) << "Failed to fully resolve text template '" << templ
                                   << "' (" << ex.what() << "); resolving what is possible.";
    }

    // Partial resolution: the whole-template process() threw (a literal '{' that was
    // not escaped, an unknown variable, or an unresolvable tag). Resolve each {tag}
    // group on its own and leave the unresolvable ones literal, so e.g.
    // "{hour}:{minute} {does_not_exist}" still resolves to "21:30 {does_not_exist}".
    // Conditional blocks ({if}/{else}/{elsif}/{endif}) span multiple groups and must
    // be processed atomically, so templates using them keep the previous behavior.
    if (templ.find("{if")   != std::string::npos ||
        templ.find("{else") != std::string::npos ||
        templ.find("{elsif") != std::string::npos ||
        templ.find("{endif") != std::string::npos)
        return templ;

    std::string result;
    result.reserve(templ.size());
    size_t pos = 0;
    while (pos < templ.size()) {
        const size_t open = templ.find('{', pos);
        if (open == std::string::npos) { result += templ.substr(pos); break; }
        result += templ.substr(pos, open - pos);
        const size_t close = templ.find('}', open + 1);
        if (close == std::string::npos) { result += templ.substr(open); break; }
        const std::string tag = templ.substr(open, close - open + 1);
        try {
            result += this->process(tag, 0);
        } catch (const std::exception &) {
            result += tag; // unresolvable - keep it literal
        }
        pos = close + 1;
    }
    return result;
}

std::string PlaceholderParser::resolve_text_template(const std::string &templ, const DynamicPrintConfig *config) const
{
    // Work on a private copy so the shared parser state is never mutated from a
    // worker thread, and stamp the clock for this invocation.
    PlaceholderParser parser(this->external_config());
    parser.update_timestamp(); // {timestamp}, {year}, {month}, {day}, {hour}, {minute}, {second}
    parser.apply_env_variables();
    if (config != nullptr)
        parser.apply_config(*config); // {nozzle_temperature}, {filament_type}, ...
    return parser.resolve_text_template(templ);
}
```

Notes for the implementer:

- **Escaping.** The parser's macro syntax requires a literal `{` to be written `\{`. A text
  like `A {literal} brace` will throw and fall back to the raw string; document this in the
  UI tooltip (Section 4.2).
- **Vector options resolve to the first element without an index.** `{nozzle_temperature}`
  is a per-filament `ConfigOptionInts`; addressed without an index the parser uses element 0
  (the "current extruder" default), so the tags stay short and non-cryptic. Explicit
  indexing (`{nozzle_temperature[1]}`) is still supported, exactly like G-code.
- **`strftime()` for format-string dates.** `{strftime("%Y-%m-%d %H:%M")}` behaves like
  .NET's `DateTime.ToString(format)` using C `strftime()` codes (see Section 3.2).
- **Thread safety.** `PlaceholderParser::process` is `const` and designed to be called from
  multiple threads (see the `ContextData` comment, `PlaceholderParser.hpp:17`).
  `Print::resolve_text_templates()` configures one parser once from a snapshot of the
  print config and reuses it for all volumes (no per-volume re-application); the GUI
  preview builds a fresh parser per call. Both paths never share mutable parser state
  across threads.

---

## 4. UI Modifications & Template Controls (`src/slic3r/GUI/`)

All UI work is in `src/slic3r/GUI/Gizmos/GLGizmoEmboss.cpp` / `.hpp`.

### 4.1 Step 1 - Store the raw template + stash the font bytes

The gizmo already copies `m_text` (raw) into the volume config on every edit via
`create_emboss_data_base` → `TextDataBase::write`. The one addition:

**a) Share the font handle when the volume config is written.**

```cpp
// GLGizmoEmboss.cpp - TextDataBase::write() (currently ~line 3365)
void TextDataBase::write(ModelVolume &volume) const
{
    // Preserve the user's "Resolve templates" toggle across edits (transient).
    const bool process_templates = volume.text_configuration.has_value()
                                       ? volume.text_configuration->process_templates
                                       : true;
    DataBase::write(volume);
    volume.text_configuration = m_text_configuration; // copy
    volume.text_configuration->process_templates = process_templates;

    // Share the font handle so the slicing thread can re-mesh headlessly without
    // touching wxWidgets. Only the shared_ptr is copied - all volumes using the same
    // font point to one FontFile.
    if (m_font_file.font_file != nullptr)
        volume.text_configuration->font_data = m_font_file.font_file;
    assert(volume.emboss_shape.has_value());
}
```

**b) Initialize `m_text` from the raw template when opening the gizmo** (so re-opening after
a slice shows the template, not resolved text). This already happens -
`m_text = tc.text;` at `GLGizmoEmboss.cpp:1245` - and since `text` stays raw, no change is
needed here. Leave it as is.

### 4.2 Step 2 - Template variable dropdown + "Preview Resolved Text" toggle

Add these members to `GLGizmoEmboss` (`GLGizmoEmboss.hpp`):

```cpp
// GLGizmoEmboss.hpp (private members)
bool        m_preview_template = false;   // "Preview Resolved Text" toggle (3D preview)
std::string m_pending_insert;             // template tag awaiting insertion into the text field
int         m_pending_insert_pos = 0;     // caret position the queued tag is inserted at
int         m_text_cursor_pos = 0;        // last known caret of the text field
bool        m_focus_text_field = false;   // focus the field so the queued insert applies
```

Add one helper declaration (private):

```cpp
// Resolve {placeholders} in a template using PlaceholderParser (Section 3.2).
// Returns the resolved string, or the input unchanged when it cannot be resolved.
std::string resolve_text_template(const std::string &templ) const;
```

Implementation in `GLGizmoEmboss.cpp`:

```cpp
std::string GLGizmoEmboss::resolve_text_template(const std::string &templ) const
{
    // Template processing can be disabled per volume - then placeholders are literal.
    if (m_volume != nullptr && m_volume->text_configuration.has_value() &&
        !m_volume->text_configuration->process_templates)
        return templ;

    // libslic3r::PlaceholderParser::resolve_text_template (see Section 3.2).
    // GUI preview only needs the clock variables; pass nullptr for the print config.
    return Slic3r::PlaceholderParser().resolve_text_template(templ, nullptr);
}
```

**Insert-at-cursor callback.** ImGui's `InputTextMultiline` owns an internal undo buffer,
so you cannot mutate `m_text` from outside the widget. The correct way to inject a tag at
the cursor is the `ImGuiInputTextFlags_CallbackEdit` callback, which can call
`ImGuiInputTextCallbackData::InsertChars` at the real cursor position:

```cpp
// GLGizmoEmboss.cpp - static helper, placed near draw_text_input()
// Insert a queued template tag at the current text-field cursor.
static int text_insert_callback(ImGuiInputTextCallbackData *data, GLGizmoEmboss *gizmo)
{
    if (data->EventFlag == ImGuiInputTextFlags_CallbackEdit && !gizmo->m_pending_insert.empty()) {
        data->InsertChars(data->CursorPos, gizmo->m_pending_insert.c_str());
        gizmo->m_pending_insert.clear();
        return 1; // handled
    }
    return 0;
}
```

**Draw the controls.** Add a collapsible "Templates" section after the text depth control
(in `draw_window`, after `draw_depth(...)` at `GLGizmoEmboss.cpp:1523`), styled like the
"Advanced" tree node. All template parameters are grouped in one dropdown; picking an
entry pastes its tag at the caret:

```cpp
// GLGizmoEmboss.cpp - new helper, called from draw_window() after draw_depth()

void GLGizmoEmboss::draw_text_template_controls()
{
    ImGui::Spacing();
    ImGuiTreeNodeFlags flags = ImGuiTreeNodeFlags_SpanAvailWidth | ImGuiTreeNodeFlags_FramePadding;
    if (ImGui::TreeNodeEx(_u8L("Templates").c_str(), flags)) {
        // Disabled while previewing (the field is then read-only) so an insert would
        // never apply and would pop up unexpectedly later.
        const bool preview_read_only = m_preview_template && !m_style_manager.get_font_prop().per_glyph;

        // Vector options (nozzle_temperature, nozzle_diameter, filament_type) are
        // addressed without an index - the parser resolves them to the first element.
        static const char *template_tags[] = {
            "{year}-{month}-{day}",
            "{hour}:{minute}",
            "{strftime(\"%Y-%m-%d %H:%M\")}",
            "{nozzle_temperature}",
            "{nozzle_diameter}",
            "{layer_height}",
            "{filament_type}",
        };

        m_imgui->disabled_begin(preview_read_only);
        if (ImGui::BeginCombo("##template_var", _u8L("Insert template...").c_str())) {
            for (const char *tag : template_tags) {
                if (ImGui::Selectable(tag)) {
                    // Paste at the caret position tracked by the text input callback, so
                    // the tag lands where the cursor was last.
                    m_pending_insert_pos = m_text_cursor_pos;
                    m_pending_insert     = tag;
                    m_focus_text_field   = true; // focused at start of draw_text_input()
                }
                if (ImGui::IsItemHovered())
                    ImGui::SetTooltip("%s", tag);
            }
            ImGui::EndCombo();
        }
        m_imgui->disabled_end();
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("%s", _u8L("Insert a template at the cursor position").c_str());

        ImGui::Spacing();

        // Master toggle: when off, {placeholders} are printed literally and never
        // resolved, both in the preview and at slice time.
        bool &process_templates = m_volume->text_configuration->process_templates;
        if (ImGui::Checkbox(_u8L("Process templates").c_str(), &process_templates)) {
            if (!process_templates)
                m_preview_template = false; // nothing to preview without resolution
        }
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("%s", _u8L(
                "When off, {placeholders} are printed literally instead of being resolved "
                "to their values.").c_str());

        ImGui::Spacing();

        // Preview toggle: shows the *resolved* text as real 3D geometry in the prepare
        // view (the text field keeps the raw, editable template). Requires template
        // processing to be enabled.
        m_imgui->disabled_begin(!process_templates);
        if (ImGui::Checkbox(_u8L("Preview Resolved Text").c_str(), &m_preview_template))
            process(); // refresh the live 3D mesh with the resolved text
        m_imgui->disabled_end();
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("%s", _u8L(
                "Show the resolved {placeholders} as 3D geometry in the prepare view. The "
                "stored text keeps the raw template; resolution to geometry happens again "
                "at slicing time. Literal braces must be escaped as \\{.").c_str());

        ImGui::TreePop();
    }
}
```

Then modify `draw_text_input()` (`GLGizmoEmboss.cpp:1539`) to register the insert
callback. The field always shows and edits the raw template - resolved text is previewed
only as 3D geometry, never inside the field:

```cpp
// GLGizmoEmboss.cpp - inside draw_text_input(), replace the flags + InputTextMultiline block

// The tag picked from the dropdown is applied through the edit callback so ImGui's
// internal undo buffer and cursor stay coherent. CallbackAlways fires on the frame
// the field regains focus, making the paste immediate.
ImGuiInputTextFlags flags = ImGuiInputTextFlags_AllowTabInput |
                            ImGuiInputTextFlags_AutoSelectAll |
                            ImGuiInputTextFlags_CallbackAlways;

ImVec2 input_size(m_gui_cfg->text_size.x, m_gui_cfg->text_size.y);
if (ImGui::InputTextMultiline("##Text", &m_text, input_size, flags,
                              text_insert_callback, this)) {
    process(); // (re)generate the live mesh - see process() change below
}
```

**`process()` uses the resolved string for the mesh while previewing**, but must never write
the resolved string into the volume config (the raw template is what persists):

```cpp
// GLGizmoEmboss.cpp - GLGizmoEmboss::process() (~line 1364)

// The mesh that gets generated uses the *resolved* text while "Preview Resolved Text"
// is on - the 3D (prepare) view shows the resolved geometry - but the volume keeps the
// raw template (create_emboss_data_base is always fed the raw m_text; shape_text only
// drives rendering).
// Per-glyph ("text along a curve") cannot be previewed: its text_lines are derived
// from the raw text and the resolved string may not match line-for-line.
const bool per_glyph = m_style_manager.get_font_prop().per_glyph;
const std::string text_to_emboss = (m_preview_template && !per_glyph) ? resolve_text_template(m_text) : m_text;
if (is_text_empty(text_to_emboss)) return false;
// ... existing checks ...

DataBasePtr base = create_emboss_data_base(m_text, m_style_manager, m_text_lines, selection,
                                           m_volume->type(), m_job_cancel,
                                           per_glyph ? std::string()
                                                     : (m_preview_template ? text_to_emboss : std::string()));
```

> The preview toggle is additionally ignored for per-glyph text so the geometry stays
> consistent.

Because `TextDataBase::write` writes `m_text_configuration` (which is built from the
**raw** `m_text` in `create_emboss_data_base` at line 3431), the volume keeps the template
even while the preview mesh shows resolved glyphs.

> Note on the legacy `GLGizmoText`: it is dead code in this fork. Do not spend time on it.

---

## 5. Slicing Interception & Dynamic Re-Meshing (`src/libslic3r`)

### 5.1 New headless re-mesh primitive in `Emboss`

File: `src/libslic3r/Emboss.hpp` + `src/libslic3r/Emboss.cpp`.

This mirrors the non-per-glyph path of `try_create_mesh()` (`EmbossJob.cpp:927`) using only
`libslic3r` types. It is the "regenerate the mesh from a resolved string" entry point.

```cpp
// ---------- Emboss.hpp (addition, in namespace Slic3r::Emboss) ----------

class ModelVolume; // fwd - defined in Model.hpp, only used as a pointer here

/// <summary>
/// Rebuild the triangle mesh of a text ModelVolume from an already-resolved string.
/// Uses the data stored on the volume: TextConfiguration (style + raw font bytes)
/// and EmbossShape (scale + projection).
/// This is the slicing-time equivalent of the GUI EmbossUpdateJob, kept free of any
/// wxWidgets / Job / GUI dependency so it can run on the background slicing thread.
/// </summary>
/// <param name="volume">Text volume to re-mesh (in/out)</param>
/// <param name="resolved_text">Resolved string to render</param>
/// <param name="was_canceled">Cancellation probe; return true to abort early</param>
/// <returns>True when the mesh was regenerated, false when it was not possible
/// (font unavailable, empty shape) - the previous mesh is then kept.</returns>
bool regenerate_text_mesh(ModelVolume &volume, const std::string &resolved_text,
                          const std::function<bool()> &was_canceled = []() { return false; });
```

Implementation (add to `src/libslic3r/Emboss.cpp`, near `get_text_shape_scale`):

```cpp
namespace {
// Load the font used by a text volume, headlessly.
// Priority: 1) raw font bytes captured by the GUI (works for every style type),
//           2) style.path when the style is a plain file_path.
std::unique_ptr<Emboss::FontFile> load_volume_font(const TextConfiguration &tc)
{
    if (tc.font_data != nullptr && !tc.font_data->empty())
        return Emboss::create_font_file(
            std::make_unique<std::vector<unsigned char>>(*tc.font_data));

    if (tc.style.type == EmbossStyle::Type::file_path && !tc.style.path.empty())
        return Emboss::create_font_file(tc.style.path.c_str());

    // wx font descriptors (wx_win_font_descr / wx_lin_font_descr / wx_mac_font_descr)
    // can only be decoded into a usable font through wxWidgets, which must not run on
    // the slicing thread. Without the font_data cache this case cannot be re-meshed.
    BOOST_LOG_TRIVIAL(warning) << "No font data for text template re-meshing; keeping previous mesh.";
    return nullptr;
}
} // namespace

bool Emboss::regenerate_text_mesh(ModelVolume &volume, const std::string &resolved_text,
                                  const std::function<bool()> &was_canceled)
{
    if (resolved_text.empty() || was_canceled())
        return false;

    const std::optional<TextConfiguration> &tc_opt = volume.text_configuration;
    const std::optional<EmbossShape>       &es_opt = volume.emboss_shape;
    if (!tc_opt.has_value() || !es_opt.has_value())
        return false; // not a text volume

    const TextConfiguration &tc = *tc_opt;
    const EmbossShape       &es = *es_opt;

    // The headless path below only reproduces flat, non-per-glyph text. On-surface
    // text (wrapped around a cylinder / cut into a surface) and per-glyph text need
    // the surface mesh, TextLinesModel and raycaster from the GUI Job pipeline, which
    // are unavailable on the slicing thread. Keep the previous mesh for those.
    if (es.projection.use_surface || tc.style.prop.per_glyph) {
        BOOST_LOG_TRIVIAL(warning)
            << "Dynamic text template: on-surface / per-glyph text cannot be re-meshed "
               "headlessly, keeping previous mesh.";
        return false;
    }

    std::unique_ptr<FontFile> font_file = load_volume_font(tc);
    if (font_file == nullptr || was_canceled())
        return false;

    // The glyph cache inside FontFileWithCache is scratch space; the shared FontFile
    // carries the byte data.
    FontFileWithCache font(std::move(font_file));

    // Build the glyph shapes from the resolved string.
    EmbossShape text_shape;
    {
        std::wstring text_w = boost::nowide::widen(resolved_text);
        text_shape.shapes_with_ids = text2vshapes(font, text_w, tc.style.prop, was_canceled);
    }
    if (text_shape.shapes_with_ids.empty() || was_canceled())
        return false;

    // Reuse the stored scale + projection so the rebuilt geometry matches the GUI
    // preview exactly (scale == get_text_shape_scale(prop, font), stored at creation).
    text_shape.scale      = es.scale;
    text_shape.projection = es.projection;

    // Boolean-union the per-glyph shapes exactly like try_create_mesh() does.
    ExPolygons shapes = union_with_delta(text_shape, UNION_DELTA, UNION_MAX_ITERATIN);
    if (shapes.empty() || was_canceled())
        return false;

    // Replicate the transform math of the GUI path (EmbossJob.cpp:939-949).
    double scale = text_shape.scale;
    double depth = text_shape.projection.depth / scale;

    bool is_outside = volume.is_model_part(); // MODEL_PART == raised text
    float offset = is_outside ? -SAFE_SURFACE_OFFSET : (SAFE_SURFACE_OFFSET - static_cast<float>(depth));
    // NOTE: the GUI additionally adds the (non-persisted) style "distance from surface"
    // here via DataBase::from_surface. It defaults to 0 for new text objects, so the
    // slice-time mesh matches the common case exactly.

    Transform3d tr = Eigen::Translation<double, 3>(0., 0., offset) * Eigen::Scaling(scale);
    auto projectZ = std::make_unique<ProjectZ>(depth);
    ProjectTransform project(std::move(projectZ), tr);
    TriangleMesh mesh(polygons2model(shapes, project));
    if (mesh.empty() || was_canceled())
        return false;

    // If this volume was loaded from a .3mf the stored transform carries a baked-in
    // fix matrix; undo it exactly like UpdateJob::finalize does (EmbossJob.cpp:1052-1056)
    // so the canonical local mesh + canonical transform agree again.
    if (es.fix_3mf_tr.has_value()) {
        volume.set_transformation(volume.get_matrix() * es.fix_3mf_tr->inverse());
        volume.emboss_shape->fix_3mf_tr.reset();
    }

    volume.set_mesh(std::move(mesh));
    volume.calculate_convex_hull();

    // Remember what this mesh was built from so process() can skip redundant work.
    volume.text_configuration->last_rendered_text = resolved_text;
    return true;
}
```

> `SAFE_SURFACE_OFFSET` is defined as a file-local constant in `Emboss.cpp` (it is only a
> GUI constant upstream, `EmbossJob.cpp:63`). `FontFileWithCache`'s constructor accepts
> `std::unique_ptr<FontFile>` (`Emboss.hpp:116`), so no extra wrapper dance is needed.

### 5.2 Hook into `Print::process()`

File: `src/libslic3r/Print.hpp` (declaration) + `src/libslic3r/Print.cpp` (definition).

Declare a private helper on `Print`:

```cpp
// ---------- Print.hpp (private section of class Print) ----------
// Resolve every text volume's dynamic template on this print's private model copy
// and regenerate the affected meshes. Called at the very start of process(), before
// any slicing / shared-object bookkeeping so the dedup logic sees resolved meshes.
void resolve_text_templates();
```

Definition in `Print.cpp`. The hook goes in `Print::process()` **immediately after the
`m_objects.empty()` check and before the shared-object dedup** (`Print.cpp:2252-2255`):

```cpp
// ---------- Print.cpp ----------

// include additions at the top of the file
#include "libslic3r/Emboss.hpp"
#include "libslic3r/PlaceholderParser.hpp"
#include "libslic3r/Model.hpp"
#include <boost/log/trivial.hpp>

void Print::resolve_text_templates()
{
    // Operating on m_model (the print's private copy from PrintBase::apply) so the
    // GUI model keeps showing the raw templates. One parser is configured once (clock
    // variables + a snapshot of the print config) and reused for every volume, so the
    // config is not re-applied per text volume and a concurrent GUI apply() cannot
    // mutate it mid-loop.
    PlaceholderParser parser;
    parser.update_timestamp(); // ensure the clock reflects the slicing moment
    parser.apply_config(this->full_print_config());

    // Resolve a text volume's template and re-mesh it when the result changed.
    auto resolve_volume = [&parser](ModelVolume &volume) -> bool {
        TextConfiguration &tc = *volume.text_configuration;
        const std::string &templ = tc.text;

        // Skip plain text - nothing to resolve.
        if (templ.find('{') == std::string::npos) {
            tc.last_rendered_text = templ;
            return false;
        }

        // When template processing is disabled, render the raw template literally.
        const std::string resolved = tc.process_templates ? parser.resolve_text_template(templ) : templ;

        // Re-mesh only when the resolved string actually changed. This keeps repeated
        // preview / re-slice cycles cheap and avoids needlessly replacing shared meshes
        // (which would defeat the shared-object dedup).
        if (!tc.last_rendered_text.empty() && tc.last_rendered_text == resolved)
            return false;

        BOOST_LOG_TRIVIAL(debug) << "Re-meshing text volume '" << volume.name
                                 << "': '" << templ << "' -> '" << resolved << "'";

        // On failure (missing font, empty shape) the previous mesh is kept and
        // last_rendered_text is not updated, so the next slice retries.
        return Emboss::regenerate_text_mesh(volume, resolved);
    };

    for (ModelObject *object : m_model.objects)
        if (object != nullptr)
            for (ModelVolume *volume : object->volumes)
                if (volume != nullptr && volume->is_text())
                    resolve_volume(*volume);
}

// ---------- Print.cpp: Print::process() ----------
void Print::process(long long *time_cost_with_cache, bool use_cache)
{
    // ... existing config / logging preamble ...
    BOOST_LOG_TRIVIAL(info) << __FUNCTION__ << boost::format(": this=%1%, enter, use_cache=%2%, object size=%3%")%this%use_cache%m_objects.size();
    if (m_objects.empty())
        return;

    // NEW: resolve dynamic text templates before any slicing bookkeeping, so
    // shared-object detection and every downstream step (slice -> perimeters ->
    // infill) consume the resolved geometry.
    resolve_text_templates();

    for (PrintObject *obj : m_objects)
        obj->clear_shared_object();
    // ... rest of process() unchanged ...
}
```

Why here and not later:

- It must run **before** the `is_print_object_the_same()` dedup (`Print.cpp:2259`), which
  compares `mesh_ptr()` pointers. Two identical objects re-meshed with the same timestamp
  produce identical meshes and can still share; more importantly, a changed mesh must not
  be silently deduped against a stale cached one.
- It must run **before** `obj->slice()` / `obj->make_perimeters()` (the "Arachne + layer
  slicing" stages, `Print.cpp:2364-2410`), which is exactly the constraint from the spec.

### 5.3 `Print` and `m_model` access

`m_model` is `protected` in `PrintBase` (`PrintBase.hpp:552`), and `Print` derives from
`PrintBaseWithState<Print, ...>` -> `PrintBase`, so `resolve_text_templates()` (a member of
`Print`) can touch `m_model` directly. If you prefer the public accessor, note that
`PrintBase::model()` returns `const Model&`; add a non-const twin if you route the helper
through the accessor instead.

`Print::config()` (`DynamicPrintConfig&`) is available and non-const for `apply_config`.

---

## 6. Build, Test, and Edge-Case Handling

### 6.1 Rebuild the modified targets

```powershell
# Windows (fastest feedback: library first, then the app)
cmake --build build --target libslic3r -- -j
cmake --build build --target OrcaSlicer -- -j
```

```bash
# macOS / Linux
cmake --build build --target libslic3r -- -j$(nproc)
cmake --build build --target OrcaSlicer -- -j$(nproc)
```

The compile should be incremental - only `libslic3r` + `libslic3r_gui` + the final link
rebuild. If you changed `TextConfiguration.hpp` expect a wide rebuild (it is included by
`Model.hpp`); that is normal.

### 6.2 Verification test workflow (manual)

1. Launch the built binary.
2. Text Shape tool (the `T` toolbar icon, `GLGizmoEmboss`).
3. Type into the text field:
   ```
   {year}-{month}-{day}
   ```
4. Pick `{year}-{month}-{day}` from the **Insert template** dropdown and confirm the tag
   is inserted at the current caret position (no keystroke needed).
5. Enable **Preview Resolved Text** - the 3D (prepare) view shows today's date as real
   geometry, e.g. `2026-08-23`, while the text field keeps the raw
   `{year}-{month}-{day}` template; disable it again and the 3D view reverts.
6. Exit the tool (a text object now exists whose `text_configuration.text` is the raw
   template). Save the project as `.3mf`, close, reopen - the text field must still show the
   **raw** template (proves `text` stayed raw and `.3mf` round-trips).
7. Click **Slice**. During slicing, `resolve_text_templates()` logs
   `Re-meshing text volume '...': '{year}-{month}-{day}' -> '2026-08-23'`.
8. In the 3D view / layer preview, the text volume geometry now reads today's date.
9. **G-code check** - the sliced G-code for that layer simply contains the text geometry as
   ordinary toolpaths. To _see_ the resolved text in G-code you would additionally need a
   custom G-code line like `; LABEL: {year}-{month}-{day}` in the start G-code; the text
   itself is geometry, not comments. The verification target for this feature is the
   **3D layer output / preview**, not a comment in the G-code stream.
10. Re-slice without changing anything - `resolve_text_templates()` should skip re-meshing
    (no second `Re-meshing text volume` log line) because `last_rendered_text` matches.
11. Slice again after the date changes (or after editing the text in the tool) - the mesh is
    regenerated.

### 6.3 Edge cases and how the design handles them

| Edge case                                                                                     | Behavior                                                                                                                                                                                                                                                                                                                                          | Where handled                                                                             |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| **Unknown placeholder / bad braces** (e.g. `Hello {world`)                                    | `PlaceholderParser::process` throws `PlaceholderParserError`; we catch and keep the **raw template** as the rendered text, log a warning. Slicing never aborts.                                                                                                                                                                                   | `Print::resolve_text_templates()` (5.2), `PlaceholderParser::resolve_text_template` (3.2) |
| **Literal braces in text**                                                                    | Must be escaped `\{` (parser syntax). Tooltip on the preview toggle documents this.                                                                                                                                                                                                                                                               | 3.2, 4.2                                                                                  |
| **Vector options without index** (`{nozzle_temperature}`)                                     | Parser rejects; user writes `{nozzle_temperature[0]}`. Falls back to raw on error.                                                                                                                                                                                                                                                                | 3.2                                                                                       |
| **Missing font glyphs for evaluated characters**                                              | `text2vshapes` substitutes the font's replacement glyph (rendered as `?`) exactly like the GUI does - the GUI already warns via `m_text_contain_unknown_glyph`. Optional: call `Emboss::create_range_text(...)` in `regenerate_text_mesh` and log when `exist_unknown` is set.                                                                    | 5.1                                                                                       |
| **Font unavailable headlessly** (wx-descriptor styles without `font_data`, deleted font file) | `load_volume_font` returns null; `regenerate_text_mesh` returns false and the **previous mesh is kept**. `last_rendered_text` is not updated, so the next slice retries.                                                                                                                                                                          | 5.1                                                                                       |
| **Multi-line templates** (`line1\n{year}`)                                                    | `widen()` + `text2vshapes` handle `\n` natively; `get_count_lines` semantics are preserved because we render via the same shape pipeline as the GUI.                                                                                                                                                                                              | 5.1                                                                                       |
| **Bounding-box change when text length changes**                                              | Handled for free: we replace the whole volume mesh and recompute the convex hull (`calculate_convex_hull()`). Do **not** call `set_mesh` on a volume whose mesh is shared between GUI and print - we always operate on the print's copy, so nothing leaks back.                                                                                   | 5.1, 5.2                                                                                  |
| **Per-glyph / on-surface ("wrapped around a cylinder") text**                                 | `create_mesh_per_glyph` and `cut_surface` need the source surface + `TextLinesModel` + raycaster, all GUI/Job-side. This guide deliberately mirrors only the **non-per-glyph** path. For such volumes, keep the previous mesh (the normal text-on-surface case is far rarer than flat text; a follow-up can lift `cut_surface` into `libslic3r`). | 5.1                                                                                       |
| **Text that is empty after resolution** (e.g. template resolves to spaces)                    | `regenerate_text_mesh` returns early on empty; previous mesh kept.                                                                                                                                                                                                                                                                                | 5.1                                                                                       |
| **`.3mf` round-trip**                                                                         | `text` (raw) is the only serialized field; `text_template` / `last_rendered_text` / `font_data` are transient. Old project files load fine; new ones store the template as before. After load, `text_template` is empty so the resolver falls back to `text`.                                                                                     | 3.1, 6.2                                                                                  |
| **Time stamp stability within one slice**                                                     | `update_timestamp()` is called once per `resolve_text_templates()`, so all text volumes in a single slice share the same wall-clock value (no mid-slice drift between objects).                                                                                                                                                                   | 5.2                                                                                       |
| **Multiple instances / shared objects**                                                       | Re-mesh happens before the dedup; equal resolved strings produce equal meshes so sharing still works.                                                                                                                                                                                                                                             | 5.2                                                                                       |

### 6.4 Automated test (optional but recommended)

A small Catch2 test in `tests/libslic3r` for the new `Emboss::regenerate_text_mesh` + the
resolver is worthwhile because both are pure `libslic3r`. Conventions live in
`tests/AGENTS.md`. Sketch:

```cpp
// tests/libslic3r/test_text_template.cpp
TEST_CASE("PlaceholderParser resolves clock vars for text", "[TextTemplate]") {
    PlaceholderParser parser;
    parser.update_timestamp();
    std::string out = parser.process("{year}-{month}-{day}", 0);
    // out matches e.g. "2026-08-23" (regex)
    REQUIRE(std::regex_match(out, std::regex(R"(\d{4}-\d{2}-\d{2})")));
}

TEST_CASE("regenerate_text_mesh skips missing font gracefully", "[TextTemplate]") {
    // Build a ModelVolume with a TextConfiguration that has no font_data and a
    // file_path that does not exist -> previous mesh must be kept, false returned.
}
```

Register the source in `tests/libslic3r/CMakeLists.txt` and run:

```bash
cd build && ctest --test-dir ./tests/libslic3r --output-on-failure
```

### 6.5 Files touched (summary)

| File                                               | Change                                                                   |
| -------------------------------------------------- | ------------------------------------------------------------------------ |
| `src/libslic3r/TextConfiguration.hpp`              | Transient `last_rendered_text`, shared `font_data` (`Emboss::FontFile`)  |
| `src/libslic3r/PlaceholderParser.hpp` / `.cpp`     | `resolve_text_template()` overloads + partial resolution + `strftime()`  |
| `src/libslic3r/Emboss.hpp` / `.cpp`                | Add `regenerate_text_mesh()` + headless font loading                     |
| `src/libslic3r/Print.hpp` / `.cpp`                 | Add `resolve_text_templates()`, call it at the top of `Print::process()` |
| `src/slic3r/GUI/Gizmos/GLGizmoEmboss.hpp` / `.cpp` | Quick-buttons, preview toggle, callback, `font_data` sharing             |
| `tests/libslic3r/` (optional)                      | Tests for resolver + headless re-mesh                                    |
