# Scripts/Entities/Weapons/Torpedo.gd - IMMEDIATE STATE REFACTOR
extends Area2D
class_name Torpedo

# Identity baked into the node
@export var torpedo_id: String = ""
@export var birth_time: float = 0.0
@export var faction: String = "hostile"
@export var source_ship_id: String = ""

# State management
var is_alive: bool = true
var marked_for_death: bool = false
var death_reason: String = ""

# Core properties
var target_node: Node2D  # Direct reference, validated each frame
var launcher_ship: Node2D

# Torpedo specifications
@export var max_acceleration: float = 1430.0    # 150 Gs in m/s²

# Launch system
@export var lateral_launch_velocity: float = 60.0   # Lateral impulse (m/s)
@export var lateral_launch_distance: float = 80.0   # Distance to travel laterally (meters)
@export var engine_ignition_delay: float = 1.6     # Seconds before engines ignite

# Smooth transition system
@export var transition_duration: float = 1.6
@export var rotation_transition_duration: float = 3.2
@export var guidance_ramp_duration: float = 0.8

# Launch state tracking
var launch_side: int = 1
var engines_ignited: bool = false
var launch_start_time: float = 0.0
var lateral_distance_traveled: float = 0.0
var initial_facing_direction: Vector2

# Smooth transition state
var engine_ignition_time: float = 0.0
var transition_progress: float = 0.0
var rotation_progress: float = 0.0
var guidance_strength: float = 0.0

# Target rotation tracking
var target_rotation: float = 0.0
var initial_rotation: float = 0.0

# Intercept guidance parameters
@export var navigation_constant: float = 3.0
@export var direct_weight: float = 0.05
@export var speed_threshold: float = 200.0

# Direct intercept PID parameters
@export var kp: float = 800.0
@export var ki: float = 50.0
@export var kd: float = 150.0

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO

# Guidance state
var previous_los: Vector2 = Vector2.ZERO
var previous_los_rate: float = 0.0
var previous_error: Vector2 = Vector2.ZERO
var integral_error: Vector2 = Vector2.ZERO
var integral_decay: float = 0.95

func _ready():
	# Generate unique ID if not provided
	if torpedo_id == "":
		torpedo_id = "torpedo_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	birth_time = Time.get_ticks_msec() / 1000.0
	launch_start_time = birth_time
	
	# Add to groups for identification
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	# Store all identity data as metadata for redundancy
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	set_meta("source_ship_id", source_ship_id)
	
	# Validate target
	if not is_valid_target(target_node):
		print("Torpedo %s: No valid target, self-destructing" % torpedo_id)
		mark_for_destruction("no_target")
		return
	
	# Launch setup
	var ship_forward = Vector2.UP
	if launcher_ship:
		ship_forward = Vector2.UP.rotated(launcher_ship.rotation)
		if "entity_id" in launcher_ship:
			source_ship_id = launcher_ship.entity_id
	
	initial_facing_direction = ship_forward
	var side_direction = Vector2(-ship_forward.y, ship_forward.x) * launch_side
	
	velocity_mps = side_direction * lateral_launch_velocity
	rotation = ship_forward.angle()
	initial_rotation = rotation
	
	# Connect collision
	area_entered.connect(_on_area_entered)
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_spawned", self, "torpedo")

func _physics_process(delta):
	# Validate we're still alive
	if marked_for_death or not is_alive:
		return
	
	# Validate target every frame
	if not is_valid_target(target_node):
		target_node = null
	
	var current_time = Time.get_ticks_msec() / 1000.0
	var time_since_launch = current_time - launch_start_time
	
	# Track lateral distance during launch phase
	if not engines_ignited:
		var distance_this_frame = velocity_mps.length() * delta
		lateral_distance_traveled += distance_this_frame
	
	# Check if engines should ignite
	if not engines_ignited and should_ignite_engines(time_since_launch):
		ignite_engines()
		engine_ignition_time = current_time
	
	# Apply appropriate movement logic based on engine state
	if engines_ignited and target_node:
		# Update transition progress
		var time_since_ignition = current_time - engine_ignition_time
		transition_progress = clamp(time_since_ignition / transition_duration, 0.0, 1.0)
		rotation_progress = clamp(time_since_ignition / rotation_transition_duration, 0.0, 1.0)
		guidance_strength = clamp(time_since_ignition / guidance_ramp_duration, 0.0, 1.0)
		
		# Calculate guidance
		var commanded_acceleration = calculate_smooth_guidance(delta)
		velocity_mps += commanded_acceleration * delta
		
		# Smooth rotation
		update_smooth_rotation(delta)
	else:
		# Lateral launch phase
		rotation = initial_facing_direction.angle()
	
	# Convert to pixel movement and update position
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Notify observers of position update
	get_tree().call_group("battle_observers", "on_entity_moved", self, global_position)

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
		return  # Already dying
	
	marked_for_death = true
	is_alive = false
	death_reason = reason
	
	# Disable immediately
	set_physics_process(false)
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = true
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	# Safe cleanup
	queue_free()

func should_ignite_engines(time_since_launch: float) -> bool:
	var distance_criteria_met = lateral_distance_traveled >= lateral_launch_distance
	var time_criteria_met = time_since_launch >= engine_ignition_delay
	return distance_criteria_met or time_criteria_met

func ignite_engines():
	engines_ignited = true
	if target_node:
		var to_target = (target_node.global_position - global_position).normalized()
		previous_los = to_target

func update_smooth_rotation(delta: float):
	if velocity_mps.length() < 10.0:
		return
	
	target_rotation = velocity_mps.angle()
	var current_target = lerp_angle(initial_rotation, target_rotation, rotation_progress)
	var rotation_speed = 3.0 * (1.0 + rotation_progress)
	rotation = rotate_toward(rotation, current_target, rotation_speed * delta)

func calculate_smooth_guidance(delta: float) -> Vector2:
	if not engines_ignited or not target_node:
		return Vector2.ZERO
	
	var pn_command = calculate_proportional_navigation(delta)
	var direct_command = calculate_direct_intercept(delta)
	
	var current_speed = velocity_mps.length()
	var distance_to_target = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	
	var effective_direct_weight = direct_weight
	
	if current_speed < speed_threshold * 0.5:
		effective_direct_weight = min(1.0, direct_weight + 0.4)
	
	if distance_to_target < 200.0:
		effective_direct_weight = min(1.0, direct_weight + 0.3)
	
	var pn_weight = 1.0 - effective_direct_weight
	var guidance_command = pn_command * pn_weight + direct_command * effective_direct_weight
	
	var gentle_steering = Vector2.ZERO
	if transition_progress < 1.0:
		var to_target = (target_node.global_position - global_position).normalized()
		var current_velocity_normalized = velocity_mps.normalized()
		var perpendicular = Vector2(-current_velocity_normalized.y, current_velocity_normalized.x)
		var steering_amount = to_target.dot(perpendicular)
		gentle_steering = perpendicular * steering_amount * max_acceleration * 0.3
	
	var transition_factor = smoothstep(0.0, 1.0, transition_progress)
	var final_command = lerp(gentle_steering, guidance_command, transition_factor)
	final_command *= guidance_strength
	
	if final_command.length() > max_acceleration:
		final_command = final_command.normalized() * max_acceleration
	
	return final_command

func calculate_proportional_navigation(delta: float) -> Vector2:
	if not target_node:
		return Vector2.ZERO
	
	var target_pos = target_node.global_position
	var target_vel = _get_target_velocity()
	
	var los_vector = target_pos - global_position
	var range_to_target = los_vector.length()
	
	if range_to_target < 1.0:
		return Vector2.ZERO
	
	var los_unit = los_vector / range_to_target
	
	var los_rate_vector = Vector2.ZERO
	if previous_los.length() > 0.1 and delta > 0:
		var los_change = los_unit - previous_los
		los_rate_vector = los_change / delta
	
	previous_los = los_unit
	
	var relative_velocity = target_vel - velocity_mps
	var closing_velocity = -relative_velocity.dot(los_unit)
	
	if closing_velocity <= 0:
		return Vector2.ZERO
	
	var lateral_command = navigation_constant * closing_velocity
	var acceleration_command = los_rate_vector * lateral_command
	
	return acceleration_command

func calculate_direct_intercept(delta: float) -> Vector2:
	if not target_node:
		return Vector2.ZERO
	
	var target_pos = target_node.global_position
	var target_vel = _get_target_velocity()
	
	var intercept_point = calculate_intercept_point(global_position, velocity_mps, target_pos, target_vel)
	
	var error = intercept_point - global_position
	var error_magnitude = error.length()
	
	if error_magnitude < 1.0:
		return Vector2.ZERO
	
	var proportional = error * kp
	integral_error = integral_error * integral_decay + error * delta
	var integral = integral_error * ki
	var derivative = (error - previous_error) / delta * kd
	previous_error = error
	
	var pid_command = proportional + integral + derivative
	
	if pid_command.length() > max_acceleration:
		pid_command = pid_command.normalized() * max_acceleration
	
	return pid_command

func calculate_intercept_point(shooter_pos: Vector2, shooter_vel: Vector2, target_pos: Vector2, target_vel: Vector2) -> Vector2:
	var relative_pos = target_pos - shooter_pos
	var relative_vel = target_vel - shooter_vel
	
	if relative_vel.length() < 1.0:
		return target_pos
	
	var torpedo_max_speed = sqrt(2.0 * max_acceleration * relative_pos.length())
	
	if torpedo_max_speed < 1.0:
		return target_pos
	
	var a = relative_vel.dot(relative_vel) - torpedo_max_speed * torpedo_max_speed
	var b = 2.0 * relative_pos.dot(relative_vel)
	var c = relative_pos.dot(relative_pos)
	
	var discriminant = b * b - 4.0 * a * c
	
	if discriminant < 0.0 or abs(a) < 0.01:
		return target_pos
	
	var t1 = (-b + sqrt(discriminant)) / (2.0 * a)
	var t2 = (-b - sqrt(discriminant)) / (2.0 * a)
	
	var intercept_time: float = 0.0
	if t1 > 0:
		intercept_time = t1
	else:
		intercept_time = t2
	
	if intercept_time <= 0:
		return target_pos
	
	return target_pos + target_vel * intercept_time

func _get_target_velocity() -> Vector2:
	if not target_node:
		return Vector2.ZERO
	
	if target_node.has_method("get_velocity_mps"):
		return target_node.get_velocity_mps()
	elif "velocity_mps" in target_node:
		return target_node.velocity_mps
	
	return Vector2.ZERO

func _on_area_entered(area: Area2D):
	if marked_for_death:
		return
	
	# Check if it's a valid collision target
	if area.is_in_group("combat_entities"):
		# Don't collide with same faction
		if area.get("faction") == faction:
			return
		
		# Store hit information on the target
		if area.has_method("mark_for_destruction"):
			area.set_meta("last_hit_by", torpedo_id)
			area.mark_for_destruction("torpedo_impact")
		
		# Self destruct
		mark_for_destruction("target_impact")

# Methods called by launcher
func set_target(target: Node2D):
	target_node = target

func set_launcher(ship: Node2D):
	launcher_ship = ship
	if ship and "faction" in ship:
		faction = ship.faction

func set_launch_side(side: int):
	launch_side = side

func get_velocity_mps() -> Vector2:
	return velocity_mps

# For PDC targeting
func get_current_position() -> Vector2:
	return global_position

func get_predicted_position(time_ahead: float) -> Vector2:
	return global_position + (velocity_mps / WorldSettings.meters_per_pixel) * time_ahead
