# Scripts/UI/ModeSelector.gd - Updated for center-top positioning
extends Control
class_name ModeSelector

@onready var battle_label: Label = $VBoxContainer/BattleMode
@onready var mpc_label: Label = $VBoxContainer/MPCTuningMode

var mode_selected: bool = false
var normal_color: Color = Color("#FF69B4")  # Pink
var hover_color: Color = Color("#FF69B4")   # Same pink but with underline
var click_color: Color = Color("#FFB6C1")   # Light pink
var inactive_alpha: float = 0.5

# For click animation
var click_tween: Tween

func _ready():
	# Wait for viewport to be ready
	await get_tree().process_frame
	
	# Position in top-center
	var window_size = get_window().size
	var container_width = $VBoxContainer.get_minimum_size().x
	position = Vector2((window_size.x - container_width) / 2, 20)
	
	# Set up labels
	setup_label(battle_label, "Battle Mode")
	setup_label(mpc_label, "MPC Tuning Mode")
	
	# Connect mouse events
	battle_label.gui_input.connect(_on_battle_input)
	mpc_label.gui_input.connect(_on_mpc_input)
	
	# Mouse enter/exit for hover effects
	battle_label.mouse_entered.connect(func(): _on_label_hover(battle_label, true))
	battle_label.mouse_exited.connect(func(): _on_label_hover(battle_label, false))
	mpc_label.mouse_entered.connect(func(): _on_label_hover(mpc_label, true))
	mpc_label.mouse_exited.connect(func(): _on_label_hover(mpc_label, false))

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

func _on_mpc_input(event: InputEvent):
	if mode_selected:
		return
		
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				animate_click(mpc_label)
			else:
				start_mpc_tuning()

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

func start_mpc_tuning():
	if mode_selected:
		return
		
	mode_selected = true
	
	# Set game mode - this will configure all systems
	GameMode.set_mode(GameMode.Mode.MPC_TUNING)
	
	fade_ui()
	
	# Enable ship movement
	enable_all_ship_movement()
	
	# Create and show the StandardTorpedoTuning UI
	var tuning_ui_scene = load("res://Scenes/StandardTorpedoTuning.tscn")
	if tuning_ui_scene:
		var tuning_ui = tuning_ui_scene.instantiate()
		tuning_ui.name = "StandardTorpedoTuningUI"
		
		# Add to UI layer if it exists, otherwise to root
		var ui_layer = get_node_or_null("/root/WorldRoot/UILayer")
		if ui_layer:
			ui_layer.add_child(tuning_ui)
		else:
			get_tree().root.add_child(tuning_ui)
		
		# Start the tuning system
		if tuning_ui.has_method("start_tuning"):
			tuning_ui.start_tuning()
		
		print("StandardTorpedoTuning UI created and started")
	else:
		push_error("Failed to load StandardTorpedoTuning.tscn!")
	
	# Configure torpedo launchers for standard torpedoes
	var launchers = get_tree().get_nodes_in_group("torpedo_launchers")
	for launcher in launchers:
		launcher.use_straight_trajectory = true
		launcher.use_multi_angle_trajectory = false
		launcher.use_simultaneous_impact = false
		
		print("Configured launcher for StandardTorpedo mode")

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
	fade_tween.tween_property(mpc_label, "modulate:a", inactive_alpha, 0.3)
	
	# Disable mouse interaction
	battle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mpc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

# Handle window resize
func _notification(what):
	if what == NOTIFICATION_RESIZED:
		# Reposition to stay centered
		var window_size = get_window().size
		var container_width = $VBoxContainer.get_minimum_size().x
		position = Vector2((window_size.x - container_width) / 2, 20)
