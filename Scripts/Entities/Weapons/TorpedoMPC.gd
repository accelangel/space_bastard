# Scripts/Entities/Weapons/TorpedoMPC.gd - Enhanced Version
extends Area2D
class_name TorpedoMPC

# Identity
@export var torpedo_id: String = ""
@export var birth_time: float = 0.0
@export var faction: String = "hostile"
@export var source_ship_id: String = ""

# State management
var is_alive: bool = true
var marked_for_death: bool = false
var death_reason: String = ""

# Core properties
var target_node: Node2D
var launcher_ship: Node2D

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var orientation: float = 0.0
var angular_velocity: float = 0.0
var max_speed_mps: float = 2000.0
var max_acceleration: float = 490.5  # 50G
var max_rotation_rate: float = deg_to_rad(1080.0)

# MPC Controller (only used if batch system unavailable)
var mpc_controller: MPCController = null

# Batch update system
var batch_manager: Node = null
var use_batch_updates: bool = true
var frames_since_update: int = 0
var max_frames_between_updates: int = 3
var last_update_time: float = 0.0
var last_control: Dictionary = {"thrust": 0.0, "rotation_rate": 0.0}

# Trajectory caching support
var cached_trajectory: Dictionary = {}
var trajectory_valid_until: float = 0.0
var using_cached_trajectory: bool = false

# Template tracking (for evolution feedback)
var assigned_template_index: int = -1
var template_performance: float = 0.0

# Flight plan configuration
var flight_plan_type: String = "straight"
var flight_plan_data: Dictionary = {}

# Launch system
var launch_side: int = 1
var engines_ignited: bool = false
var launch_start_time: float = 0.0
var engine_ignition_time: float = 0.0
var lateral_launch_velocity: float = 60.0
var lateral_launch_distance: float = 80.0
var engine_ignition_delay: float = 1.6
var lateral_distance_traveled: float = 0.0

# Miss detection
var miss_detection_timer: float = 0.0
var miss_detection_threshold: float = 2.0
var max_lifetime: float = 30.0
var closest_approach_distance: float = INF
var has_passed_target: bool = false

# Performance tracking
var control_history: Array = []
var trajectory_smoothness: float = 0.0
var total_control_changes: float = 0.0
var alignment_quality: float = 0.0
var computation_times: Array = []

# Debug
var debug_trail: PackedVector2Array = []
var max_trail_points: int = 100
var debug_enabled: bool = false

func _ready():
	# Generate ID
	if torpedo_id == "":
		torpedo_id = "torpedo_mpc_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	birth_time = Time.get_ticks_msec() / 1000.0
	launch_start_time = birth_time
	
	# Check for batch manager
	if use_batch_updates:
		batch_manager = get_node_or_null("/root/BatchMPCManager")
		if batch_manager and batch_manager.has_method("register_torpedo"):
			batch_manager.register_torpedo(self)
			print("TorpedoMPC %s: Registered with enhanced batch manager" % torpedo_id)
		else:
			print("TorpedoMPC %s: No batch manager found, using individual MPC" % torpedo_id)
			use_batch_updates = false
			# Create individual MPC controller as fallback
			mpc_controller = MPCController.new()
			mpc_controller.max_acceleration = max_acceleration
			mpc_controller.max_rotation_rate = max_rotation_rate
			mpc_controller.max_speed = max_speed_mps
	
	# Groups
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	# Enable input for debug
	set_process_unhandled_input(true)
	
	# Metadata
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	set_meta("source_ship_id", source_ship_id)
	
	# Validate target
	if not is_valid_target(target_node):
		print("TorpedoMPC %s: No valid target, self-destructing" % torpedo_id)
		mark_for_destruction("no_target")
		return
	
	# Initialize physics
	if launcher_ship:
		if launcher_ship.has_method("get_velocity_mps"):
			velocity_mps = launcher_ship.get_velocity_mps()
		
		var ship_forward = Vector2.UP.rotated(launcher_ship.rotation)
		orientation = ship_forward.angle()
		rotation = orientation
		
		var side_direction = Vector2(-ship_forward.y, ship_forward.x) * launch_side
		velocity_mps += side_direction * lateral_launch_velocity
		
		if "entity_id" in launcher_ship:
			source_ship_id = launcher_ship.entity_id
	
	# Connect collision
	area_entered.connect(_on_area_entered)
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_spawned", self, "torpedo")
	
	if debug_enabled:
		print("TorpedoMPC %s launched - Type: %s" % [torpedo_id, flight_plan_type])

func _physics_process(delta):
	if marked_for_death or not is_alive:
		return
	
	# Validate target
	if not is_valid_target(target_node):
		target_node = null
		mark_for_destruction("target_lost")
		return
	
	var current_time = Time.get_ticks_msec() / 1000.0
	var time_since_launch = current_time - launch_start_time
	
	# Check lifetime
	if time_since_launch > max_lifetime:
		report_miss("max_lifetime")
		mark_for_destruction("max_lifetime")
		return
	
	# Launch phase
	if not engines_ignited:
		var distance_this_frame = velocity_mps.length() * delta
		lateral_distance_traveled += distance_this_frame
		
		if should_ignite_engines(time_since_launch):
			ignite_engines()
			engine_ignition_time = current_time
	
	# Main control update
	if engines_ignited and target_node:
		update_mpc_control(delta)
		check_miss_conditions(delta)
	
	# Update position
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Update visual rotation
	rotation = orientation
	
	# Bounds check
	check_out_of_bounds()
	
	# Debug trail
	update_debug_trail()
	
	# Report position occasionally
	if Engine.get_physics_frames() % 10 == 0:
		get_tree().call_group("battle_observers", "on_entity_moved", self, global_position)

func update_mpc_control(delta: float):
	"""Main MPC control update - enhanced with caching and smart scheduling"""
	
	# Check if we have a valid cached trajectory
	var current_time = Time.get_ticks_msec() / 1000.0
	if using_cached_trajectory and current_time < trajectory_valid_until:
		# Apply cached control
		apply_control(cached_trajectory.control, delta)
		update_performance_metrics(cached_trajectory.control, delta)
		return
	
	using_cached_trajectory = false
	
	if use_batch_updates and batch_manager:
		# Calculate update priority
		var update_priority = calculate_update_priority()
		
		# Request batch update
		frames_since_update += 1
		
		# Only request if we haven't updated recently or priority is high
		if frames_since_update >= max_frames_between_updates or update_priority > 5.0:
			if batch_manager.has_method("request_update"):
				batch_manager.request_update(self, update_priority)
		
		# Apply last known control while waiting for update
		apply_control(last_control, delta)
		return
	
	# Fallback to individual MPC update
	if mpc_controller:
		var start_time = Time.get_ticks_usec()
		
		# Get current state
		var current_state = {
			"position": global_position,
			"velocity": velocity_mps,
			"orientation": orientation,
			"angular_velocity": angular_velocity
		}
		
		# Get target state
		var target_state = {
			"position": target_node.global_position,
			"velocity": get_target_velocity()
		}
		
		# Convert positions to world coordinates
		current_state.position *= WorldSettings.meters_per_pixel
		target_state.position *= WorldSettings.meters_per_pixel
		
		# Get MPC control
		var control = mpc_controller.update_trajectory(
			current_state,
			target_state,
			flight_plan_type,
			flight_plan_data,
			delta
		)
		
		# Track computation time
		var compute_time = (Time.get_ticks_usec() - start_time) / 1000000.0
		computation_times.append(compute_time)
		if computation_times.size() > 10:
			computation_times.pop_front()
		
		# Apply control
		apply_control(control, delta)
		update_performance_metrics(control, delta)
		last_control = control
		last_update_time = current_time

func calculate_update_priority() -> float:
	"""Calculate priority for batch update scheduling"""
	var priority = 1.0
	
	# Distance to target
	if target_node and is_instance_valid(target_node):
		var distance = global_position.distance_to(target_node.global_position)
		
		if distance < 2000:  # Very close
			priority = 10.0
		elif distance < 5000:  # Close
			priority = 5.0
		elif distance < 10000:  # Medium
			priority = 2.0
	
	# Time since launch
	var age = (Time.get_ticks_msec() / 1000.0) - launch_start_time
	if age < 2.0:  # Just launched
		priority *= 2.0
	
	# Frames since last update
	if frames_since_update > 5:
		priority *= 1.5
	
	# Trajectory quality - request more updates if trajectory is poor
	if trajectory_smoothness < 0.5:
		priority *= 1.5
	
	return priority

func apply_mpc_control(control: Dictionary):
	"""Apply control calculated by batch MPC system"""
	
	if not control.has("thrust") or not control.has("rotation_rate"):
		push_error("Invalid control dictionary from batch MPC")
		return
	
	# Reset update counter
	frames_since_update = 0
	last_update_time = Time.get_ticks_msec() / 1000.0
	
	# Store control for reuse
	last_control = control
	
	# Apply the control
	apply_control(control, get_physics_process_delta_time())
	
	# Update performance metrics
	update_performance_metrics(control, get_physics_process_delta_time())
	
	# Track template performance if assigned
	if assigned_template_index >= 0 and control.has("template_index"):
		if int(control.template_index) == assigned_template_index:
			# Template is performing well if still being selected
			template_performance += 0.1

func apply_cached_trajectory(trajectory_data: Dictionary):
	"""Apply a cached trajectory from the batch manager"""
	
	if not trajectory_data.has("control") or not trajectory_data.has("timestamp"):
		return
	
	cached_trajectory = trajectory_data
	trajectory_valid_until = trajectory_data.timestamp + 0.5  # Cache valid for 0.5 seconds
	using_cached_trajectory = true
	
	# Apply the cached control
	apply_control(trajectory_data.control, get_physics_process_delta_time())

func apply_control(control: Dictionary, delta: float):
	"""Apply MPC control output to torpedo physics"""
	
	# Update orientation
	orientation += control.rotation_rate * delta
	orientation = wrapf(orientation, -PI, PI)
	angular_velocity = control.rotation_rate
	
	# Update velocity
	var thrust_direction = Vector2.from_angle(orientation)
	var acceleration = thrust_direction * control.thrust
	velocity_mps += acceleration * delta
	
	# Apply speed limit
	if velocity_mps.length() > max_speed_mps:
		velocity_mps = velocity_mps.normalized() * max_speed_mps

func update_performance_metrics(control: Dictionary, delta: float):
	"""Track performance metrics for analysis and evolution feedback"""
	
	# Update control history
	control_history.append(control)
	if control_history.size() > 10:
		control_history.pop_front()
	
	# Calculate trajectory smoothness
	update_trajectory_smoothness()
	
	# Track total control changes
	if control_history.size() > 1:
		var prev = control_history[-2]
		var thrust_change = abs(control.thrust - prev.thrust)
		var rotation_change = abs(control.rotation_rate - prev.rotation_rate)
		total_control_changes += thrust_change / max_acceleration + rotation_change / max_rotation_rate
	
	# Track alignment quality
	if velocity_mps.length() > 10.0:
		var velocity_angle = velocity_mps.angle()
		var alignment_error = abs(angle_difference(orientation, velocity_angle))
		var instant_alignment = 1.0 - (alignment_error / PI)
		alignment_quality = lerp(alignment_quality, instant_alignment, 0.1)

func update_trajectory_smoothness():
	"""Calculate how smooth the control history is"""
	if control_history.size() < 2:
		trajectory_smoothness = 1.0
		return
	
	var total_change = 0.0
	for i in range(1, control_history.size()):
		var thrust_change = abs(control_history[i].thrust - control_history[i-1].thrust)
		var rotation_change = abs(control_history[i].rotation_rate - control_history[i-1].rotation_rate)
		total_change += thrust_change / max_acceleration + rotation_change / max_rotation_rate
	
	# Normalize to 0-1 range (1 = very smooth, 0 = very jerky)
	trajectory_smoothness = 1.0 / (1.0 + total_change)

func get_trajectory_smoothness() -> float:
	return trajectory_smoothness

func get_last_mpc_compute_time() -> float:
	"""Get average computation time for performance monitoring"""
	if computation_times.is_empty():
		return 0.0
	
	var sum = 0.0
	for time in computation_times:
		sum += time
	return sum / computation_times.size()

func should_ignite_engines(time_since_launch: float) -> bool:
	var distance_criteria_met = lateral_distance_traveled >= lateral_launch_distance
	var time_criteria_met = time_since_launch >= engine_ignition_delay
	return distance_criteria_met or time_criteria_met

func ignite_engines():
	engines_ignited = true
	if debug_enabled:
		print("TorpedoMPC %s: Engines ignited! Type: %s" % [torpedo_id, flight_plan_type])

func get_target_velocity() -> Vector2:
	if not target_node:
		return Vector2.ZERO
	
	if target_node.has_method("get_velocity_mps"):
		return target_node.get_velocity_mps()
	elif "velocity_mps" in target_node:
		return target_node.velocity_mps
	
	return Vector2.ZERO

func check_miss_conditions(delta: float):
	"""Check if torpedo has missed its target"""
	if not target_node:
		return
	
	var to_target = target_node.global_position - global_position
	var distance = to_target.length() * WorldSettings.meters_per_pixel
	
	# Track closest approach
	if distance < closest_approach_distance:
		closest_approach_distance = distance
		has_passed_target = false
		miss_detection_timer = 0.0
	
	# Check if moving away
	var closing_velocity = velocity_mps.dot(to_target.normalized())
	
	if closing_velocity < 0 and distance > 50.0:
		if not has_passed_target:
			has_passed_target = true
			if debug_enabled:
				print("TorpedoMPC %s: Passed target, distance %.1f m" % [torpedo_id, distance])
		
		miss_detection_timer += delta
		
		if miss_detection_timer >= miss_detection_threshold:
			report_miss("overshot")
			mark_for_destruction("missed_target")

func check_out_of_bounds():
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		report_miss("out_of_bounds")
		mark_for_destruction("out_of_bounds")

func is_valid_target(target: Node2D) -> bool:
	if not target:
		return false
	if not is_instance_valid(target):
		return false
	if not target.is_inside_tree():
		return false
	if target.has_method("is_alive") and not target.is_alive:
		return false
	if target.get("marked_for_death") and target.marked_for_death:
		return false
	return true

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	# Report template performance if using evolution
	if assigned_template_index >= 0 and batch_manager:
		var hit_success = (reason == "ship_impact")
		if batch_manager.has_method("report_template_performance"):
			batch_manager.report_template_performance(
				assigned_template_index,
				hit_success,
				trajectory_smoothness
			)
	
	# Unregister from batch manager
	if use_batch_updates and batch_manager and batch_manager.has_method("unregister_torpedo"):
		batch_manager.unregister_torpedo(torpedo_id)
	
	marked_for_death = true
	is_alive = false
	death_reason = reason
	
	set_physics_process(false)
	
	if has_node("CollisionShape2D"):
		call_deferred("_disable_collision")
	
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	queue_free()

func _disable_collision():
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = true

func _on_area_entered(area: Area2D):
	if marked_for_death:
		return
	
	# Collide with PDC bullets
	if area.is_in_group("bullets"):
		if area.get("faction") == faction:
			return
		
		area.set_meta("hit_target", torpedo_id)
		mark_for_destruction("bullet_impact")
		return
	
	# Collide with ships
	if area.is_in_group("ships"):
		if area.get("faction") == faction:
			return
		
		if debug_enabled:
			print("TorpedoMPC %s hit ship %s" % [torpedo_id, area.get("entity_id")])
		report_hit()
		mark_for_destruction("ship_impact")

func report_miss(reason: String):
	"""Report miss for analysis"""
	var miss_data = {
		"torpedo_id": torpedo_id,
		"flight_plan_type": flight_plan_type,
		"closest_approach": closest_approach_distance,
		"lifetime": (Time.get_ticks_msec() / 1000.0) - launch_start_time,
		"reason": reason,
		"trajectory_smoothness": trajectory_smoothness,
		"alignment_quality": alignment_quality,
		"total_control_changes": total_control_changes,
		"template_index": assigned_template_index
	}
	
	# Report to any listening systems
	get_tree().call_group("mpc_observers", "on_torpedo_miss", miss_data)

func report_hit():
	"""Report successful hit"""
	var hit_data = {
		"torpedo_id": torpedo_id,
		"flight_plan_type": flight_plan_type,
		"time_to_impact": (Time.get_ticks_msec() / 1000.0) - launch_start_time,
		"trajectory_smoothness": trajectory_smoothness,
		"alignment_quality": alignment_quality,
		"total_control_changes": total_control_changes,
		"template_index": assigned_template_index
	}
	
	# Report to any listening systems
	get_tree().call_group("mpc_observers", "on_torpedo_hit", hit_data)

func update_debug_trail():
	debug_trail.append(global_position)
	if debug_trail.size() > max_trail_points:
		debug_trail.remove_at(0)

func angle_difference(from: float, to: float) -> float:
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff

# Configuration methods
func set_target(target: Node2D):
	target_node = target

func set_launcher(ship: Node2D):
	launcher_ship = ship
	if ship and "faction" in ship:
		faction = ship.faction

func set_launch_side(side: int):
	launch_side = side

func set_flight_plan(plan_type: String, plan_data: Dictionary = {}):
	flight_plan_type = plan_type
	flight_plan_data = plan_data

func set_template_index(index: int):
	"""Assign a specific template for evolution tracking"""
	assigned_template_index = index

# Getters for compatibility
func get_velocity_mps() -> Vector2:
	return velocity_mps

func get_current_position() -> Vector2:
	return global_position

func get_predicted_position(time_ahead: float) -> Vector2:
	# Simple linear prediction
	return global_position + (velocity_mps / WorldSettings.meters_per_pixel) * time_ahead

func get_orientation() -> float:
	return orientation

# Debug input
func _unhandled_input(event):
	# Debug: Toggle performance overlay with P key
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_P:
			if batch_manager and batch_manager.has_method("toggle_performance_overlay"):
				batch_manager.toggle_performance_overlay()

# Debug drawing
func _draw():
	if not debug_enabled:
		return
	
	# Draw trail
	if debug_trail.size() < 2:
		return
	
	for i in range(1, debug_trail.size()):
		var from = to_local(debug_trail[i-1])
		var to = to_local(debug_trail[i])
		var alpha = float(i) / float(debug_trail.size())
		var color = Color(1, 0.5, 0, alpha)
		
		# Color based on using cached trajectory
		if using_cached_trajectory:
			color = Color(0, 1, 0, alpha)  # Green for cached
		
		draw_line(from, to, color, 2.0)
