class_name BlockMenu extends Control

signal tile_type_selected(type: int)

@onready var panel: Panel = $Panel
@onready var toggle_button: Button = $Panel/ToggleButton

var is_open: bool = false
var tween: Tween
var panel_width: float = 300.0
var button_width: float = 30.0

# ============================================================================
# INITIALIZATION
# ============================================================================

func _ready():
	# Start closed — slide panel off to the right, leaving only the button tab visible
	panel.position.x = panel_width - button_width
	_update_toggle_button()


# ============================================================================
# TOGGLE
# ============================================================================

func toggle():
	print("Panel position before: ", panel.position.x)
	if tween:
		tween.kill()
	tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var target_x = 0.0 if not is_open else panel_width - button_width
	tween.tween_property(panel, "position:x", target_x, 0.25)
	is_open = not is_open
	_update_toggle_button()


func _update_toggle_button():
	toggle_button.text = "<" if is_open else ">"


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

func _on_toggle_button_pressed():
	print("Toggle pressed, is_open: ", is_open)
	toggle()
