# Scripts/UI/ManualTuningPanel.gd
extends Control
class_name ManualTuningPanel

# UI References
@onready var vbox_container: VBoxContainer = $VBoxContainer

# Torpedo selection
@onready var straight_button: Button = $VBoxContainer/TorpedoSelectionContainer/StraightButton
@onready var multi_angle_button: Button = $VBoxContainer/TorpedoSelectionContainer/MultiAngleButton
@onready var simultaneous_button: Button = $VBoxContainer/TorpedoSelectionContainer/SimultaneousButton

# Auto-launch
@onready var auto_launch_toggle: CheckBox = $VBoxContainer/AutoLaunchContainer/AutoLaunchToggle

# Time scale
@onready var time_scale_slider: HSlider = $VBoxContainer/TimeScaleContainer/TimeScaleSlider
@onready var time_scale_label: Label = $VBoxContainer/TimeScaleContainer/TimeScaleLabel

# Parameters
@onready var parameter_container: VBoxContainer = $VBoxContainer/ScrollContainer/ParameterContainer

# Current torpedo type
enum TorpedoType { STRAIGHT, MULTI_ANGLE, SIMULTANEOUS }
var current_torpedo_type: TorpedoType = TorpedoType.STRAIGHT

# Auto-launch state
var auto_launch_enabled: bool = false
var cycle_in_progress: bool = false
var waiting_for_next_cycle: bool = false

# Slider controls
var layer1_sliders: Dictionary = {}
var layer2_sliders: Dictionary = {}
var current_layer1_sliders: Array = []  # Currently visible L1 sliders

# Performance tracking
var update_timer: float = 0.0
var update_interval: float = 0.1

# Cycle statistics
var cycle_start_time: float = 0.0
var torpedoes_fired: int = 0
var torpedoes_hit: int = 0
var total_cycles: int = 0

# Visual settings
const SLIDER_HEIGHT: float = 40.0
const LABEL_WIDTH: float = 250.0
const VALUE_LABEL_WIDTH: float = 80.0

func _ready():
	# Set up torpedo type buttons
	setup_torpedo_buttons()
	
	# Set up auto-launch toggle
	auto_launch_toggle.toggled.connect(_on_auto_launch_toggled)
	
	# Set up time scale slider
	setup_time_scale_control()
	
	# Create ALL parameter sliders (but hide them)
	create_all_parameter_sliders()
	
	# Show only straight torpedo params by default
	show_parameters_for_type(TorpedoType.STRAIGHT)
	
	# Add cycle statistics display
	create_statistics_display()
	
	# Start invisible
	visible = false
	
	# Listen for mode changes
	GameMode.mode_changed.connect(_on_mode_changed)

func setup_torpedo_buttons():
	# Style buttons
	straight_button.toggle_mode = true
	multi_angle_button.toggle_mode = true
	simultaneous_button.toggle_mode = true
	
	# Connect signals
	straight_button.pressed.connect(func(): _on_torpedo_type_selected(TorpedoType.STRAIGHT))
	multi_angle_button.pressed.connect(func(): _on_torpedo_type_selected(TorpedoType.MULTI_ANGLE))
	simultaneous_button.pressed.connect(func(): _on_torpedo_type_selected(TorpedoType.SIMULTANEOUS))
	
	# Select straight by default
	straight_button.button_pressed = true

func _on_torpedo_type_selected(type: TorpedoType):
	current_torpedo_type = type
	
	# Update button states
	straight_button.button_pressed = (type == TorpedoType.STRAIGHT)
	multi_angle_button.button_pressed = (type == TorpedoType.MULTI_ANGLE)
	simultaneous_button.button_pressed = (type == TorpedoType.SIMULTANEOUS)
	
	# Show only relevant parameters
	show_parameters_for_type(type)
	
	# Reset cycle stats when switching types
	reset_cycle_stats()
	
	# Configure player ship torpedo launcher
	configure_player_torpedo_type(type)
	
	print("\n=== SELECTED TORPEDO TYPE: %s ===" % get_torpedo_type_name(type))

func get_torpedo_type_name(type: TorpedoType) -> String:
	match type:
		TorpedoType.STRAIGHT: return "STRAIGHT"
		TorpedoType.MULTI_ANGLE: return "MULTI-ANGLE"
		TorpedoType.SIMULTANEOUS: return "SIMULTANEOUS"
		_: return "UNKNOWN"

func configure_player_torpedo_type(type: TorpedoType):
	var player_ships = get_tree().get_nodes_in_group("player_ships")
	if player_ships.is_empty():
		return
		
	var player = player_ships[0]
	match type:
		TorpedoType.STRAIGHT:
			player.use_multi_angle_torpedoes = false
			player.use_simultaneous_impact = false
		TorpedoType.MULTI_ANGLE:
			player.use_multi_angle_torpedoes = true
			player.use_simultaneous_impact = false
		TorpedoType.SIMULTANEOUS:
			player.use_multi_angle_torpedoes = false
			player.use_simultaneous_impact = true
	
	player.update_torpedo_launcher_settings()

func _on_auto_launch_toggled(pressed: bool):
	auto_launch_enabled = pressed
	
	if pressed:
		print("Auto-launch ENABLED - Cycles will fire automatically")
		# Start first cycle immediately if not already in progress
		if not cycle_in_progress:
			fire_torpedo_volley()
	else:
		print("Auto-launch DISABLED")

func show_parameters_for_type(type: TorpedoType):
	# Hide all layer 1 sliders
	for slider_control in current_layer1_sliders:
		slider_control.container.visible = false
	current_layer1_sliders.clear()
	
	# Show relevant sliders
	match type:
		TorpedoType.STRAIGHT:
			show_straight_parameters()
		TorpedoType.MULTI_ANGLE:
			show_multi_angle_parameters()
		TorpedoType.SIMULTANEOUS:
			show_simultaneous_parameters()
	
	# Layer 2 is always visible - just make sure
	for key in layer2_sliders:
		layer2_sliders[key].container.visible = true

func show_straight_parameters():
	var params = ["waypoint_density_threshold", "straight.lateral_separation", 
				  "straight.convergence_delay", "straight.initial_boost_duration"]
	
	for param in params:
		if param in layer1_sliders:
			layer1_sliders[param].container.visible = true
			current_layer1_sliders.append(layer1_sliders[param])

func show_multi_angle_parameters():
	# For now, show a message since it's not implemented
	print("Multi-angle trajectories not yet implemented - showing straight parameters")
	show_straight_parameters()

func show_simultaneous_parameters():
	# For now, show a message since it's not implemented
	print("Simultaneous trajectories not yet implemented - showing straight parameters")
	show_straight_parameters()

func create_all_parameter_sliders():
	# Create the layer labels and ALL sliders, but they start hidden
	var layer1_label = Label.new()
	layer1_label.text = "=== LAYER 1 - TRAJECTORY SHAPING ==="
	layer1_label.add_theme_font_size_override("font_size", 16)
	layer1_label.add_theme_color_override("font_color", Color.CYAN)
	parameter_container.add_child(layer1_label)
	
	# Create ALL layer 1 sliders
	create_layer1_sliders()
	
	# Create layer 2 sliders (always visible)
	create_layer2_sliders()
	
	# Hide all layer 1 sliders initially
	for key in layer1_sliders:
		layer1_sliders[key].container.visible = false

func setup_time_scale_control():
	time_scale_slider.min_value = -2.0  # 0.1x speed
	time_scale_slider.max_value = 2.0   # 4.0x speed
	time_scale_slider.value = 0.0      # 1.0x speed
	time_scale_slider.step = 0.1
	time_scale_slider.value_changed.connect(_on_time_scale_changed)
	
	# Initial label
	time_scale_label.text = "Speed: 1.0x (Normal)"

func _on_mode_changed(new_mode: GameMode.Mode):
	visible = (new_mode == GameMode.Mode.MPC_TUNING)
	if visible:
		cycle_start_time = Time.get_ticks_msec() / 1000.0
		reset_cycle_stats()

func _on_time_scale_changed(value: float):
	var time_scale = pow(2.0, value)
	Engine.time_scale = time_scale
	
	# Update label
	if time_scale < 1.0:
		time_scale_label.text = "Speed: %.1fx (Slow)" % time_scale
	elif time_scale > 1.0:
		time_scale_label.text = "Speed: %.1fx (Fast)" % time_scale
	else:
		time_scale_label.text = "Speed: 1.0x (Normal)"
	
	# Notify BatchMPCManager
	var batch_manager = get_node_or_null("/root/BatchMPC")
	if batch_manager:
		batch_manager.use_real_time_updates = true

func create_layer1_sliders():
	# Universal parameters
	add_section_label("Universal Parameters")
	layer1_sliders["waypoint_density_threshold"] = create_parameter_slider(
		"Waypoint Density Threshold", 0.1, 1.0, 0.2, 0.01, 1
	)
	
	# Straight trajectory parameters
	add_section_label("Straight Trajectory")
	layer1_sliders["straight.lateral_separation"] = create_parameter_slider(
		"Lateral Separation", 0.0, 0.5, 0.1, 0.01, 1
	)
	layer1_sliders["straight.convergence_delay"] = create_parameter_slider(
		"Convergence Delay", 0.5, 1.0, 0.8, 0.01, 1
	)
	layer1_sliders["straight.initial_boost_duration"] = create_parameter_slider(
		"Initial Boost Duration", 0.0, 0.5, 0.15, 0.01, 1
	)
	
	# Multi-angle parameters
	add_section_label("Multi-Angle Trajectory")
	layer1_sliders["multi_angle.flip_burn_threshold"] = create_parameter_slider(
		"Flip-Burn Threshold", 0.5, 2.0, 1.2, 0.1, 1
	)
	layer1_sliders["multi_angle.deceleration_target"] = create_parameter_slider(
		"Deceleration Target (km/s)", 1.0, 10.0, 2.0, 0.1, 1
	)
	layer1_sliders["multi_angle.arc_distance"] = create_parameter_slider(
		"Arc Distance", 0.1, 0.5, 0.3, 0.01, 1
	)
	layer1_sliders["multi_angle.arc_start"] = create_parameter_slider(
		"Arc Start", 0.0, 0.3, 0.1, 0.01, 1
	)
	layer1_sliders["multi_angle.arc_peak"] = create_parameter_slider(
		"Arc Peak", 0.3, 0.7, 0.5, 0.01, 1
	)
	layer1_sliders["multi_angle.final_approach"] = create_parameter_slider(
		"Final Approach", 0.7, 1.0, 0.8, 0.01, 1
	)
	
	# Simultaneous impact parameters
	add_section_label("Simultaneous Impact")
	layer1_sliders["simultaneous.flip_burn_threshold"] = create_parameter_slider(
		"Flip-Burn Threshold", 0.5, 2.5, 1.5, 0.1, 1
	)
	layer1_sliders["simultaneous.deceleration_target"] = create_parameter_slider(
		"Deceleration Target (km/s)", 1.0, 10.0, 3.0, 0.1, 1
	)
	layer1_sliders["simultaneous.fan_out_rate"] = create_parameter_slider(
		"Fan Out Rate", 0.5, 2.0, 1.0, 0.1, 1
	)
	layer1_sliders["simultaneous.fan_duration"] = create_parameter_slider(
		"Fan Duration", 0.1, 0.5, 0.25, 0.01, 1
	)
	layer1_sliders["simultaneous.converge_start"] = create_parameter_slider(
		"Converge Start", 0.5, 0.9, 0.7, 0.01, 1
	)
	layer1_sliders["simultaneous.converge_aggression"] = create_parameter_slider(
		"Converge Aggression", 0.5, 2.0, 1.0, 0.1, 1
	)

func create_layer2_sliders():
	# Add separator
	var separator = HSeparator.new()
	parameter_container.add_child(separator)
	
	var layer2_label = Label.new()
	layer2_label.text = "=== LAYER 2 - EXECUTION CONTROL ==="
	layer2_label.add_theme_font_size_override("font_size", 16)
	layer2_label.add_theme_color_override("font_color", Color.CYAN)
	parameter_container.add_child(layer2_label)
	
	layer2_sliders["navigation_constant_N"] = create_parameter_slider(
		"Navigation Constant N", 1.0, 5.0, 3.0, 0.1, 2
	)
	layer2_sliders["velocity_gain"] = create_parameter_slider(
		"Velocity Gain", 0.0001, 0.01, 0.001, 0.0001, 2
	)
	layer2_sliders["velocity_anticipation"] = create_parameter_slider(
		"Velocity Anticipation", 0.0, 1.0, 0.5, 0.05, 2
	)
	layer2_sliders["rotation_thrust_penalty"] = create_parameter_slider(
		"Rotation Thrust Penalty", 0.0, 1.0, 0.5, 0.05, 2
	)
	layer2_sliders["thrust_smoothing"] = create_parameter_slider(
		"Thrust Smoothing", 0.0, 1.0, 0.5, 0.05, 2
	)
	layer2_sliders["position_tolerance"] = create_parameter_slider(
		"Position Tolerance (m)", 50.0, 500.0, 100.0, 10.0, 2
	)
	layer2_sliders["velocity_tolerance"] = create_parameter_slider(
		"Velocity Tolerance (m/s)", 100.0, 2000.0, 500.0, 50.0, 2
	)

func add_section_label(text: String):
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color.YELLOW)
	label.add_theme_constant_override("outline_size", 1)
	parameter_container.add_child(label)

func create_parameter_slider(label_text: String, min_val: float, max_val: float, 
						   default_val: float, step_val: float, layer: int) -> SliderControl:
	var container = HBoxContainer.new()
	container.custom_minimum_size.y = SLIDER_HEIGHT
	
	# Background for performance indication
	var background = ColorRect.new()
	background.color = Color(0.2, 0.2, 0.2, 0.5)
	background.show_behind_parent = true
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.add_child(background)
	
	# Label
	var label = Label.new()
	label.text = label_text
	label.custom_minimum_size.x = LABEL_WIDTH
	container.add_child(label)
	
	# Slider
	var slider = HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.value = default_val
	slider.step = step_val
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(slider)
	
	# Value label
	var value_label = Label.new()
	value_label.text = str(default_val)
	value_label.custom_minimum_size.x = VALUE_LABEL_WIDTH
	value_label.add_theme_constant_override("outline_size", 1)
	container.add_child(value_label)
	
	# Connect slider
	slider.value_changed.connect(func(value): 
		value_label.text = "%.3f" % value if step_val < 0.01 else "%.1f" % value
		_on_parameter_changed(label_text, value, layer)
	)
	
	parameter_container.add_child(container)
	
	# Create control object
	var control = SliderControl.new()
	control.container = container
	control.slider = slider
	control.label = label
	control.value_label = value_label
	control.background = background
	control.param_name = label_text
	control.layer = layer
	
	return control

func _on_parameter_changed(param_name: String, value: float, layer: int):
	# Update ManualTuningParameters singleton
	TuningParams.set_parameter(layer, param_name, value)

func create_statistics_display():
	var separator = HSeparator.new()
	parameter_container.add_child(separator)
	
	var stats_label = Label.new()
	stats_label.name = "StatsLabel"
	stats_label.text = "=== CYCLE STATISTICS ==="
	stats_label.add_theme_font_size_override("font_size", 14)
	stats_label.add_theme_color_override("font_color", Color.GREEN)
	parameter_container.add_child(stats_label)
	
	var stats_text = RichTextLabel.new()
	stats_text.name = "StatsText"
	stats_text.custom_minimum_size.y = 200
	stats_text.bbcode_enabled = true
	stats_text.fit_content = true
	parameter_container.add_child(stats_text)

func _process(delta):
	if not visible:
		return
	
	# Update performance feedback
	update_timer += delta
	if update_timer >= update_interval:
		update_timer = 0.0
		update_layer2_feedback()
		check_cycle_completion()

func fire_torpedo_volley():
	var player_ships = get_tree().get_nodes_in_group("player_ships")
	if player_ships.is_empty():
		return
	
	var player = player_ships[0]
	player.fire_torpedoes_at_enemy()
	torpedoes_fired += 1
	cycle_in_progress = true
	
	print("Fired torpedo volley #%d for cycle #%d" % [torpedoes_fired, total_cycles + 1])

func update_layer2_feedback():
	var metrics = collect_torpedo_metrics()
	
	# Update slider colors based on performance
	for param_name in layer2_sliders:
		var control = layer2_sliders[param_name]
		
		match param_name:
			"navigation_constant_N":
				control.performance_score = 1.0 - min(metrics.avg_position_error / 1000.0, 1.0)
			"velocity_gain":
				control.performance_score = 1.0 - min(metrics.avg_velocity_error / 5000.0, 1.0)
			"velocity_anticipation":
				control.performance_score = metrics.anticipation_quality
			"rotation_thrust_penalty":
				control.performance_score = metrics.rotation_efficiency
			"thrust_smoothing":
				control.performance_score = metrics.control_smoothness
			"position_tolerance":
				control.performance_score = 1.0 - min(metrics.tolerance_violations / 10.0, 1.0)
			"velocity_tolerance":
				control.performance_score = 1.0 - min(metrics.velocity_violations / 10.0, 1.0)
		
		control.update_performance_color()

func collect_torpedo_metrics() -> Dictionary:
	var metrics = {
		"avg_position_error": 0.0,
		"avg_velocity_error": 0.0,
		"anticipation_quality": 0.0,
		"rotation_efficiency": 0.0,
		"control_smoothness": 0.0,
		"tolerance_violations": 0,
		"velocity_violations": 0,
		"torpedo_count": 0
	}
	
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	var valid_count = 0
	
	for torpedo in torpedoes:
		if not is_instance_valid(torpedo) or torpedo.get("marked_for_death"):
			continue
			
		if torpedo.has_method("get_performance_metrics"):
			var t_metrics = torpedo.get_performance_metrics()
			metrics.avg_position_error += t_metrics.position_error
			metrics.avg_velocity_error += t_metrics.velocity_error
			metrics.anticipation_quality += t_metrics.anticipation_score
			metrics.rotation_efficiency += t_metrics.rotation_efficiency
			metrics.control_smoothness += t_metrics.smoothness
			
			if t_metrics.position_error > layer2_sliders["position_tolerance"].slider.value:
				metrics.tolerance_violations += 1
			if t_metrics.velocity_error > layer2_sliders["velocity_tolerance"].slider.value:
				metrics.velocity_violations += 1
			
			valid_count += 1
	
	# Average the metrics
	if valid_count > 0:
		metrics.avg_position_error /= valid_count
		metrics.avg_velocity_error /= valid_count
		metrics.anticipation_quality /= valid_count
		metrics.rotation_efficiency /= valid_count
		metrics.control_smoothness /= valid_count
		metrics.torpedo_count = valid_count
	
	return metrics

func check_cycle_completion():
	if not cycle_in_progress:
		return
		
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	var active_count = 0
	
	for torpedo in torpedoes:
		if is_instance_valid(torpedo) and not torpedo.get("marked_for_death"):
			active_count += 1
	
	# Cycle complete when no torpedoes remain
	if active_count == 0:
		cycle_in_progress = false
		print_cycle_statistics()
		
		# Start next cycle if auto-launch is enabled
		if auto_launch_enabled:
			# Small delay before next cycle for clarity
			waiting_for_next_cycle = true
			await get_tree().create_timer(0.5).timeout
			waiting_for_next_cycle = false
			
			reset_cycle_stats()
			fire_torpedo_volley()
		else:
			reset_cycle_stats()

func print_cycle_statistics():
	total_cycles += 1
	var cycle_time = Time.get_ticks_msec() / 1000.0 - cycle_start_time
	var hit_rate = float(torpedoes_hit) / float(torpedoes_fired) * 100.0 if torpedoes_fired > 0 else 0.0
	
	print("\n=== TUNING CYCLE %d RESULTS ===" % total_cycles)
	print("Cycle Duration: %.1f seconds" % cycle_time)
	print("Hit Rate: %d/%d (%.1f%%)" % [torpedoes_hit, torpedoes_fired, hit_rate])
	
	# Call the final parameters print if this is a good cycle
	if hit_rate > 80.0:
		print("Good hit rate! Current parameters:")
		print_final_tuned_parameters()
	
	# Update UI statistics
	var stats_text = parameter_container.get_node_or_null("StatsText")
	if stats_text:
		var text = "[b]Cycle %d Complete[/b]\n" % total_cycles
		text += "Duration: %.1fs\n" % cycle_time
		text += "Hit Rate: %d/%d ([color=%s]%.1f%%[/color])\n" % [
			torpedoes_hit, torpedoes_fired,
			"green" if hit_rate > 80 else "yellow" if hit_rate > 50 else "red",
			hit_rate
		]
		stats_text.text = text

func reset_cycle_stats():
	torpedoes_fired = 0
	torpedoes_hit = 0
	cycle_start_time = Time.get_ticks_msec() / 1000.0

func print_final_tuned_parameters():
	print("\n" + "=".repeat(60))
	print("FINAL TUNED PARAMETERS - %s TORPEDO" % get_torpedo_type_name(current_torpedo_type))
	print("=".repeat(60))
	
	print("\n# Copy these values to your torpedo configuration:")
	print("# Layer 1 Parameters:")
	for slider_control in current_layer1_sliders:
		if slider_control.container.visible:
			print("%s = %.3f" % [slider_control.param_name, slider_control.slider.value])
	
	print("\n# Layer 2 Parameters:")
	for key in layer2_sliders:
		var control = layer2_sliders[key]
		print("%s = %.3f" % [control.param_name, control.slider.value])
	
	print("\n" + "=".repeat(60))

# Inner class for slider controls
class SliderControl extends RefCounted:
	var container: HBoxContainer
	var slider: HSlider
	var label: Label
	var value_label: Label
	var background: ColorRect
	var param_name: String
	var layer: int
	var performance_score: float = 1.0
	
	func update_performance_color():
		var color: Color
		if performance_score > 0.95:
			color = Color.GREEN
		elif performance_score > 0.85:
			color = Color.YELLOW
		elif performance_score > 0.70:
			color = Color.ORANGE
		else:
			color = Color.RED
		
		if background:
			background.color = color.darkened(0.7)
			background.color.a = 0.5
