# popup_layout.gd
# Shared layout helper for all imaging/labs/medication/etc popups in MedRPG.
#
# Holds the four edge offsets that define where a popup's outer rectangle sits
# on the virtual 1280x720 canvas, plus a helper to apply those offsets to any
# popup's main panel.
#
# The numbers below are PIXEL OFFSETS from each screen edge, not the popup's
# width/height directly. Example: with left=215 and right=487, the popup's
# rectangle occupies x=215 to x=(1280-487)=793.
#
# Any popup that wants the standardized layout calls:
#   PopupLayout.apply_layout(main_panel)
# instead of doing its own custom_minimum_size + centering math.
#
# To shift an edge: change one number here, save, reload — every popup using
# this helper updates automatically.

class_name PopupLayout
extends RefCounted

# --- Per-popup edge offsets, in pixels from screen edges ---
# Each popup type gets its own dictionary so we can tune them independently.
# Keys: "left", "top", "right", "bottom"

const IMAGING := {
	"left":   150,
	"top":    200,
	"right":  200,
	"bottom":  50,
}

const LABS := {
	"left":   150,
	"top":    200,
	"right":  200,
	"bottom":  50,
}

const MEDICATIONS := {
	"left":   150,
	"top":    200,
	"right":  200,
	"bottom":  50,
}

const IV := {
	"left":   215,
	"top":    240,
	"right":  287,
	"bottom":  65,
}

# Default fallback if a popup name isn't recognized — same numbers as IMAGING.
const DEFAULT := {
	"left":   215,
	"top":    240,
	"right":  487,
	"bottom":  65,
}


# Apply edge-offset layout to a popup's main panel Control.
# popup_kind is the lookup key: "imaging", "labs", "medications", etc.
# Falls back to DEFAULT if the kind isn't found.
#
# This sets position and size directly from viewport dimensions instead of using
# anchors. Anchors don't reliably work for popups parented under CanvasLayer or
# Node2D — they need a Control parent with a real rect to anchor against, and
# CanvasLayer doesn't have one. Direct sizing sidesteps the issue.
static func apply_layout(panel: Control, popup_kind: String = "imaging") -> void:
	if not panel:
		return
	var edges: Dictionary = _get_edges(popup_kind)

	# Get viewport size (the visible game area).
	var vp: Vector2 = panel.get_viewport_rect().size

	var x: float    = float(edges["left"])
	var y: float    = float(edges["top"])
	var width: float  = vp.x - x - float(edges["right"])
	var height: float = vp.y - y - float(edges["bottom"])

	# Disable anchor-based sizing so position/size are honored directly.
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(x, y)
	panel.size = Vector2(width, height)
	panel.custom_minimum_size = Vector2(width, height)


static func _get_edges(popup_kind: String) -> Dictionary:
	match popup_kind:
		"imaging":     return IMAGING
		"labs":        return LABS
		"medications": return MEDICATIONS
		"iv":          return IV
		_:             return DEFAULT
