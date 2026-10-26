#include "I18N.hpp"
#include <wx/string.h>
#include <string>
#include <wx/translation.h>
#include <wx/strconv.h>

namespace Slic3r { namespace GUI { 

wxString L_s_u8L(const std::string &str)
{
	//! Explicitly specify that the source string is already in UTF-8 encoding
	return wxGetTranslation(wxString(str.c_str(), wxConvUTF8));
}

} }
