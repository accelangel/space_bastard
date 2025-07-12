# Scripts/Entities/Weapons/Torpedo.gd - FIXED WITH SPEED LIMIT AND PROPER MULTI-ANGLE
extends Area2D
class_name Torpedo

# Identity baked into the node
@export var torpedo_id: String = ""
@export var birth_time: float = 0.0
@export var faction: String = "hostile"
@export var source_ship_id: String = ""

# Torpedo configuration
@export var torpedo_type: TorpedoType

# State management
var is_alive: bool = true
var marked_for_death: bool = false
var death_reason: String = ""

# Core properties
var target_node: Node2D  # Direct reference, validated each frame
var launcher_ship: Node2D

# Launch system
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

# Multi-angle specific state
var desired_approach_angle: float = 0.0  # Radians
var arc_phase: float = 0.0  # 0 = maintain offset, 1 = final approach

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var max_speed_mps: float = 200.0  # RESTORED SPEED LIMIT

# Guidance state
var previous_los: Vector2 = Vector2.ZERO
var previous_error: Vector2 = Vector2.ZERO
var integral_error: Vector2 = Vector2.ZERO
var integral_decay: float = 0.95

func _ready():
	# Load default torpedo type if none provided
	if not torpedo_type:
		torpedo_type = TorpedoType.new()
		torpedo_type.torpedo_name = "Basic Torpedo"
		torpedo_type.flight_pattern = TorpedoType.FlightPattern.BASIC
	
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
	
	velocity_mps = side_direction * torpedo_type.lateral_launch_velocity
	rotation = ship_forward.angle()
	initial_rotation = rotation
	
	# Set up approach angle for multi-angle torpedoes
	if torpedo_type.flight_pattern == TorpedoType.FlightPattern.MULTI_ANGLE:
		# Launch side determines which side we approach from
		# launch_side: 1 = starboard, -1 = port
		# We want opposite approach angles for visual distinction
		desired_approach_angle = deg_to_rad(torpedo_type.approach_angle_offset) * launch_side
		print("Torpedo %s (%s) launching with %s approach angle" % [
			torpedo_id, 
			torpedo_type.torpedo_name,
			"right" if launch_side > 0 else "left"
		])
	
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
		transition_progress = clamp(time_since_ignition / torpedo_type.transition_duration, 0.0, 1.0)
		rotation_progress = clamp(time_since_ignition / torpedo_type.rotation_transition_duration, 0.0, 1.0)
		guidance_strength = clamp(time_since_ignition / torpedo_type.guidance_ramp_duration, 0.0, 1.0)
		
		# Calculate guidance based on flight pattern
		var commanded_acceleration = Vector2.ZERO
		match torpedo_type.flight_pattern:
			TorpedoType.FlightPattern.BASIC:
				commanded_acceleration = calculate_smooth_guidance(delta)
			TorpedoType.FlightPattern.MULTI_ANGLE:
				commanded_acceleration = calculate_multi_angle_guidance(delta)
			_:
				commanded_acceleration = calculate_smooth_guidance(delta)
		
		velocity_mps += commanded_acceleration * delta
		
		# APPLY SPEED LIMIT
		if velocity_mps.length() > max_speed_mps:
			velocity_mps = velocity_mps.normalized() * max_speed_mps
		
		# Smooth rotation
		update_smooth_rotation(delta)
	else:
		# Lateral launch phase
		rotation = initial_facing_direction.angle()
	
	# Convert to pixel movement and update position
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# CHECK IF OUT OF BOUNDS
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		print("Torpedo %s went out of bounds at position %s" % [torpedo_id, global_position])
		mark_for_destruction("out_of_bounds")
		return
	
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
	var distance_criteria_met = lateral_distance_traveled >= torpedo_type.lateral_launch_distance
	var time_criteria_met = time_since_launch >= torpedo_type.engine_ignition_delay
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

func calculate_multi_angle_guidance(_delta: float) -> Vector2:
	if not engines_ignited or not target_node:
		return Vector2.ZERO
	
	var target_pos = target_node.global_position
	var to_target = target_pos - global_position
	var distance_to_target_meters = to_target.length() * WorldSettings.meters_per_pixel
	
	# FIXED: More aggressive arc approach
	# Phase transitions:
	# - Far away (>1000m): Strong arc
	# - Medium (500-1000m): Reduce arc  
	# - Close (<500m): Direct approach
	if distance_to_target_meters < 500.0:
		arc_phase = 1.0  # Full direct
	elif distance_to_target_meters < 1000.0:
		arc_phase = (1000.0 - distance_to_target_meters) / 500.0  # Gradual transition
	else:
		arc_phase = 0.0  # Full arc
	
	# FIXED: Create a proper arc trajectory
	var direct_angle = to_target.angle()
	
	# Calculate desired heading based on phase
	var desired_heading: Vector2
	
	if arc_phase < 0.5:  # Still in arc phase
		# Create perpendicular approach vector
		var perpendicular = Vector2(-to_target.y, to_target.x).normalized()
		# Choose direction based on which side we're approaching from
		if desired_approach_angle > 0:  # Right side approach
			perpendicular = -perpendicular
		
		# Blend between perpendicular and direct based on distance
		var blend = arc_phase * 2.0  # 0 to 1 during first half of arc_phase
		desired_heading = perpendicular.lerp(to_target.normalized(), blend)
	else:  # Transitioning to direct
		# Direct approach with slight offset
		var offset_angle = desired_approach_angle * (1.0 - arc_phase)
		desired_heading = Vector2.from_angle(direct_angle + offset_angle)
	
	# Calculate acceleration to achieve desired heading
	var current_heading = velocity_mps.normalized()
	var heading_error = desired_heading - current_heading
	
	# Strong lateral acceleration for arc
	var lateral_accel = heading_error * torpedo_type.max_acceleration * 0.8
	
	# Forward thrust to maintain speed
	var forward_accel = current_heading * torpedo_type.max_acceleration * 0.2
	
	var total_accel = lateral_accel + forward_accel
	
	# Limit to max acceleration
	if total_accel.length() > torpedo_type.max_acceleration:
		total_accel = total_accel.normalized() * torpedo_type.max_acceleration
	
	return total_accel * guidance_strength

func calculate_smooth_guidance(delta: float) -> Vector2:
	if not engines_ignited or not target_node:
		return Vector2.ZERO
	
	var pn_command = calculate_proportional_navigation(delta)
	var direct_command = calculate_direct_intercept(delta)
	
	var current_speed = velocity_mps.length()
	var distance_to_target = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	
	var effective_direct_weight = torpedo_type.direct_weight
	
	if current_speed < torpedo_type.speed_threshold * 0.5:
		effective_direct_weight = min(1.0, torpedo_type.direct_weight + 0.4)
	
	if distance_to_target < 200.0:
		effective_direct_weight = min(1.0, torpedo_type.direct_weight + 0.3)
	
	var pn_weight = 1.0 - effective_direct_weight
	var guidance_command = pn_command * pn_weight + direct_command * effective_direct_weight
	
	var gentle_steering = Vector2.ZERO
	if transition_progress < 1.0:
		var to_target = (target_node.global_position - global_position).normalized()
		var current_velocity_normalized = velocity_mps.normalized()
		var perpendicular = Vector2(-current_velocity_normalized.y, current_velocity_normalized.x)
		var steering_amount = to_target.dot(perpendicular)
		gentle_steering = perpendicular * steering_amount * torpedo_type.max_acceleration * 0.3
	
	var transition_factor = smoothstep(0.0, 1.0, transition_progress)
	var final_command = lerp(gentle_steering, guidance_command, transition_factor)
	final_command *= guidance_strength
	
	if final_command.length() > torpedo_type.max_acceleration:
		final_command = final_command.normalized() * torpedo_type.max_acceleration
	
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
	
	var lateral_command = torpedo_type.navigation_constant * closing_velocity
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
	
	var proportional = error * torpedo_type.kp
	integral_error = integral_error * integral_decay + error * delta
	var integral = integral_error * torpedo_type.ki
	var derivative = (error - previous_error) / delta * torpedo_type.kd
	previous_error = error
	
	var pid_command = proportional + integral + derivative
	
	if pid_command.length() > torpedo_type.max_acceleration:
		pid_command = pid_command.normalized() * torpedo_type.max_acceleration
	
	return pid_command

func calculate_intercept_point(shooter_pos: Vector2, shooter_vel: Vector2, target_pos: Vector2, target_vel: Vector2) -> Vector2:
	var relative_pos = target_pos - shooter_pos
	var relative_vel = target_vel - shooter_vel
	
	if relative_vel.length() < 1.0:
		return target_pos
	
	# Use actual max speed, not unlimited acceleration-based speed
	var torpedo_speed = min(max_speed_mps, velocity_mps.length() + 50.0)  # Current speed + some acceleration headroom
	
	var a = relative_vel.dot(relative_vel) - torpedo_speed * torpedo_speed
	var b = 2.0 * relative_pos.dot(relative_vel)
	var c = relative_pos.dot(relative_pos)
	
	var discriminant = b * b - 4.0 * a * c
	
	if discriminant < 0.0 or abs(a) < 0.01:
		return target_pos
	
	var t1 = (-b + sqrt(discriminant)) / (2.0 * a)
	var t2 = (-b - sqrt(discriminant)) / (2.0 * a)
	
	var intercept_time: float = 0.0
	if t1 > 0 and t2 > 0:
		intercept_time = min(t1, t2)
	elif t1 > 0:
		intercept_time = t1
	elif t2 > 0:
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
	
	# COLLIDE WITH PDC BULLETS
	if area.is_in_group("bullets"):
		# Don't collide with same faction
		if area.get("faction") == faction:
			return
		
		# Store hit information on the bullet (it will handle the collision)
		area.set_meta("hit_target", torpedo_id)
		
		# Self destruct
		mark_for_destruction("bullet_impact")
		return
	
	# COLLIDE WITH SHIPS (torpedo dies, ship survives)
	if area.is_in_group("ships"):
		# Don't collide with same faction (friendly fire protection)
		if area.get("faction") == faction:
			return
		
		print("Torpedo %s hit ship %s" % [torpedo_id, area.get("entity_id")])
		# Torpedo is destroyed, ship survives (testing phase)
		mark_for_destruction("ship_impact")

# Methods called by launcher
func set_target(target: Node2D):
	target_node = target

func set_launcher(ship: Node2D):
	launcher_ship = ship
	if ship and "faction" in ship:
		faction = ship.faction

func set_launch_side(side: int):
	launch_side = side

func set_torpedo_type(type: TorpedoType):
	torpedo_type = type

func get_velocity_mps() -> Vector2:
	return velocity_mps

# For PDC targeting
func get_current_position() -> Vector2:
	return global_position

func get_predicted_position(time_ahead: float) -> Vector2:
	return global_position + (velocity_mps / WorldSettings.meters_per_pixel) * time_ahead
