#include "ColorPickerDialog.hpp"
#include "Widgets/WebViewHostDialog.hpp"
#include "Widgets/WebView.hpp"
#include <wx/dialog.h>
#include <wx/button.h>
#include <wx/stattext.h>
#include <wx/toplevel.h>
#include <wx/frame.h>
#include <wx/colour.h>
#include <wx/display.h>
#include <algorithm>
#include <cmath>
#include <wx/webview.h>

#include "GUI_App.hpp"
#include "GUI_Utils.hpp"
#include "slic3r/Utils/MacDarkMode.hpp"
#include "I18N.hpp"
#include "libslic3r/AppConfig.hpp"

#include <atomic>
#include <memory>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>
#include <wx/defs.h>
#include <wx/chartype.h>
#include <wx/event.h>
#include <wx/gdicmn.h>
#include <wx/sizer.h>
#include <wx/string.h>
#include <wx/window.h>

#ifdef __linux__
#include <gtk/gtk.h>
#endif


#include "libslic3r/Color.hpp"
#include <optional>
#include <variant>
#include <cstddef>
#include <stdexcept>
#include <set>
#include <string>
#include <map>
#include <array>
#include <charconv>
#include <system_error>

namespace Slic3r::GUI {

namespace {

struct ColorPickerFavoritesState {
    std::vector<ColorSelection> favorites;
    bool writable = true;
};

bool normalize_color(ColorRGBA& color, bool allow_alpha)
{
    for (int i = 0; i < 4; ++i)
        if (!std::isfinite(color[i]) || color[i] < 0.0f || color[i] > 1.0f)
            return false;
    if (!allow_alpha)
        color.a(1.0f);
    return true;
}

bool parse_color(const nlohmann::json& value, ColorRGBA& color)
{
    if (!value.is_string())
        return false;
    const std::string& hex = value.get_ref<const std::string&>();
    if (!can_decode_color(hex))
        return false;
    // decode_color accepts invalid hex digits, so validate before reusing it.
    for (std::size_t i = 1; i < hex.size(); ++i) {
        const char c = hex[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
            return false;
    }
    return decode_color(hex, color);
}

std::string rgba_hex(const ColorRGBA& color)
{
    constexpr char digits[] = "0123456789ABCDEF";
    std::string hex(9, '#');
    for (int i = 0; i < 4; ++i) {
        const unsigned int byte = static_cast<unsigned int>(std::lround(color[i] * 255.0f));
        hex[1 + 2 * i] = digits[byte >> 4];
        hex[2 + 2 * i] = digits[byte & 15];
    }
    return hex;
}

std::optional<ColorSelection> normalize_color_selection(const ColorSelection& selection, ColorPickerOptions options)
{
    ColorSelection normalized = selection;
    if (auto* solid = std::get_if<ColorRGBA>(&normalized)) {
        if (!normalize_color(*solid, options.allow_alpha))
            return std::nullopt;
    } else {
        auto& gradient = std::get<ColorGradient>(normalized);
        if (!options.allow_gradient || gradient.size() < 2 || gradient.size() > COLOR_PICKER_MAX_GRADIENT_COLORS)
            return std::nullopt;
        for (ColorRGBA& color : gradient)
            if (!normalize_color(color, options.allow_alpha))
                return std::nullopt;
    }
    return normalized;
}

std::optional<ColorSelection> color_selection_from_json(const nlohmann::json& value, ColorPickerOptions options)
{
    if (!value.is_object())
        return std::nullopt;
    const auto type = value.find("type");
    const auto colors = value.find("colors");
    if (type == value.end() || !type->is_string() || colors == value.end() || !colors->is_array())
        return std::nullopt;
    if (*type == "solid" && colors->size() == 1) {
        ColorRGBA solid;
        if (parse_color((*colors)[0], solid))
            return normalize_color_selection(solid, options);
    } else if (*type == "gradient" && options.allow_gradient && colors->size() >= 2 && colors->size() <= COLOR_PICKER_MAX_GRADIENT_COLORS) {
        ColorGradient gradient(colors->size());
        for (std::size_t i = 0; i < gradient.size(); ++i)
            if (!parse_color((*colors)[i], gradient[i]))
                return std::nullopt;
        return normalize_color_selection(gradient, options);
    }
    return std::nullopt;
}

nlohmann::json color_selection_to_json(const ColorSelection& selection)
{
    const auto normalized = normalize_color_selection(selection, {true, true});
    if (!normalized)
        throw std::invalid_argument("Invalid color selection channels");
    if (const auto* solid = std::get_if<ColorRGBA>(&*normalized))
        return {{"type", "solid"}, {"colors", {rgba_hex(*solid)}}};
    nlohmann::json colors = nlohmann::json::array();
    for (const ColorRGBA& color : std::get<ColorGradient>(*normalized))
        colors.push_back(rgba_hex(color));
    return {{"type", "gradient"}, {"colors", std::move(colors)}};
}

std::optional<std::vector<ColorSelection>> color_favorites_from_json(const nlohmann::json& values)
{
    if (!values.is_array() || values.size() > 24)
        return std::nullopt;
    std::vector<ColorSelection> favorites;
    favorites.reserve(values.size());
    std::set<std::string> seen;
    for (const auto& value : values) {
        const auto selection = color_selection_from_json(value, {true, true});
        if (!selection)
            return std::nullopt;
        if (seen.insert(color_selection_to_json(*selection).dump()).second)
            favorites.push_back(*selection);
    }
    return favorites;
}

std::optional<ColorSelection> legacy_color(const std::string& value)
{
    if (!value.empty() && value.front() == '#')
        return color_selection_from_json({{"type", "solid"}, {"colors", {value}}}, {false, true});

    // string_to_wxColor uses stoi without checking the consumed length or byte
    // range. Parse the actual color_to_string RGBA format strictly for migration.
    std::array<unsigned int, 4> bytes;
    std::size_t begin = 0;
    for (std::size_t i = 0; i < bytes.size(); ++i) {
        const auto comma = value.find(',', begin);
        if ((i < 3 && comma == std::string::npos) || (i == 3 && comma != std::string::npos))
            return std::nullopt;
        const auto end = comma == std::string::npos ? value.size() : comma;
        const auto parsed = std::from_chars(value.data() + begin, value.data() + end, bytes[i]);
        if (parsed.ec != std::errc{} || parsed.ptr != value.data() + end || bytes[i] > 255)
            return std::nullopt;
        begin = end + 1;
    }
    return ColorRGBA(static_cast<unsigned char>(bytes[0]), static_cast<unsigned char>(bytes[1]),
                     static_cast<unsigned char>(bytes[2]), static_cast<unsigned char>(bytes[3]));
}
bool save_color_picker_favorites(AppConfig& config, const nlohmann::json& values)
{
    if (config.has_section("color_picker") && config.get("color_picker", "version") != "1")
        return false;
    const auto favorites = color_favorites_from_json(values);
    if (!favorites)
        return false;
    nlohmann::json canonical = nlohmann::json::array();
    for (const auto& selection : *favorites)
        canonical.push_back(color_selection_to_json(selection));
    // set_section is a raw replacement and does not mark AppConfig dirty itself.
    config.set_section("color_picker", {{"version", "1"}, {"favorites", canonical.dump()}});
    config.set_dirty();
    config.save();
    return true;
}

ColorPickerFavoritesState load_color_picker_favorites(AppConfig& config)
{
    if (config.has_section("color_picker")) {
        if (config.get("color_picker", "version") != "1")
            return {{}, false};
        const auto values = nlohmann::json::parse(config.get("color_picker", "favorites"), nullptr, false);
        const auto favorites = color_favorites_from_json(values);
        return {favorites ? *favorites : std::vector<ColorSelection>{}, true};
    }

    nlohmann::json imported = nlohmann::json::array();
    for (const std::string& value_string : config.get_custom_color_from_config()) {
        const auto selection = legacy_color(value_string);
        if (!selection)
            continue;
        const auto value = color_selection_to_json(*selection);
        bool duplicate = false;
        for (const auto& existing : imported)
            if (existing == value) {
                duplicate = true;
                break;
            }
        if (!duplicate)
            imported.push_back(value);
        if (imported.size() == 24)
            break;
    }
    // Persist the version even for an empty import: clearing never reimports.
    save_color_picker_favorites(config, imported);
    return {*color_favorites_from_json(imported), true};
}

} // namespace

std::optional<ColorSelection> filament_color_picker_selection(const FilamentColorPickerValue& value)
{
    return color_selection_from_json({{"type", value.gradient ? "gradient" : "solid"}, {"colors", value.colors}}, {true, true});
}

ColorSelection filament_color_picker_initial(const FilamentColorPickerValue& value)
{
    if (const auto exact = filament_color_picker_selection(value))
        return *exact;
    if (!value.colors.empty()) {
        if (const auto primary = color_selection_from_json({{"type", "solid"}, {"colors", {value.colors.front()}}}, {false, true}))
            return *primary;
    }
    if (const auto primary = color_selection_from_json({{"type", "solid"}, {"colors", {value.primary}}}, {false, true}))
        return *primary;
    return ColorRGBA(0.f, 0.f, 0.f, 1.f);
}

FilamentColorPickerValue filament_color_picker_result(const ColorSelection& selection)
{
    // Keep legacy RGB spelling for opaque colors; retain RGBA for transparency.
    const auto canonical = color_selection_to_json(selection);
    FilamentColorPickerValue value;
    value.gradient = canonical.at("type") == "gradient";
    for (const auto& color : canonical.at("colors")) {
        auto hex = color.get<std::string>();
        if (hex.compare(7, 2, "FF") == 0) hex.resize(7);
        value.colors.push_back(std::move(hex));
    }
    return value;
}

bool filament_color_picker_changed(const ColorSelection& initial, const std::optional<ColorSelection>& result)
{
    // Compare encoded bytes, not ColorRGBA's tolerant floating point equality.
    // An unchanged seed also leaves unrepresentable multi-color data untouched.
    return result && color_selection_to_json(initial) != color_selection_to_json(*result);
}

namespace {

// Sidebar state lives in its own section: "color_picker" is replaced wholesale when favorites are
// saved, and its presence alone marks favorites as already migrated.
constexpr const char* COLOR_PICKER_UI_SECTION = "color_picker_ui";

// The page's own size in DIP (style.css): body padding 10 oneach side around the 330 x 360 picker, 
// and the 160px sidebar plus its 10px gap. Opening at this size means the
// first resize message from the page normally changes nothing, so the window doesn't jump.
constexpr int COLOR_PICKER_PAGE_WIDTH    = 330 + 2 * 10;
constexpr int COLOR_PICKER_PAGE_HEIGHT   = 360 + 2 * 10;
constexpr int COLOR_PICKER_SIDEBAR_WIDTH = 160 + 10;

// Palette ids are short lowercase words defined by the page (basic, orca, ral, gradient, ...).
bool valid_palette_id(const std::string& id)
{
    return !id.empty() && id.size() <= 32 &&
           std::all_of(id.begin(), id.end(), [](char c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'; });
}

// English palette names are stable translation keys; RAL codes stay in the page data.
nlohmann::json color_picker_ui_strings()
{
    return {
        {"Color Picker", TR("Color Picker")},
        {"Basic Colors", TR("Basic Colors")},
        // TRN: Keep the brand name "Orca" unchanged; translate only the palette descriptor.
        {"Orca Palette", TR("Orca Palette")},
        // TRN: Keep the standard/brand name "RAL" unchanged.
        {"RAL Classic", TR("RAL Classic")},
        {"Gradients", TR("Gradients")},
        {"Solid", TR_CONTEXT("Solid", "Color picker")},
        {"Gradient", TR("Gradient")},
        {"Gradient start", TR("Gradient start")},
        {"Gradient end", TR("Gradient end")},
        {"Gradient color", TR("Gradient color")},
        {"Add color", TR("Add color")},
        {"Remove color", TR("Remove color")},
        {"Saturation", TR("Saturation")},
        {"Original color", TR("Original color")},
        // TRN: Clicking the current color preview adds it to the saved favorites.
        {"Save current color", TR("Save current color")},
        {"Palettes", TR("Palettes")},
        {"Search colors", TR("Search colors")},
        {"Filter colors", TR("Filter colors")},
        {"No matching colors", TR("No matching colors")},
        {"Hex color", TR("Hex color")},
        {"Opacity", TR("Opacity")},
        {"Opacity percent", TR("Opacity percent")},
        {"Save color", TR("Save color")},
        {"Cancel", TR("Cancel")},
        {"OK", TR("OK")},
        {"Enter a complete hexadecimal color", TR("Enter a complete hexadecimal color")},
        {"Invalid input", TR("Invalid input")},
        {"Value is out of range.", TR("Value is out of range.")},
        {"The current multi-color selection is kept until you choose a different color.", TR("The current multi-color selection is kept until you choose a different color.")},
        {"Up to %d colors supported.", TR("Up to %d colors supported.")},
        {"Red", TR("Red")},
        {"Crimson", TR("Crimson")},
        {"Orange red", TR("Orange red")},
        {"Tomato", TR("Tomato")},
        {"Orange", TR("Orange")},
        {"Dark orange", TR("Dark orange")},
        {"Gold", TR("Gold")},
        {"Burly wood", TR("Burly wood")},
        {"Bisque", TR("Bisque")},
        {"Misty rose", TR("Misty rose")},
        {"Yellow", TR("Yellow")},
        {"Light yellow", TR("Light yellow")},
        {"Lemon chiffon", TR("Lemon chiffon")},
        {"Beige", TR("Beige")},
        {"Light golden rod yellow", TR("Light golden rod yellow")},
        {"Pale golden rod", TR("Pale golden rod")},
        {"Khaki", TR("Khaki")},
        {"Dark khaki", TR("Dark khaki")},
        {"Peach puff", TR("Peach puff")},
        {"Moccasin", TR("Moccasin")},
        {"Papaya whip", TR("Papaya whip")},
        {"Blanched almond", TR("Blanched almond")},
        {"Antique white", TR("Antique white")},
        {"Navajo white", TR("Navajo white")},
        {"Wheat", TR("Wheat")},
        {"Golden rod", TR("Golden rod")},
        {"Chocolate", TR("Chocolate")},
        {"Peru", TR("Peru")},
        {"Fire brick", TR("Fire brick")},
        {"Sienna", TR("Sienna")},
        {"Saddle brown", TR("Saddle brown")},
        {"Brown", TR("Brown")},
        {"Rosy brown", TR("Rosy brown")},
        {"Salmon", TR("Salmon")},
        {"Light salmon", TR("Light salmon")},
        {"Dark salmon", TR("Dark salmon")},
        {"Sandy brown", TR("Sandy brown")},
        {"Coral", TR("Coral")},
        {"Light coral", TR("Light coral")},
        {"Indian red", TR("Indian red")},
        {"Dark red", TR("Dark red")},
        {"Maroon", TR("Maroon")},
        {"Green yellow", TR("Green yellow")},
        {"Yellow green", TR("Yellow green")},
        {"Chartreuse", TR("Chartreuse")},
        {"Lawn green", TR("Lawn green")},
        {"Lime green", TR("Lime green")},
        {"Spring green", TR("Spring green")},
        {"Medium spring green", TR("Medium spring green")},
        {"Lime", TR("Lime")},
        {"Green", TR("Green")},
        {"Forest green", TR("Forest green")},
        {"Dark green", TR("Dark green")},
        {"Olive drab", TR("Olive drab")},
        {"Olive", TR("Olive")},
        {"Dark olive green", TR("Dark olive green")},
        {"Pale green", TR("Pale green")},
        {"Light green", TR("Light green")},
        {"Medium sea green", TR("Medium sea green")},
        {"Sea green", TR("Sea green")},
        {"Dark sea green", TR("Dark sea green")},
        {"Cadet blue", TR("Cadet blue")},
        {"Medium aqua marine", TR("Medium aqua marine")},
        {"Turquoise", TR("Turquoise")},
        {"Medium turquoise", TR("Medium turquoise")},
        {"Dark turquoise", TR("Dark turquoise")},
        {"Pale turquoise", TR("Pale turquoise")},
        {"Aqua", TR("Aqua")},
        {"Cyan", TR("Cyan")},
        {"Light cyan", TR("Light cyan")},
        {"Mint cream", TR("Mint cream")},
        {"Honey dew", TR("Honey dew")},
        {"Aquamarine", TR("Aquamarine")},
        {"Light sea green", TR("Light sea green")},
        {"Dark cyan", TR("Dark cyan")},
        {"Teal", TR("Teal")},
        {"Dark slate gray", TR("Dark slate gray")},
        {"Light slate gray", TR("Light slate gray")},
        {"Slate gray", TR("Slate gray")},
        {"Deep sky blue", TR("Deep sky blue")},
        {"Dodger Blue", TR("Dodger Blue")},
        {"Sky blue", TR("Sky blue")},
        {"Light sky blue", TR("Light sky blue")},
        {"Light blue", TR("Light blue")},
        {"Powder blue", TR("Powder blue")},
        {"Light steel blue", TR("Light steel blue")},
        {"Steel blue", TR("Steel blue")},
        {"Cornflower blue", TR("Cornflower blue")},
        {"Royal blue", TR("Royal blue")},
        {"Blue", TR("Blue")},
        {"Medium blue", TR("Medium blue")},
        {"Midnight blue", TR("Midnight blue")},
        {"Dark blue", TR("Dark blue")},
        {"Navy", TR("Navy")},
        {"Slate blue", TR("Slate blue")},
        {"Dark slate blue", TR("Dark slate blue")},
        {"Medium slate blue", TR("Medium slate blue")},
        {"Blue violet", TR("Blue violet")},
        {"Indigo", TR("Indigo")},
        {"Dark violet", TR("Dark violet")},
        {"Dark orchid", TR("Dark orchid")},
        {"Medium orchid", TR("Medium orchid")},
        {"Orchid", TR("Orchid")},
        {"Violet", TR("Violet")},
        {"Medium purple", TR("Medium purple")},
        {"Purple", TR("Purple")},
        {"Rebecca purple", TR("Rebecca purple")},
        {"Medium violet red", TR("Medium violet red")},
        {"Pale violet red", TR("Pale violet red")},
        {"Deep pink", TR("Deep pink")},
        {"Hot pink", TR("Hot pink")},
        {"Light pink", TR("Light pink")},
        {"Pink", TR("Pink")},
        {"Plum", TR("Plum")},
        {"Thistle", TR("Thistle")},
        {"Magenta", TR("Magenta")},
        {"Fuchsia", TR("Fuchsia")},
        {"Dark magenta", TR("Dark magenta")},
        {"Linen", TR("Linen")},
        {"Old lace", TR("Old lace")},
        {"Sea shell", TR("Sea shell")},
        {"Ivory", TR("Ivory")},
        {"Floral white", TR("Floral white")},
        {"Lavender blush", TR("Lavender blush")},
        {"Ghost white", TR("Ghost white")},
        {"Alice blue", TR("Alice blue")},
        {"Lavender", TR("Lavender")},
        {"White smoke", TR("White smoke")},
        {"Gainsboro", TR("Gainsboro")},
        {"Black", TR("Black")},
        {"White", TR("White")},
        {"Coral fire", TR("Coral fire")},
        {"Sea anemone", TR("Sea anemone")},
        {"Deep abyss", TR("Deep abyss")},
        {"Lobster red", TR("Lobster red")},
        {"Sandy clay", TR("Sandy clay")},
        {"Driftwood", TR("Driftwood")},
        {"Sea buckthorn", TR("Sea buckthorn")},
        {"Sunset reef", TR("Sunset reef")},
        {"Tiger coral", TR("Tiger coral")},
        {"Pink coral", TR("Pink coral")},
        {"Seashell glow", TR("Seashell glow")},
        {"Sand", TR("Sand")},
        {"Golden kelp", TR("Golden kelp")},
        {"Sunlit dune", TR("Sunlit dune")},
        {"Amber nautilus", TR("Amber nautilus")},
        {"Sea lemon", TR("Sea lemon")},
        {"Pale starfish", TR("Pale starfish")},
        {"Spring tide", TR("Spring tide")},
        {"Lime algae", TR("Lime algae")},
        {"Sea grass", TR("Sea grass")},
        {"Neon plankton", TR("Neon plankton")},
        {"Kelp forest", TR("Kelp forest")},
        {"Emerald wave", TR("Emerald wave")},
        {"Whale shadow", TR("Whale shadow")},
        {"Sea turtle", TR("Sea turtle")},
        {"Lagoon", TR("Lagoon")},
        {"Tropical current", TR("Tropical current")},
        {"Midnight trench", TR("Midnight trench")},
        {"Dark kelp", TR("Dark kelp")},
        {"Crystal surf", TR("Crystal surf")},
        {"Turquoise bay", TR("Turquoise bay")},
        {"Sky over reef", TR("Sky over reef")},
        {"Shallow sky", TR("Shallow sky")},
        {"Electric blue", TR("Electric blue")},
        {"Dolphin", TR("Dolphin")},
        {"Ocean depths", TR("Ocean depths")},
        {"Whale", TR("Whale")},
        {"Indigo abyss", TR("Indigo abyss")},
        {"Sea urchin", TR("Sea urchin")},
        {"Lavender coral", TR("Lavender coral")},
        {"Violet tide", TR("Violet tide")},
        {"Deep sea orchid", TR("Deep sea orchid")},
        {"Neon jelly", TR("Neon jelly")},
        {"Fuchsia coral", TR("Fuchsia coral")},
        {"Pink jellyfish", TR("Pink jellyfish")},
        {"Foam", TR("Foam")},
        {"Seashell white", TR("Seashell white")},
        {"Pebble gray", TR("Pebble gray")},
        {"Storm cloud", TR("Storm cloud")},
        {"Ink black", TR("Ink black")},
        {"Green beige", TR("Green beige")},
        {"Sand yellow", TR("Sand yellow")},
        {"Signal yellow", TR("Signal yellow")},
        {"Golden yellow", TR("Golden yellow")},
        {"Honey yellow", TR("Honey yellow")},
        {"Maize yellow", TR("Maize yellow")},
        {"Daffodil yellow", TR("Daffodil yellow")},
        {"Brown beige", TR("Brown beige")},
        {"Lemon yellow", TR("Lemon yellow")},
        {"Oyster white", TR("Oyster white")},
        {"Light ivory", TR("Light ivory")},
        {"Zinc yellow", TR("Zinc yellow")},
        {"Grey beige", TR("Grey beige")},
        {"Olive yellow", TR("Olive yellow")},
        {"Rape yellow", TR("Rape yellow")},
        {"Traffic yellow", TR("Traffic yellow")},
        {"Ochre yellow", TR("Ochre yellow")},
        {"Traffic orange yellow", TR("Traffic orange yellow")},
        {"Curry", TR("Curry")},
        {"Melon yellow", TR("Melon yellow")},
        {"Broom yellow", TR("Broom yellow")},
        {"Dahlia yellow", TR("Dahlia yellow")},
        {"Pastel yellow", TR("Pastel yellow")},
        {"Pearl beige", TR("Pearl beige")},
        {"Pearl gold", TR("Pearl gold")},
        {"Sun yellow", TR("Sun yellow")},
        {"Yellow orange", TR("Yellow orange")},
        {"Deep orange", TR("Deep orange")},
        {"Vermilion", TR("Vermilion")},
        {"Pearl orange", TR("Pearl orange")},
        {"Pure orange", TR("Pure orange")},
        {"Luminous orange", TR("Luminous orange")},
        {"Luminous bright orange", TR("Luminous bright orange")},
        {"Bright red orange", TR("Bright red orange")},
        {"Traffic orange", TR("Traffic orange")},
        {"Signal orange", TR("Signal orange")},
        {"Salmon orange", TR("Salmon orange")},
        {"Pearl pink", TR("Pearl pink")},
        {"Copper orange", TR("Copper orange")},
        {"Signal brown", TR("Signal brown")},
        {"Fir orange", TR("Fir orange")},
        {"Signal red", TR("Signal red")},
        {"Luminous red", TR("Luminous red")},
        {"Carmine red", TR("Carmine red")},
        {"Pearl carmine red", TR("Pearl carmine red")},
        {"Pure red", TR("Pure red")},
        {"Luminous deep red", TR("Luminous deep red")},
        {"Currant red", TR("Currant red")},
        {"Pearl ruby red", TR("Pearl ruby red")},
        {"Fire red", TR("Fire red")},
        {"Ruby red", TR("Ruby red")},
        {"Purple red", TR("Purple red")},
        {"Wine red", TR("Wine red")},
        {"Black red", TR("Black red")},
        {"Oxide red", TR("Oxide red")},
        {"Brown red", TR("Brown red")},
        {"Pine red", TR("Pine red")},
        {"Tomato red", TR("Tomato red")},
        {"Antique pink", TR("Antique pink")},
        {"Coral red", TR("Coral red")},
        {"Rose", TR("Rose")},
        {"Strawberry red", TR("Strawberry red")},
        {"Traffic red", TR("Traffic red")},
        {"Salmon pink", TR("Salmon pink")},
        {"Luminous rose", TR("Luminous rose")},
        {"Luminous bright red", TR("Luminous bright red")},
        {"Raspberry red", TR("Raspberry red")},
        {"Orient red", TR("Orient red")},
        {"Pearl ruby", TR("Pearl ruby")},
        {"Red purple", TR("Red purple")},
        {"Red violet", TR("Red violet")},
        {"Heather violet", TR("Heather violet")},
        {"Bordeaux violet", TR("Bordeaux violet")},
        {"Mahogany", TR("Mahogany")},
        {"Grey purple", TR("Grey purple")},
        {"Signal violet", TR("Signal violet")},
        {"Fir green", TR("Fir green")},
        {"Sabine grey", TR("Sabine grey")},
        {"Pearl violet", TR("Pearl violet")},
        {"Pearl blackberry", TR("Pearl blackberry")},
        {"Green blue", TR("Green blue")},
        {"Ultramarine blue", TR("Ultramarine blue")},
        {"Sapphire blue", TR("Sapphire blue")},
        {"Black blue", TR("Black blue")},
        {"Signal blue", TR("Signal blue")},
        {"Brilliant blue", TR("Brilliant blue")},
        {"Grey blue", TR("Grey blue")},
        {"Azure blue", TR("Azure blue")},
        {"Gentian blue", TR("Gentian blue")},
        {"Cobalt blue", TR("Cobalt blue")},
        {"Pigeon blue", TR("Pigeon blue")},
        {"Traffic blue", TR("Traffic blue")},
        {"Turquoise blue", TR("Turquoise blue")},
        {"Capri blue", TR("Capri blue")},
        {"Ocean blue", TR("Ocean blue")},
        {"Water blue", TR("Water blue")},
        {"Night blue", TR("Night blue")},
        {"Distant blue", TR("Distant blue")},
        {"Pastel blue", TR("Pastel blue")},
        {"Pearl gentian blue", TR("Pearl gentian blue")},
        {"Pearl midnight blue", TR("Pearl midnight blue")},
        {"Patina green", TR("Patina green")},
        {"Emerald green", TR("Emerald green")},
        {"Leaf green", TR("Leaf green")},
        {"Olive green", TR("Olive green")},
        {"Blue green", TR("Blue green")},
        {"Moss green", TR("Moss green")},
        {"Grey olive", TR("Grey olive")},
        {"Pine green", TR("Pine green")},
        {"Pine brown", TR("Pine brown")},
        {"Grass green", TR("Grass green")},
        {"Reseda green", TR("Reseda green")},
        {"Brown green", TR("Brown green")},
        {"Reed green", TR("Reed green")},
        {"Black green", TR("Black green")},
        {"Turquoise green", TR("Turquoise green")},
        {"May green", TR("May green")},
        {"Chrome oxide green", TR("Chrome oxide green")},
        {"Traffic green", TR("Traffic green")},
        {"Fern green", TR("Fern green")},
        {"Opal green", TR("Opal green")},
        {"Mint green", TR("Mint green")},
        {"Bronze green", TR("Bronze green")},
        {"Pearl green", TR("Pearl green")},
        {"Sax turquoise", TR("Sax turquoise")},
        {"Pearl turquoise", TR("Pearl turquoise")},
        {"Pearl jade", TR("Pearl jade")},
        {"Pure green", TR("Pure green")},
        {"Luminous green", TR("Luminous green")},
        {"Squirrel grey", TR("Squirrel grey")},
        {"Silver grey", TR("Silver grey")},
        {"Olive grey", TR("Olive grey")},
        {"Moss grey", TR("Moss grey")},
        {"Signal grey", TR("Signal grey")},
        {"Mouse grey", TR("Mouse grey")},
        {"Beige grey", TR("Beige grey")},
        {"Khaki grey", TR("Khaki grey")},
        {"Green grey", TR("Green grey")},
        {"Tarpaulin grey", TR("Tarpaulin grey")},
        {"Iron grey", TR("Iron grey")},
        {"Basalt grey", TR("Basalt grey")},
        {"Brown grey", TR("Brown grey")},
        {"Slate grey", TR("Slate grey")},
        {"Anthracite grey", TR("Anthracite grey")},
        {"Light grey", TR("Light grey")},
        {"Umber grey", TR("Umber grey")},
        {"Concrete grey", TR("Concrete grey")},
        {"Graphite grey", TR("Graphite grey")},
        {"Granite grey", TR("Granite grey")},
        {"Stone grey", TR("Stone grey")},
        {"Pebble grey", TR("Pebble grey")},
        {"Cement grey", TR("Cement grey")},
        {"Yellow grey", TR("Yellow grey")},
        {"Platinum grey", TR("Platinum grey")},
        {"Dusty grey", TR("Dusty grey")},
        {"Agate grey", TR("Agate grey")},
        {"Quartz grey", TR("Quartz grey")},
        {"Window grey", TR("Window grey")},
        {"Traffic grey A", TR("Traffic grey A")},
        {"Traffic grey B", TR("Traffic grey B")},
        {"Silk grey", TR("Silk grey")},
        {"Telegrey 1", TR("Telegrey 1")},
        {"Telegrey 2", TR("Telegrey 2")},
        {"Telegrey 4", TR("Telegrey 4")},
        {"Pearl mouse grey", TR("Pearl mouse grey")},
        {"Green brown", TR("Green brown")},
        {"Ochre brown", TR("Ochre brown")},
        {"Clay brown", TR("Clay brown")},
        {"Copper brown", TR("Copper brown")},
        {"Chocolate brown", TR("Chocolate brown")},
        {"Olive brown", TR("Olive brown")},
        {"Nut brown", TR("Nut brown")},
        {"Red brown", TR("Red brown")},
        {"Sepia brown", TR("Sepia brown")},
        {"Chestnut brown", TR("Chestnut brown")},
        {"Mahogany brown", TR("Mahogany brown")},
        {"Grey brown", TR("Grey brown")},
        {"Pearl copper", TR("Pearl copper")},
        {"Beige brown", TR("Beige brown")},
        {"Pearl mocha brown", TR("Pearl mocha brown")},
        {"Earth brown", TR("Earth brown")},
        {"Pearl brown", TR("Pearl brown")},
        {"Cream", TR("Cream")},
        {"Grey white", TR("Grey white")},
        {"Signal white", TR("Signal white")},
        {"Signal black", TR("Signal black")},
        {"Jet black", TR("Jet black")},
        {"White aluminium", TR("White aluminium")},
        {"Grey aluminium", TR("Grey aluminium")},
        {"Pure white", TR("Pure white")},
        {"Graphite black", TR("Graphite black")},
        {"Traffic white", TR("Traffic white")},
        {"Traffic black", TR("Traffic black")},
        {"Papyrus white", TR("Papyrus white")},
        {"Pearl light grey", TR("Pearl light grey")},
        {"Metal: Silver", TR("Metal: Silver")},
        {"Metal: Brass", TR("Metal: Brass")},
        {"Metal: Gold", TR("Metal: Gold")},
        {"Metal: Copper", TR("Metal: Copper")},
        {"Metal: Bronze", TR("Metal: Bronze")},
        {"Nature: Pearl", TR("Nature: Pearl")},
        {"Nature: Rainbow", TR("Nature: Rainbow")},
        {"Nature: Clear Sky", TR("Nature: Clear Sky")},
        {"Nature: Sunset", TR("Nature: Sunset")},
        {"Wood: Dark", TR("Wood: Dark")},
        {"Wood: Medium", TR("Wood: Medium")},
        {"Wood: Light", TR("Wood: Light")}
    };
}

} // namespace


namespace {

// All geometry uses native screen coordinates, including negative monitor origins.
wxPoint color_picker_panel_position(const wxRect& anchor, const wxRect& work_area, const wxSize& size, int gap)
{
    const int below = anchor.y + anchor.height + gap;
    const int above = anchor.y - gap - size.y;
    const int y = below + size.y <= work_area.y + work_area.height ? below : above;
    return {std::clamp(anchor.x, work_area.x, work_area.x + std::max(0, work_area.width - size.x)),
            std::clamp(y, work_area.y, work_area.y + std::max(0, work_area.height - size.y))};
}

} // namespace

ColorPickerDialog::ColorPickerDialog(wxWindow* parent, const ColorSelection& initial, ColorPickerOptions options,
                                   bool preserve_multi_color, wxWindow* anchor)
    : WebViewHostDialog(parent, wxID_ANY, _L("Color Picker"), wxDefaultPosition, wxDefaultSize,
                        wxCAPTION | wxSYSTEM_MENU | wxCLOSE_BOX | wxFRAME_NO_TASKBAR),
      m_initial(initial), m_options(options), m_preserve_multi_color(preserve_multi_color)
{
    Bind(wxEVT_CLOSE_WINDOW, [this](wxCloseEvent&) { finish(wxID_CANCEL); });
    Bind(wxEVT_CHAR_HOOK, [this](wxKeyEvent& event) {
        if (event.GetKeyCode() == WXK_ESCAPE)
            finish(wxID_CANCEL);
        else
            event.Skip();
    });
    SetBackgroundColour(wxGetApp().get_window_default_clr());
    wxGetApp().UpdateDlgDarkUI(this);
#ifdef __WXGTK__
    // wxGTK dialogs default to CENTER_ON_PARENT, which conflicts with the anchor.
    gtk_window_set_position(GTK_WINDOW(GetHandle()), GTK_WIN_POS_NONE);
#endif
    // Snapshot the trigger instead of following the mouse or retaining a raw pointer.
    wxWindow* trigger = anchor ? anchor : parent;
    if (trigger)
        m_anchor_rect = trigger->GetScreenRect();
    int display_index = wxDisplay::GetFromPoint(m_anchor_rect.GetPosition() + wxPoint(m_anchor_rect.width / 2, m_anchor_rect.height / 2));
    if (display_index == wxNOT_FOUND)
        display_index = 0;
    m_work_area = wxDisplay(static_cast<unsigned int>(display_index)).GetClientArea();
    const auto normalized = normalize_color_selection(initial, options);
    if (normalized)
        m_initial = *normalized;
    // Read the sidebar state before the WebView exists: add_user_scripts() passes it to the page,
    // and the window opens at the matching size instead of resizing after the page loads.
    if (wxGetApp().app_config) {
        const AppConfig& config = *wxGetApp().app_config;
        m_sidebar_open = config.get(COLOR_PICKER_UI_SECTION, "sidebar_open") == "1";
        if (const std::string palette = config.get(COLOR_PICKER_UI_SECTION, "palette"); valid_palette_id(palette))
            m_palette = palette;
    }
    m_content_width  = COLOR_PICKER_PAGE_WIDTH + (m_sidebar_open ? COLOR_PICKER_SIDEBAR_WIDTH : 0);
    m_content_height = COLOR_PICKER_PAGE_HEIGHT;
    if (!normalized || !create_webview("web/dialog/ColorPickerDialog/index.html", _L("Color Picker"),
                                      wxSize(m_content_width, m_content_height),
                                      wxSize(COLOR_PICKER_PAGE_WIDTH, COLOR_PICKER_PAGE_HEIGHT))) {
        auto* sizer = new wxBoxSizer(wxVERTICAL);
        sizer->Add(new wxStaticText(this, wxID_ANY, wxS("wxWebView unavailable")), wxSizerFlags().Border(wxALL, FromDIP(20)));
        sizer->Add(new wxButton(this, wxID_CANCEL, _L("Cancel")), wxSizerFlags().Right().Border(wxALL, FromDIP(8)));
        SetSizerAndFit(sizer);
        Bind(wxEVT_BUTTON, [this](wxCommandEvent&) { finish(wxID_CANCEL); }, wxID_CANCEL);
        Bind(wxEVT_SHOW, [this](wxShowEvent& event) {
            if (event.IsShown() && !m_initial_positioned) {
                move_to_anchor();
                wxGetApp().CallAfter([this, alive = m_alive] {
                    if (alive->load(std::memory_order_acquire) && !m_closing) {
                        move_to_anchor();
                        m_initial_positioned = true;
                    }
                });
            }
            event.Skip();
        });
        wxGetApp().UpdateDlgDarkUI(this);
        move_to_anchor();
        return;
    }
    browser()->EnableBrowserAcceleratorKeys(false);
    browser()->Bind(EVT_WEBVIEW_RECREATED, [this](wxCommandEvent& event) {
        wxGetApp().UpdateDlgDarkUI(this);
        event.Skip(); // The shared host updates the page theme.
    });
    Bind(wxEVT_ACTIVATE, [this](wxActivateEvent& event) {
        if (event.GetActive() && IsShown() && !m_closing)
            focus_webview();
        event.Skip();
    });
    if (wxGetApp().app_config) {
        const auto stored = load_color_picker_favorites(*wxGetApp().app_config);
        m_favorites = stored.favorites;
        m_favorites_writable = stored.writable;
    }
    // The shared host attaches its sizer before constructing the full layout.
    GetSizer()->SetSizeHints(this);
    Move(m_work_area.GetPosition());
    // SetSizeHints may fit the window to the WebView's small initial best size.
    // Restore the intended dialog size only after applying the layout hints.
    resize_to_content(m_content_height);
    move_to_anchor();
    Bind(wxEVT_SHOW, [this](wxShowEvent& event) {
        if (event.IsShown() && !m_initial_positioned) {
            resize_to_content(m_content_height);
            move_to_anchor();
            // GTK may ignore the requested position until the window is shown.
            wxGetApp().CallAfter([this, alive = m_alive] {
                if (alive->load(std::memory_order_acquire) && !m_closing) {
                    resize_to_content(m_content_height);
                    move_to_anchor();
                    m_initial_positioned = true;
                    focus_webview();
                }
            });
        }
        event.Skip();
    });
}

ColorPickerDialog::~ColorPickerDialog() { m_alive->store(false, std::memory_order_release); }

void ColorPickerDialog::position_panel()
{
    if (m_positioning)
        return;
    m_positioning = true;
    // Both dimensions come from the page: width changes when the palette sidebar opens or closes.
    wxSize size = FromDIP(wxSize(m_content_width, m_content_height));
    // The work-area limit includes the native title bar and fixed frame.
    const wxSize frame = GetSize() - GetClientSize();
    size.x = std::min(size.x, std::max(1, m_work_area.width - frame.x));
    size.y = std::min(size.y, std::max(1, m_work_area.height - frame.y - FromDIP(16)));
    SetMinSize(wxSize(std::min(FromDIP(320), size.x), std::min(FromDIP(360), size.y)));
    if (size != GetClientSize())
        SetClientSize(size);
    m_positioning = false;
}

void ColorPickerDialog::move_to_anchor()
{
    const wxPoint position = color_picker_panel_position(m_anchor_rect, m_work_area, GetSize(), FromDIP(4));
    if (position != GetPosition())
        Move(position);
#ifdef __WXGTK__
    // wxGTK caches requested coordinates: Move can skip a post-show request even
    // when the window manager ignored the initial one. Reapply at native level.
    gtk_window_move(GTK_WINDOW(GetHandle()), position.x, position.y);
#endif
}

void ColorPickerDialog::resize_to_content(int height)
{
    m_content_height = height;
    position_panel();
    Layout();
#ifdef __WXOSX__
    // Like SpeedDial, explicitly match WKWebView's viewport even at unchanged size.
    if (wxWebView* view = browser())
        view->SetSize(GetClientSize());
#endif
    repaint_webview();
}

void ColorPickerDialog::focus_webview()
{
    wxWebView* view = browser();
    if (!view)
        return;
#ifdef __linux__
    if (void* backend = view->GetNativeBackend())
        gtk_widget_grab_focus(static_cast<GtkWidget*>(backend));
#else
    view->SetFocus();
#endif
    if (m_page_ready)
        run_script("window.ColorPickerDialog.focusInput();");
}

void ColorPickerDialog::repaint_webview()
{
    wxWebView* view = browser();
    if (!view)
        return;
    view->Refresh();
#ifdef __WXOSX__
    if (void* backend = view->GetNativeBackend())
        WKWebView_force_display(backend);
    view->Update();
#elif defined(__linux__)
    if (void* backend = view->GetNativeBackend())
        gtk_widget_queue_draw(static_cast<GtkWidget*>(backend));
#else
    view->Update();
#endif
}

void ColorPickerDialog::on_dpi_changed(const wxRect&)
{
    resize_to_content(m_content_height);
    Refresh();
}

void ColorPickerDialog::on_sys_color_changed()
{
    wxGetApp().UpdateDlgDarkUI(this);
}

void ColorPickerDialog::add_user_scripts()
{
    if (wxWebView* view = browser()) {
        auto language = wxGetApp().current_language_code().ToStdString();
        std::replace(language.begin(), language.end(), '_', '-');
        const std::string script = "window.ORCA_UI_STRINGS = " +
            color_picker_ui_strings().dump(-1, ' ', false, nlohmann::json::error_handler_t::ignore) +
            ";window.ORCA_COLOR_PICKER_LANGUAGE = " + nlohmann::json(language).dump() +
            // Lets the page lay out the sidebar before its first paint, matching the window size.
            ";window.ORCA_COLOR_PICKER_UI = " + nlohmann::json({{"sidebar_open", m_sidebar_open}, {"palette", m_palette}}).dump() + ";";
        view->AddUserScript(wxString::FromUTF8(script));
    }
}

void ColorPickerDialog::on_script_message(const nlohmann::json& payload)
{
    // GTK/WebKit may call on the native script-message stack. All dialog work,
    // including EndModal, runs after that callback and checks the lifetime token.
    wxGetApp().CallAfter([this, alive = m_alive, payload] {
        if (alive->load(std::memory_order_acquire) && !m_closing)
            handle_web_command(payload);
    });
}

void ColorPickerDialog::handle_web_command(const nlohmann::json& payload)
{
    if (!browser() || !payload.is_object())
        return;
    const auto command = payload.find("command");
    const auto page_id = payload.find("page_id");
    if (command == payload.end() || !command->is_string() || page_id == payload.end() || !page_id->is_string())
        return;
    const auto& id = page_id->get_ref<const std::string&>();
    if (id.empty() || id.size() > 64)
        return;
    if (*command == "ready") {
        // A repeated ready from the same document must not reset its edits. A new
        // document (e.g. WebView recreation) gets a fresh initialization handshake.
        if (id != m_page_id) {
            m_page_id = id;
            m_page_ready = false;
            m_init_sent = false;
        }
        if (!m_init_sent)
            send_initial_state();
        return;
    }
    if (id != m_page_id)
        return;
    if (*command == "cancel") {
        finish(wxID_CANCEL);
        return;
    }
    if (*command == "initialized") {
        if (m_init_sent && !m_page_ready) {
            m_page_ready = true;
            focus_webview();
            repaint_webview();
        }
        return;
    }
    if (!m_page_ready)
        return;
    if (*command == "resize") {
        const auto height = payload.find("height");
        if (height == payload.end() || !height->is_number())
            return;
        const double value = height->get<double>();
        if (!std::isfinite(value) || value < 300 || value > 900)
            return;
        // Width is optional so an older page that reports only height keeps the current width.
        const auto width = payload.find("width");
        if (width != payload.end()) {
            if (!width->is_number())
                return;
            const double width_value = width->get<double>();
            if (!std::isfinite(width_value) || width_value < 300 || width_value > 1200)
                return;
            m_content_width = static_cast<int>(std::ceil(width_value));
        }
        resize_to_content(static_cast<int>(std::ceil(value)));
        return;
    }
    if (*command == "confirm") {
        const auto value = payload.find("selection");
        if (value == payload.end())
            return;
        const auto selection = color_selection_from_json(*value, m_options);
        if (!selection)
            return;
        m_selection = *selection;
        finish(wxID_OK);
    } else if (*command == "update_favorites") {
        const auto values = payload.find("favorites");
        if (values == payload.end() || !m_favorites_writable || !wxGetApp().app_config)
            return;
        const auto favorites = color_favorites_from_json(*values);
        if (favorites && save_color_picker_favorites(*wxGetApp().app_config, *values)) {
            m_favorites = *favorites;
            nlohmann::json canonical = nlohmann::json::array();
            for (const ColorSelection& selection : m_favorites)
                canonical.push_back(color_selection_to_json(selection));
            const nlohmann::json response = {{"command", "favorites"}, {"page_id", m_page_id}, {"favorites", std::move(canonical)}};
            run_script(wxString::FromUTF8("window.ColorPickerDialog.handleMessage(" + response.dump() + ")"));
        }
    } else if (*command == "update_ui") {
        // Sidebar open/closed and the chosen palette, restored the next time the picker opens.
        const auto open = payload.find("sidebar_open");
        const auto palette = payload.find("palette");
        if (open == payload.end() || !open->is_boolean() || palette == payload.end() || !palette->is_string() || !wxGetApp().app_config)
            return;
        const auto& id = palette->get_ref<const std::string&>();
        if (!valid_palette_id(id))
            return;
        m_sidebar_open = open->get<bool>();
        m_palette = id;
        // set() marks the config dirty; it is written with the rest of the app config.
        AppConfig& config = *wxGetApp().app_config;
        config.set(COLOR_PICKER_UI_SECTION, "sidebar_open", m_sidebar_open ? "1" : "0");
        config.set(COLOR_PICKER_UI_SECTION, "palette", m_palette);
    }
}

void ColorPickerDialog::send_initial_state()
{
    nlohmann::json favorites = nlohmann::json::array();
    for (const ColorSelection& selection : m_favorites)
        favorites.push_back(color_selection_to_json(selection));
    const nlohmann::json payload = {{"command", "init"}, {"page_id", m_page_id},
                                   {"options", {{"allow_gradient", m_options.allow_gradient}, {"allow_alpha", m_options.allow_alpha},
                                                {"max_gradient_colors", COLOR_PICKER_MAX_GRADIENT_COLORS}}},
                                   {"selection", color_selection_to_json(m_initial)}, {"favorites", std::move(favorites)},
                                   {"favorites_writable", m_favorites_writable}, {"preserve_multi_color", m_preserve_multi_color},
                                   {"ui", {{"sidebar_open", m_sidebar_open}, {"palette", m_palette}}}};
    m_init_sent = true;
    // Already deferred and guarded: avoid the shared call_web_handler's unguarded
    // second CallAfter, which could run after this modal dialog is destroyed.
    if (!run_script(wxString::FromUTF8("window.ColorPickerDialog.handleMessage(" + payload.dump() + ")")))
        m_init_sent = false;
}

void ColorPickerDialog::finish(int return_code)
{
    if (m_closing)
        return;
    m_closing = true;
    if (return_code != wxID_OK)
        m_selection.reset();
    if (IsModal())
        EndModal(return_code);
    else
        Hide();
}

} // namespace Slic3r::GUI
