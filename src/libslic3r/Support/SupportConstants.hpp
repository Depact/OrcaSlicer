#ifndef slic3r_SupportConstants_hpp_
#define slic3r_SupportConstants_hpp_

// Unified support-related constants for unity-build compatibility.
// Replaces per-file #define macros that clashed in unified translation units.

#include <initializer_list>
#include "ClipperUtils.hpp"     // JoinType, jtSquare
#include "SupportLayer.hpp"      // SupporLayerType

namespace Slic3r {

// Support material margin — how much we extend support around contact areas.
// NOTE: different subsystems used different values; keep explicit names.
constexpr float SUPPORT_MATERIAL_MARGIN_COMMON       = 1.5f;  // SupportCommon.cpp (support generation)
constexpr float SUPPORT_MATERIAL_MARGIN_MATERIAL     = 1.2f;  // SupportMaterial.cpp (support material)
constexpr float SUPPORT_MATERIAL_MARGIN_BRIDGE       = 1.2f;  // PrintObject.cpp (bridge removal)

// Support surface offset parameters for polygon operations (join type, miter limit)
constexpr JoinType SUPPORT_SURFACES_OFFSET_JOIN_TYPE = jtSquare;
constexpr double SUPPORT_SURFACES_OFFSET_MITER_LIMIT = 0.0;

// Number of steps to reach margin incrementally (SupportMaterial.cpp)
constexpr int SUPPORT_MARGIN_STEPS = 3;

// Tree support pillar geometry (SupportMaterial.cpp, TreeSupport.cpp)
constexpr float TREE_SUPPORT_PILLAR_SIZE    = 2.5f;
constexpr float TREE_SUPPORT_PILLAR_SPACING = 10.0f;

// Support layer types covered by dense interface (shared between SupportCommon.cpp, SupportMaterial.cpp)
constexpr std::initializer_list<SupporLayerType> support_types_interface = {
    SupporLayerType::RaftInterface, SupporLayerType::BottomContact, SupporLayerType::BottomInterface,
    SupporLayerType::TopContact, SupporLayerType::TopInterface
};

} // namespace Slic3r

#endif // slic3r_SupportConstants_hpp_