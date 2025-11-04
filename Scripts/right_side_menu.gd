extends VBoxContainer
@onready var level_editor: Node3D = $"../.."

@onready var x_spin: SpinBox = $OffsetFold/PanelContainer/OffsetVContain/XSpin
@onready var z_spin: SpinBox = $OffsetFold/PanelContainer/OffsetVContain/ZSpin
@onready var y_level: Label = $YLevel

@onready var offset_confirm_button: Button = $OffsetFold/PanelContainer/OffsetVContain/OffsetConfirmButton

var old_text := ""

func _ready() -> void:
	x_spin.get_line_edit().text_changed.connect(_something.bind(x_spin))
	z_spin.get_line_edit().text_changed.connect(_something.bind(z_spin))

func _something(text: String, box: SpinBox) -> void:
	if text.is_empty() or text.is_valid_float():
		old_text = text
	else:
		box.get_line_edit().text = old_text


func _on_offset_confirm_button_pressed() -> void:
	level_editor.set_y_level_offset(level_editor.current_y_level, x_spin.value, z_spin.value)


func _on_grid_visualizer_level_changed(level: int, offset: Vector2) -> void:
	y_level.text = "Current Y-Level: " + str(level)
	print(offset.x)
	x_spin.value = offset.x
	z_spin.value = offset.y
