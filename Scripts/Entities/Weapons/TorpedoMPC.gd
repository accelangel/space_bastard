# Scripts/Entities/Weapons/TorpedoMPC.gd - MPC-Controlled Torpedo
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
var max_speed_mps: float = 2000.0  # Will be removed later
var max_acceleration: float = 490.5  # 50G
var max_rotation_rate: float = deg_to_rad(1080.0)

# MPC Controller
var mpc_controller: MPCController

# Batch update system
var batch_manager: Node = null
var use_batch_updates: bool = true
var frames_since_update: int = 0
var max_frames_between_updates: int = 3  # Update every 3 frames max

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
	
	# Create MPC controller
	mpc_controller = MPCController.new()
	mpc_controller.max_acceleration = max_acceleration
	mpc_controller.max_rotation_rate = max_rotation_rate
	mpc_controller.max_speed = max_speed_mps
	
	# Report GPU status
	if mpc_controller.gpu_available:
		print("TorpedoMPC %s: GPU acceleration AVAILABLE (%s mode)" % [
			torpedo_id,
			"ENABLED" if mpc_controller.use_gpu else "DISABLED"
		])
	else:
		print("TorpedoMPC %s: GPU acceleration NOT AVAILABLE - using CPU" % torpedo_id)
	
	# Check for batch manager
	if use_batch_updates:
		batch_manager = get_node_or_null("/root/BatchMPCManager")
		if batch_manager and batch_manager.has_method("register_torpedo"):
			batch_manager.register_torpedo(self)
			print("TorpedoMPC %s: Registered with batch manager" % torpedo_id)
		else:
			print("TorpedoMPC %s: No batch manager found, using individual updates" % torpedo_id)
			use_batch_updates = false
	
	# Groups
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	# Enable input for GPU toggle
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
	"""Main MPC control update - now uses batch system when available"""
	
	if use_batch_updates and batch_manager:
		# Request batch update instead of doing it ourselves
		frames_since_update += 1
		
		# Calculate priority based on situation
		var priority = 1.0
		
		# Higher priority if close to target
		if target_node:
			var distance = global_position.distance_to(target_node.global_position)
			if distance < 2000:  # Very close
				priority = 10.0
			elif distance < 5000:  # Close
				priority = 5.0
		
		# Higher priority if we haven't updated recently
		if frames_since_update >= max_frames_between_updates:
			priority *= 2.0
		
		# Request update from batch system
		if batch_manager.has_method("request_update"):
			batch_manager.request_update(self, priority)
		
		# Don't do our own update - wait for batch result
		return
	
	# Fall back to individual update if no batch system
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
	
	# Apply control
	apply_control(control, delta)
	
	# Track control smoothness
	control_history.append(control)
	if control_history.size() > 10:
		control_history.pop_front()
	
	update_trajectory_smoothness()

func apply_mpc_control(control: Dictionary):
	"""Apply control calculated by batch MPC system"""
	
	if not control.has("thrust") or not control.has("rotation_rate"):
		push_error("Invalid control dictionary from batch MPC")
		return
	
	# Reset update counter
	frames_since_update = 0
	
	# Apply the control
	apply_control(control, get_physics_process_delta_time())
	
	# Update trajectory smoothness tracking
	control_history.append(control)
	if control_history.size() > 10:
		control_history.pop_front()
	
	update_trajectory_smoothness()

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
		"trajectory_smoothness": trajectory_smoothness
	}
	
	# Report to any listening systems
	get_tree().call_group("mpc_observers", "on_torpedo_miss", miss_data)

func report_hit():
	"""Report successful hit"""
	var hit_data = {
		"torpedo_id": torpedo_id,
		"flight_plan_type": flight_plan_type,
		"time_to_impact": (Time.get_ticks_msec() / 1000.0) - launch_start_time,
		"trajectory_smoothness": trajectory_smoothness
	}
	
	# Report to any listening systems
	get_tree().call_group("mpc_observers", "on_torpedo_hit", hit_data)

func update_debug_trail():
	debug_trail.append(global_position)
	if debug_trail.size() > max_trail_points:
		debug_trail.remove_at(0)

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

# Getters for compatibility
func get_velocity_mps() -> Vector2:
	return velocity_mps

func get_current_position() -> Vector2:
	return global_position

func get_predicted_position(time_ahead: float) -> Vector2:
	# Get prediction from MPC trajectory
	if mpc_controller and mpc_controller.current_trajectory.states.size() > 0:
		var state = mpc_controller.current_trajectory.get_state_at_time(time_ahead)
		if state.has("position"):
			# Convert from meters to pixels
			return state.position / WorldSettings.meters_per_pixel
	
	# Fallback to linear prediction
	return global_position + (velocity_mps / WorldSettings.meters_per_pixel) * time_ahead

func get_orientation() -> float:
	return orientation

# Debug input
func _unhandled_input(event):
	# Debug: Toggle GPU with G key
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_G:
			if mpc_controller and mpc_controller.gpu_available:
				mpc_controller.use_gpu = !mpc_controller.use_gpu
				print("TorpedoMPC %s: GPU %s" % [
					torpedo_id,
					"ENABLED" if mpc_controller.use_gpu else "DISABLED"
				])

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
		draw_line(from, to, Color(1, 0.5, 0, alpha), 2.0)
	
	# Draw MPC predicted trajectory
	if mpc_controller:
		var mpc_points = mpc_controller.get_debug_points()
		if mpc_points.size() > 1:
			for i in range(1, min(mpc_points.size(), 20)):  # Only show next 20 points
				var from = to_local(mpc_points[i-1] / WorldSettings.meters_per_pixel)
				var to = to_local(mpc_points[i] / WorldSettings.meters_per_pixel)
				draw_line(from, to, Color(0, 1, 0, 0.5), 1.0)
