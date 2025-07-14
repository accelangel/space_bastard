# Scripts/UI/ModeSelector.gd - Updated for GameMode
extends Control
class_name ModeSelector

@onready var battle_label: Label = $VBoxContainer/BattleMode
@onready var pid_label: Label = $VBoxContainer/PIDTuningMode

var mode_selected: bool = false
var normal_color: Color = Color("#FF69B4")  # Pink
var hover_color: Color = Color("#FF69B4")   # Same pink but with underline
var click_color: Color = Color("#FFB6C1")   # Light pink
var inactive_alpha: float = 0.5

# For click animation
var click_tween: Tween

signal mode_chosen(mode: String)

func _ready():
	# Position in top-left
	position = Vector2(20, 20)
	
	# Set up labels
	setup_label(battle_label, "Battle Mode")
	setup_label(pid_label, "PID Tuning Mode")
	
	# Connect mouse events
	battle_label.gui_input.connect(_on_battle_input)
	pid_label.gui_input.connect(_on_pid_input)
	
	# Mouse enter/exit for hover effects
	battle_label.mouse_entered.connect(func(): _on_label_hover(battle_label, true))
	battle_label.mouse_exited.connect(func(): _on_label_hover(battle_label, false))
	pid_label.mouse_entered.connect(func(): _on_label_hover(pid_label, true))
	pid_label.mouse_exited.connect(func(): _on_label_hover(pid_label, false))

func setup_label(label: Label, text: String):
	label.text = text
	label.add_theme_color_override("font_color", normal_color)
	label.add_theme_font_size_override("font_size", 24)
	label.mouse_filter = Control.MOUSE_FILTER_STOP

func _on_label_hover(label: Label, hovering: bool):
	if mode_selected:
		return
		
	if hovering:
		# Add underline on hover
		label.add_theme_color_override("font_shadow_color", normal_color)
		label.add_theme_constant_override("shadow_offset_y", 2)
		label.add_theme_constant_override("line_spacing", -2)
		# Create underline effect with a bottom border
		var font = label.get_theme_font("font")
		if font:
			label.set("theme_override_styles/normal", get_underline_style())
	else:
		# Remove underline
		label.remove_theme_color_override("font_shadow_color")
		label.remove_theme_constant_override("shadow_offset_y")
		label.remove_theme_constant_override("line_spacing")

func get_underline_style():
	# Simple underline effect using RichTextLabel would be better, 
	# but for now we'll handle it differently
	return null

func _on_battle_input(event: InputEvent):
	if mode_selected:
		return
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				animate_click(battle_label)
			else:
				start_battle_mode()

func _on_pid_input(event: InputEvent):
	if mode_selected:
		return
		
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				animate_click(pid_label)
			else:
				start_pid_tuning()

func animate_click(label: Label):
	# Kill any existing tween
	if click_tween:
		click_tween.kill()
	
	# Create scale pulse animation
	click_tween = create_tween()
	click_tween.set_trans(Tween.TRANS_ELASTIC)
	click_tween.tween_property(label, "scale", Vector2(1.1, 1.1), 0.1)
	click_tween.tween_property(label, "scale", Vector2(1.0, 1.0), 0.1)
	
	# Also brighten color briefly
	label.add_theme_color_override("font_color", click_color)

func start_battle_mode():
	if mode_selected:
		return
		
	mode_selected = true
	
	# Set game mode - this will configure all systems
	GameMode.set_mode(GameMode.Mode.BATTLE)
	
	fade_ui()
	
	# Enable ship movement
	enable_all_ship_movement()
	
	# Start battle timer in player ship
	var player_ships = get_tree().get_nodes_in_group("player_ships")
	if player_ships.size() > 0:
		var player = player_ships[0]
		if player.has_method("start_battle_timer"):
			player.start_battle_timer()

func start_pid_tuning():
	if mode_selected:
		return
		
	mode_selected = true
	
	# Set game mode - this will configure all systems
	GameMode.set_mode(GameMode.Mode.PID_TUNING)
	
	fade_ui()
	
	# Enable ship movement
	enable_all_ship_movement()
	
	# PIDTuner will start automatically from mode signal

func enable_all_ship_movement():
	var ships = get_tree().get_nodes_in_group("ships")
	for ship in ships:
		if ship.has_method("enable_movement"):
			ship.enable_movement()

func fade_ui():
	# Fade both labels to inactive state
	var fade_tween = create_tween()
	fade_tween.set_parallel(true)
	fade_tween.tween_property(battle_label, "modulate:a", inactive_alpha, 0.3)
	fade_tween.tween_property(pid_label, "modulate:a", inactive_alpha, 0.3)
	
	# Disable mouse interaction
	battle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pid_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
