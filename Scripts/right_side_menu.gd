extends VBoxContainer
@onready var level_editor: Node3D = $"../.."
@onready var camera: CameraController = $"../../Camera3D"

@onready var x_spin: SpinBox = $OffsetFold/PanelContainer/OffsetVContain/XSpin
@onready var z_spin: SpinBox = $OffsetFold/PanelContainer/OffsetVContain/ZSpin
@onready var y_level: Label = $YLevel

@onready var offset_confirm_button: Button = $OffsetFold/PanelContainer/OffsetVContain/OffsetConfirmButton

var old_text := ""
var is_spinbox_focused := false

func _ready() -> void:
	x_spin.get_line_edit().text_changed.connect(_something.bind(x_spin))
	z_spin.get_line_edit().text_changed.connect(_something.bind(z_spin))
	
	# Track focus state
	x_spin.get_line_edit().focus_entered.connect(_on_spinbox_focus_entered)
	x_spin.get_line_edit().focus_exited.connect(_on_spinbox_focus_exited)
	z_spin.get_line_edit().focus_entered.connect(_on_spinbox_focus_entered)
	z_spin.get_line_edit().focus_exited.connect(_on_spinbox_focus_exited)

func _something(text: String, box: SpinBox) -> void:
	# Allow empty, valid float, or just a minus sign (for typing negatives)
	if text.is_empty() or text.is_valid_float() or text == "-":
		old_text = text
	else:
		box.get_line_edit().text = old_text
		box.get_line_edit().caret_column = old_text.length()

func _on_spinbox_focus_entered() -> void:
	is_spinbox_focused = true
	# Disable ALL processing and input
	level_editor.set_process(false)
	level_editor.set_physics_process(false)
	level_editor.set_process_input(false)
	level_editor.set_process_unhandled_input(false)
	
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.set_process_input(false)
	camera.set_process_unhandled_input(false)
	
	print("All input blocked - spinbox focused")

func _on_spinbox_focus_exited() -> void:
	is_spinbox_focused = false
	# Re-enable ALL processing and input
	level_editor.set_process(true)
	level_editor.set_physics_process(true)
	level_editor.set_process_input(true)
	level_editor.set_process_unhandled_input(true)
	
	camera.set_process(true)
	camera.set_physics_process(true)
	camera.set_process_input(true)
	camera.set_process_unhandled_input(true)
	
	print("All input enabled - spinbox unfocused")

func _on_offset_confirm_button_pressed() -> void:
	var target_level = level_editor.current_y_level
	
	level_editor.set_y_level_offset(target_level, x_spin.value, z_spin.value)
	
	# Verify it was stored correctly
	var stored_offset = level_editor.get_y_level_offset(target_level)
	
	# Update display
	x_spin.set_value_no_signal(snappedf(stored_offset.x, 0.01))
	z_spin.set_value_no_signal(snappedf(stored_offset.y, 0.01))


func _on_grid_visualizer_level_changed(level: int) -> void:
	y_level.text = "Current Y-Level: " + str(level)
	
	# Get the actual stored offset for this level
	var actual_offset = level_editor.get_y_level_offset(level)
	
	# Round to avoid floating point weirdness
	x_spin.set_value_no_signal(snappedf(actual_offset.x, 0.01))
	z_spin.set_value_no_signal(snappedf(actual_offset.y, 0.01))
