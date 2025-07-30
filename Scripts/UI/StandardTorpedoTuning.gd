# Scripts/UI/StandardTorpedoTuning.gd
extends Control
class_name StandardTorpedoTuning

# Tuning state machine
enum TuningState {
	WAITING_TO_FIRE,
	TORPEDO_IN_FLIGHT,
	ANALYZING_RESULTS,
	RESETTING_SCENARIO
}

var current_state: TuningState = TuningState.WAITING_TO_FIRE
var auto_fire_enabled: bool = true

# Tuning parameters
var current_parameters: Dictionary = {
	"navigation_constant": 3.0,
	"terminal_deceleration": 0.6
}

# Metrics tracking
var current_cycle: int = 0
var total_hits: int = 0
var total_cycles: int = 0
var recent_metrics: Array = []  # Last 10 CycleMetrics
var max_recent_metrics: int = 10

# Performance trend tracking
var performance_history: Array = []  # For analyzing trends
var best_parameters: Dictionary = {}
var best_hit_rate: float = 0.0

# References
var player_ship: Node2D
var enemy_ship: Node2D
var active_torpedo: StandardTorpedo = null

# UI Elements (to be created in scene)
@onready var auto_fire_checkbox: CheckBox = $VBoxContainer/HeaderPanel/HBoxContainer/AutoFireCheckBox
@onready var cycle_label: Label = $VBoxContainer/HeaderPanel/HBoxContainer/CycleLabel
@onready var hit_rate_label: Label = $VBoxContainer/HeaderPanel/HBoxContainer/HitRateLabel
@onready var nav_slider: HSlider = $VBoxContainer/ParametersPanel/VBoxContainer/HBoxContainer/NavConstantSlider
@onready var nav_value_label: Label = $VBoxContainer/ParametersPanel/VBoxContainer/HBoxContainer/NavValueLabel
@onready var decel_slider: HSlider = $VBoxContainer/ParametersPanel/VBoxContainer/HBoxContainer2/TerminalDecelSlider
@onready var decel_value_label: Label = $VBoxContainer/ParametersPanel/VBoxContainer/HBoxContainer2/DecelValueLabel
@onready var status_label: Label = $VBoxContainer/StatusPanel/VBoxContainer/StatusLabel
@onready var metrics_label: RichTextLabel = $VBoxContainer/StatusPanel/VBoxContainer/MetricsLabel

# Scene positions for reset
const PLAYER_START_POS = Vector2(-64000, 35500)
const PLAYER_START_ROT = 0.785398  # 45 degrees
const ENEMY_START_POS = Vector2(60000, -33000)
const ENEMY_START_ROT = -2.35619   # -135 degrees

signal tuning_cycle_complete(metrics: TorpedoDataStructures.CycleMetrics)

func _ready():
	print("StandardTorpedoTuning _ready() called")
	
	# Only active in MPC tuning mode
	if GameMode.current_mode != GameMode.Mode.MPC_TUNING:
		print("StandardTorpedoTuning: Not in MPC tuning mode, hiding UI")
		visible = false
		set_process(false)
		return
	
	# Find ships
	find_ships()
	
	# Connect UI if elements exist
	if auto_fire_checkbox:
		auto_fire_checkbox.toggled.connect(_on_auto_fire_toggled)
		auto_fire_checkbox.button_pressed = true
	if nav_slider:
		nav_slider.value_changed.connect(_on_nav_constant_changed)
		nav_slider.value = current_parameters.navigation_constant
	if decel_slider:
		decel_slider.value_changed.connect(_on_terminal_decel_changed)
		decel_slider.value = current_parameters.terminal_deceleration
	
	# Connect our own signal for analytics
	tuning_cycle_complete.connect(_on_tuning_cycle_complete)
	
	# Initialize best parameters
	best_parameters = current_parameters.duplicate()
	
	# Update UI
	update_ui()
	
	print("StandardTorpedoTuning initialized successfully")

func find_ships():
	var player_ships = get_tree().get_nodes_in_group("player_ships")
	if player_ships.size() > 0:
		player_ship = player_ships[0]
		print("StandardTorpedoTuning: Found player ship")
	else:
		push_error("StandardTorpedoTuning: No player ship found!")
	
	var enemy_ships = get_tree().get_nodes_in_group("enemy_ships")
	if enemy_ships.size() > 0:
		enemy_ship = enemy_ships[0]
		print("StandardTorpedoTuning: Found enemy ship")
	else:
		push_error("StandardTorpedoTuning: No enemy ship found!")

func _process(_delta):
	if not visible:
		return
	
	# State machine
	match current_state:
		TuningState.WAITING_TO_FIRE:
			if auto_fire_enabled:
				fire_test_torpedo()
		
		TuningState.TORPEDO_IN_FLIGHT:
			if active_torpedo:
				update_live_torpedo_status()
		
		TuningState.ANALYZING_RESULTS:
			# Analysis happens in event handlers
			pass
		
		TuningState.RESETTING_SCENARIO:
			# Reset happens in timer callback
			pass

func fire_test_torpedo():
	if not player_ship or not enemy_ship:
		find_ships()
		return
	
	if not player_ship.has_node("TorpedoLauncher"):
		print("ERROR: Player ship has no torpedo launcher!")
		return
	
	# Fire torpedo
	var launcher = player_ship.get_node("TorpedoLauncher")
	launcher.fire_torpedo(enemy_ship, 1)  # Fire single torpedo
	
	current_state = TuningState.TORPEDO_IN_FLIGHT
	total_cycles += 1
	current_cycle = total_cycles
	
	# Wait for torpedo to spawn and connect to it
	await get_tree().process_frame
	
	# Find the torpedo that was just launched
	var torpedoes = get_tree().get_nodes_in_group("torpedoes")
	for torpedo in torpedoes:
		if torpedo is StandardTorpedo and not torpedo.marked_for_death:
			active_torpedo = torpedo
			
			# Apply current tuning parameters
			torpedo.set_tuning_parameters(current_parameters)
			
			# Connect to torpedo signals using the corrected signal names
			torpedo.hit_target.connect(_on_torpedo_hit)
			torpedo.missed_target.connect(_on_torpedo_missed)
			torpedo.timed_out.connect(_on_torpedo_timeout)
			
			if DebugConfig.should_log("mpc_tuning"):
				print("[Tuning] Cycle %d: Torpedo %s launched" % [current_cycle, torpedo.torpedo_id])
			break
	
	update_ui()

func _on_torpedo_hit(torpedo: StandardTorpedo, impact_data: TorpedoDataStructures.ImpactData):
	if torpedo != active_torpedo:
		return
	
	total_hits += 1
	
	var metrics = create_cycle_metrics(torpedo, true, impact_data, null)
	recent_metrics.append(metrics)
	if recent_metrics.size() > max_recent_metrics:
		recent_metrics.pop_front()
	
	if DebugConfig.should_log("mpc_tuning"):
		print("[Tuning] Cycle %d: HIT! Flight time: %.2fs, Terminal alignment: %.2f" % 
			  [current_cycle, metrics.flight_time, metrics.terminal_alignment])
	
	emit_signal("tuning_cycle_complete", metrics)
	
	current_state = TuningState.ANALYZING_RESULTS
	analyze_and_reset()

func _on_torpedo_missed(torpedo: StandardTorpedo, miss_data: TorpedoDataStructures.MissData):
	if torpedo != active_torpedo:
		return
	
	var metrics = create_cycle_metrics(torpedo, false, null, miss_data)
	recent_metrics.append(metrics)
	if recent_metrics.size() > max_recent_metrics:
		recent_metrics.pop_front()
	
	if DebugConfig.should_log("mpc_tuning"):
		print("[Tuning] Cycle %d: MISS! Reason: %s, Closest: %.1fm" % 
			  [current_cycle, miss_data.miss_reason, miss_data.closest_approach_distance])
	
	emit_signal("tuning_cycle_complete", metrics)
	
	current_state = TuningState.ANALYZING_RESULTS
	analyze_and_reset()

func _on_torpedo_timeout(torpedo: StandardTorpedo):
	# The timeout signal is used to log specific timeout information
	if torpedo != active_torpedo:
		return
	
	var flight_time = (Time.get_ticks_msec() / 1000.0) - torpedo.launch_time
	
	if DebugConfig.should_log("mpc_tuning"):
		print("[Tuning] Cycle %d: TIMEOUT after %.1fs flight" % [current_cycle, flight_time])
		
		# Log torpedo state at timeout
		var speed = torpedo.velocity_mps.length()
		var fuel_percent = (torpedo.current_fuel / torpedo.fuel_mass) * 100.0
		print("  Final state: Speed=%.0f m/s, Fuel=%.1f%%, Phase=%s" % 
			  [speed, fuel_percent, torpedo.flight_phase])

func _on_tuning_cycle_complete(metrics: TorpedoDataStructures.CycleMetrics):
	# Track performance trends and evolution
	performance_history.append({
		"cycle": current_cycle,
		"hit": metrics.hit_result,
		"parameters": current_parameters.duplicate(),
		"metrics": metrics
	})
	
	# Update best parameters if we're doing better
	var current_hit_rate = float(total_hits) / float(total_cycles)
	if current_hit_rate > best_hit_rate:
		best_hit_rate = current_hit_rate
		best_parameters = current_parameters.duplicate()
		
		if DebugConfig.should_log("mpc_evolution"):
			print("[Tuning Evolution] NEW BEST! Hit rate: %.1f%% with N=%.2f, TD=%.2f" % 
				  [best_hit_rate * 100.0, best_parameters.navigation_constant, 
				   best_parameters.terminal_deceleration])
	
	# Analyze recent performance trends
	if recent_metrics.size() >= 5:
		var recent_hits = 0
		var avg_flight_time = 0.0
		var avg_terminal_alignment = 0.0
		
		for m in recent_metrics:
			if m.hit_result:
				recent_hits += 1
				avg_terminal_alignment += m.terminal_alignment
			avg_flight_time += m.flight_time
		
		avg_flight_time /= recent_metrics.size()
		if recent_hits > 0:
			avg_terminal_alignment /= recent_hits
		
		var recent_rate = float(recent_hits) / float(recent_metrics.size()) * 100.0
		
		if DebugConfig.should_log("mpc_evolution"):
			print("[Tuning Evolution] Last 5 cycles: %.1f%% hit rate, avg flight: %.1fs" % 
				  [recent_rate, avg_flight_time])
			if recent_hits > 0:
				print("  Average terminal alignment for hits: %.2f" % avg_terminal_alignment)

func create_cycle_metrics(torpedo: StandardTorpedo, hit: bool, 
						 impact_data: TorpedoDataStructures.ImpactData,
						 miss_data: TorpedoDataStructures.MissData) -> TorpedoDataStructures.CycleMetrics:
	var metrics = TorpedoDataStructures.CycleMetrics.new()
	
	metrics.hit_result = hit
	metrics.flight_time = (Time.get_ticks_msec() / 1000.0) - torpedo.launch_time
	
	if hit and impact_data:
		metrics.miss_distance = 0.0
		metrics.terminal_alignment = 1.0 - (impact_data.impact_angle / PI)
		metrics.terminal_velocity = impact_data.impact_velocity.length()
	elif miss_data:
		metrics.miss_distance = miss_data.closest_approach_distance
		metrics.terminal_alignment = 0.0
		metrics.terminal_velocity = torpedo.velocity_mps.length()
	
	metrics.average_speed = torpedo.total_distance_traveled / metrics.flight_time if metrics.flight_time > 0 else 0
	metrics.max_acceleration = torpedo.max_thrust_mps2
	metrics.control_smoothness = torpedo.get_control_smoothness()
	
	return metrics

func analyze_and_reset():
	# Clean up torpedo reference
	active_torpedo = null
	
	# Wait a moment before resetting
	await get_tree().create_timer(1.0).timeout
	
	current_state = TuningState.RESETTING_SCENARIO
	reset_ships()

func reset_ships():
	# Reset player ship
	if player_ship and player_ship.has_method("reset_for_mpc_cycle"):
		player_ship.reset_for_mpc_cycle()
	
	# Reset enemy ship
	if enemy_ship and enemy_ship.has_method("reset_for_mpc_cycle"):
		enemy_ship.reset_for_mpc_cycle()
	
	# Reset torpedo launcher
	if player_ship and player_ship.has_node("TorpedoLauncher"):
		var launcher = player_ship.get_node("TorpedoLauncher")
		if launcher.has_method("reset_all_tubes"):
			launcher.reset_all_tubes()
	
	# Small delay before next cycle
	await get_tree().create_timer(0.5).timeout
	
	current_state = TuningState.WAITING_TO_FIRE
	update_ui()

func update_ui():
	if not visible:
		return
	
	# Update labels
	if cycle_label:
		cycle_label.text = "Cycle: %d" % current_cycle
	
	if hit_rate_label:
		var hit_rate = 0.0
		if total_cycles > 0:
			hit_rate = (float(total_hits) / float(total_cycles)) * 100.0
		hit_rate_label.text = "Hits: %d/%d (%.1f%%)" % [total_hits, total_cycles, hit_rate]
	
	if nav_value_label:
		nav_value_label.text = "%.2f" % current_parameters.navigation_constant
	
	if decel_value_label:
		decel_value_label.text = "%.2f" % current_parameters.terminal_deceleration
	
	# Update status
	if status_label:
		match current_state:
			TuningState.WAITING_TO_FIRE:
				status_label.text = "Status: Ready to fire"
			TuningState.TORPEDO_IN_FLIGHT:
				status_label.text = "Status: Torpedo in flight"
			TuningState.ANALYZING_RESULTS:
				status_label.text = "Status: Analyzing results"
			TuningState.RESETTING_SCENARIO:
				status_label.text = "Status: Resetting scenario"
	
	# Update recent metrics display
	update_metrics_display()

func update_live_torpedo_status():
	if not active_torpedo or not status_label:
		return
	
	var distance_to_target = 0.0
	if enemy_ship:
		distance_to_target = active_torpedo.global_position.distance_to(enemy_ship.global_position)
		distance_to_target *= WorldSettings.meters_per_pixel
	
	var speed = active_torpedo.velocity_mps.length()
	var phase = active_torpedo.flight_phase
	var alignment = active_torpedo.control_commands.alignment_quality if active_torpedo.control_commands else 0.0
	
	status_label.text = "Phase: %s | Speed: %.0f m/s | Distance: %.0fm | Alignment: %.2f" % [
		phase.capitalize(), speed, distance_to_target, alignment
	]

func update_metrics_display():
	if not metrics_label:
		return
	
	var text = "[b]Recent Results:[/b]\n"
	
	# Show recent results with best parameters highlighted
	for i in range(recent_metrics.size() - 1, max(recent_metrics.size() - 6, -1), -1):
		var m = recent_metrics[i]
		var result = "HIT" if m.hit_result else "MISS"
		var color = "green" if m.hit_result else "red"
		
		text += "[color=%s]%s[/color] - %.1fs flight, " % [color, result]
		
		if m.hit_result:
			text += "alignment: %.2f, smoothness: %.2f\n" % [m.terminal_alignment, m.control_smoothness]
		else:
			text += "miss by: %.0fm\n" % m.miss_distance
	
	# Add best parameters info if we have enough data
	if total_cycles >= 10:
		text += "\n[b]Best Parameters:[/b]\n"
		text += "Hit Rate: %.1f%% with N=%.2f, TD=%.2f" % [
			best_hit_rate * 100.0, 
			best_parameters.navigation_constant,
			best_parameters.terminal_deceleration
		]
	
	metrics_label.bbcode_text = text

# UI callbacks
func _on_auto_fire_toggled(pressed: bool):
	auto_fire_enabled = pressed
	if DebugConfig.should_log("mpc_tuning"):
		print("[Tuning] Auto-fire %s" % ("enabled" if pressed else "disabled"))

func _on_nav_constant_changed(value: float):
	current_parameters.navigation_constant = value
	if nav_value_label:
		nav_value_label.text = "%.2f" % value

func _on_terminal_decel_changed(value: float):
	current_parameters.terminal_deceleration = value
	if decel_value_label:
		decel_value_label.text = "%.2f" % value

# Public interface
func start_tuning():
	visible = true
	set_process(true)
	current_state = TuningState.WAITING_TO_FIRE
	print("StandardTorpedoTuning: Tuning started")

func stop_tuning():
	visible = false
	set_process(false)
	auto_fire_enabled = false
	
	# Clean up any active torpedo
	if active_torpedo:
		active_torpedo.mark_for_destruction("tuning_stopped")
		active_torpedo = null
	
	# Print final summary
	if DebugConfig.should_log("mpc_evolution") and total_cycles > 0:
		print("[Tuning Summary] Total cycles: %d, Hit rate: %.1f%%" % 
			  [total_cycles, (float(total_hits) / float(total_cycles)) * 100.0])
		print("  Best parameters: N=%.2f, TD=%.2f (%.1f%% hit rate)" % 
			  [best_parameters.navigation_constant, 
			   best_parameters.terminal_deceleration,
			   best_hit_rate * 100.0])
