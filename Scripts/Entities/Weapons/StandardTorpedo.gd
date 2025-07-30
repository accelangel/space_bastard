# Scripts/Entities/Weapons/StandardTorpedo.gd
extends Area2D
class_name StandardTorpedo

# Torpedo identity
var torpedo_id: String = ""
var faction: String = "friendly"
var source_ship_id: String = ""
var launch_time: float = 0.0

# State management
var is_alive: bool = true
var marked_for_death: bool = false
var flight_phase: String = "launch"  # "launch", "acceleration", "midcourse", "terminal", "impact"

# Layer update timers
var mission_timer: float = 0.0
var guidance_timer: float = 0.0
const MISSION_UPDATE_INTERVAL: float = 1.0    # 1 Hz
const GUIDANCE_UPDATE_INTERVAL: float = 0.1   # 10 Hz

# Layer states
var mission_directive: TorpedoDataStructures.MissionDirective
var guidance_state: TorpedoDataStructures.GuidanceState
var control_commands: TorpedoDataStructures.ControlCommands
var physics_state: TorpedoDataStructures.TorpedoPhysicsState

# Layer references
var mission_layer: TorpedoMissionLayer
var guidance_layer: TorpedoGuidanceLayer
var control_layer: TorpedoControlLayer

# Physics parameters
@export var max_thrust_mps2: float = 500.0      # Maximum acceleration in m/s²
@export var max_rotation_speed: float = 10.0     # rad/s
@export var exhaust_velocity: float = 3000.0     # m/s for specific impulse
@export var dry_mass: float = 50.0               # kg without fuel
@export var fuel_mass: float = 50.0              # kg of fuel
@export var burn_rate: float = 5.0               # kg/s fuel consumption at max thrust

# Terminal phase parameters
@export var terminal_phase_distance: float = 2000.0  # meters
@export var terminal_deceleration_factor: float = 0.6  # Thrust reduction in terminal

# Current physics state
var velocity_mps: Vector2 = Vector2.ZERO
var current_fuel: float = 0.0
var current_mass: float = 0.0

# Trail visualization
var trail_points: PackedVector2Array = []
var max_trail_points: int = 100

# Performance tracking
var launch_position: Vector2 = Vector2.ZERO
var total_distance_traveled: float = 0.0
var max_speed_achieved: float = 0.0
var last_position: Vector2 = Vector2.ZERO
var control_smoothness_accumulator: float = 0.0
var smoothness_samples: int = 0

# Debug
@export var debug_enabled: bool = false

# Signals for external systems to connect to
signal hit_target(torpedo: StandardTorpedo, impact_data: TorpedoDataStructures.ImpactData)
signal missed_target(torpedo: StandardTorpedo, miss_data: TorpedoDataStructures.MissData)
signal timed_out(torpedo: StandardTorpedo)

func _ready():
	# Generate unique ID
	torpedo_id = "torpedo_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	launch_time = Time.get_ticks_msec() / 1000.0
	
	# Initialize data structures FIRST (before they can be used)
	mission_directive = TorpedoDataStructures.MissionDirective.new()
	guidance_state = TorpedoDataStructures.GuidanceState.new()
	control_commands = TorpedoDataStructures.ControlCommands.new()
	physics_state = TorpedoDataStructures.TorpedoPhysicsState.new()
	
	# Initialize physics
	current_fuel = fuel_mass
	current_mass = dry_mass + fuel_mass
	launch_position = global_position
	last_position = global_position
	
	# Create layer instances
	mission_layer = TorpedoMissionLayer.new()
	guidance_layer = TorpedoGuidanceLayer.new()
	control_layer = TorpedoControlLayer.new()
	
	# Configure layers
	mission_layer.configure(self)
	guidance_layer.configure(self)
	control_layer.configure(self)
	
	# Update initial physics state
	update_physics_state()
	
	# Groups and metadata
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	# Connect collision
	area_entered.connect(_on_area_entered)
	
	# Start animation
	if has_node("AnimatedSprite2D"):
		$AnimatedSprite2D.play()
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_spawned", self, "torpedo")
	
	if debug_enabled:
		print("[StandardTorpedo] %s launched" % torpedo_id)

func _physics_process(delta):
	if marked_for_death or not is_alive:
		return
	
	# Update layer timers
	mission_timer += delta
	guidance_timer += delta
	
	# Mission layer update (1 Hz)
	if mission_timer >= MISSION_UPDATE_INTERVAL:
		mission_timer = 0.0
		mission_directive = mission_layer.update_mission(mission_directive)
		check_abort_conditions()
	
	# Guidance layer update (10 Hz)
	if guidance_timer >= GUIDANCE_UPDATE_INTERVAL:
		guidance_timer = 0.0
		update_physics_state()
		guidance_state = guidance_layer.update_guidance(mission_directive, physics_state)
		update_flight_phase()
	
	# Control layer update (60 Hz)
	update_physics_state()
	control_commands = control_layer.update_control(guidance_state, physics_state)
	
	# Apply control commands
	apply_control_commands(delta)
	
	# Update position and rotation
	update_torpedo_physics(delta)
	
	# Update trail
	update_trail()
	
	# Performance tracking
	track_performance(delta)

func update_physics_state():
	physics_state.position = global_position
	physics_state.velocity = velocity_mps / WorldSettings.meters_per_pixel
	physics_state.rotation = rotation
	physics_state.mass = current_mass

func apply_control_commands(delta: float):
	# Apply rotation
	rotation += control_commands.rotation_rate * delta
	
	# Apply thrust if we have fuel
	if current_fuel > 0 and control_commands.thrust_magnitude > 0:
		var thrust_force = max_thrust_mps2 * control_commands.thrust_magnitude
		var thrust_direction = Vector2.from_angle(rotation - PI/2)  # Adjust for sprite orientation
		var acceleration = thrust_direction * thrust_force
		
		# Update velocity
		velocity_mps += acceleration * delta
		
		# Consume fuel
		var fuel_consumed = burn_rate * control_commands.thrust_magnitude * delta
		fuel_consumed = min(fuel_consumed, current_fuel)
		current_fuel -= fuel_consumed
		current_mass = dry_mass + current_fuel

func update_torpedo_physics(delta: float):
	# Convert to pixels and update position
	var velocity_pixels = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels * delta
	
	# Check bounds
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		mark_for_destruction("out_of_bounds")

func update_flight_phase():
	var old_phase = flight_phase
	
	# Determine phase based on guidance state
	match guidance_state.guidance_mode:
		"accelerate":
			if flight_phase == "launch":
				flight_phase = "acceleration"
			else:
				flight_phase = "midcourse"
		"terminal":
			flight_phase = "terminal"
		"coast":
			if current_fuel <= 0:
				flight_phase = "coast"
	
	if old_phase != flight_phase and debug_enabled:
		print("[StandardTorpedo] %s phase changed: %s -> %s" % [torpedo_id, old_phase, flight_phase])

func check_abort_conditions():
	# Timeout check
	var flight_time = (Time.get_ticks_msec() / 1000.0) - launch_time
	if flight_time > 30.0:  # 30 second timeout
		var miss_data = TorpedoDataStructures.MissData.new()
		miss_data.miss_reason = "timeout"
		miss_data.time_of_miss = Time.get_ticks_msec() / 1000.0
		if mission_directive.target_node and is_instance_valid(mission_directive.target_node):
			miss_data.closest_approach_distance = global_position.distance_to(mission_directive.target_node.global_position) * WorldSettings.meters_per_pixel
		emit_signal("timed_out", self)
		emit_signal("missed_target", self, miss_data)
		mark_for_destruction("timeout")
		return
	
	# Lost target check
	if not mission_directive.target_node or not is_instance_valid(mission_directive.target_node):
		var miss_data = TorpedoDataStructures.MissData.new()
		miss_data.miss_reason = "lost_track"
		miss_data.time_of_miss = Time.get_ticks_msec() / 1000.0
		emit_signal("missed_target", self, miss_data)
		mark_for_destruction("lost_target")

func update_trail():
	trail_points.append(global_position)
	if trail_points.size() > max_trail_points:
		trail_points.remove_at(0)
	queue_redraw()

func track_performance(delta: float):
	# Distance traveled
	var distance_this_frame = global_position.distance_to(last_position)
	total_distance_traveled += distance_this_frame
	last_position = global_position
	
	# Max speed
	var current_speed = velocity_mps.length()
	if current_speed > max_speed_achieved:
		max_speed_achieved = current_speed
	
	# Track control smoothness
	if control_commands:
		var current_rotation_rate = abs(control_commands.rotation_rate)
		control_smoothness_accumulator += current_rotation_rate * delta
		smoothness_samples += 1

func get_control_smoothness() -> float:
	if smoothness_samples == 0:
		return 1.0
	# Lower values = smoother control
	var avg_rotation_rate = control_smoothness_accumulator / smoothness_samples
	return 1.0 - clamp(avg_rotation_rate / max_rotation_speed, 0.0, 1.0)

func _draw():
	if not debug_enabled:
		return
	
	# Draw trail
	if trail_points.size() > 1:
		for i in range(1, trail_points.size()):
			var start = trail_points[i-1] - global_position
			var end = trail_points[i] - global_position
			var alpha = float(i) / float(trail_points.size())
			draw_line(start, end, Color(1, 0.5, 0, alpha), 2.0)
	
	# Draw velocity vector
	var vel_end = velocity_mps.normalized() * 50.0 / WorldSettings.meters_per_pixel
	draw_line(Vector2.ZERO, vel_end, Color.GREEN, 2.0)
	
	# Draw heading
	var heading_end = Vector2.from_angle(rotation - PI/2) * 40.0
	draw_line(Vector2.ZERO, heading_end, Color.CYAN, 2.0)

func _on_area_entered(area: Area2D):
	if marked_for_death:
		return
	
	# Check for ship collision
	if area.is_in_group("ships"):
		# Don't hit friendly ships
		if area.get("faction") == faction:
			return
		
		# Target hit!
		var impact_data = TorpedoDataStructures.ImpactData.new()
		impact_data.impact_position = global_position
		impact_data.impact_velocity = velocity_mps
		impact_data.impact_angle = abs(angle_difference(rotation, velocity_mps.angle()))
		impact_data.target_id = area.get("entity_id") if "entity_id" in area else ""
		impact_data.time_of_impact = Time.get_ticks_msec() / 1000.0
		
		emit_signal("hit_target", self, impact_data)
		mark_for_destruction("target_impact")

func angle_difference(a: float, b: float) -> float:
	var diff = fmod(b - a + PI, TAU) - PI
	return diff

# Public interface for launcher
func set_target(target: Node2D):
	if not mission_directive:
		push_error("StandardTorpedo: mission_directive is null in set_target!")
		return
	mission_directive.target_node = target
	mission_directive.mission_start_time = Time.get_ticks_msec() / 1000.0
	mission_directive.mission_id = "%s_mission" % torpedo_id

func set_launcher(launcher: Node2D):
	if "entity_id" in launcher:
		source_ship_id = launcher.entity_id

func set_launch_side(_side: int):
	# Not used for standard torpedoes
	pass

func set_flight_plan(_plan: String, _data: Dictionary = {}):
	# Standard torpedoes always use direct attack
	pass

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	# Disable physics
	set_physics_process(false)
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = true
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	# Cleanup
	queue_free()

func get_velocity_mps() -> Vector2:
	return velocity_mps

# Tuning interface
func get_tuning_parameters() -> Dictionary:
	return {
		"navigation_constant": control_layer.navigation_constant if control_layer else 3.0,
		"terminal_deceleration": guidance_layer.terminal_deceleration_factor if guidance_layer else 0.6
	}

func set_tuning_parameters(params: Dictionary):
	if "navigation_constant" in params and control_layer:
		control_layer.navigation_constant = params.navigation_constant
	if "terminal_deceleration" in params and guidance_layer:
		guidance_layer.terminal_deceleration_factor = params.terminal_deceleration
