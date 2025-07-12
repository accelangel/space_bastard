# Scripts/Entities/Weapons/Torpedo.gd - PROPER SINGLE-THRUST PHYSICS
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

# PROPER PHYSICS STATE
var velocity_mps: Vector2 = Vector2.ZERO
var orientation: float = 0.0  # The direction the torpedo is pointing
var max_speed_mps: float = 2000.0  # Default 2 km/s
var max_rotation_rate: float = deg_to_rad(180.0)  # degrees per second

# Multi-angle specific state
var desired_approach_angle: float = 0.0  # Radians
var arc_phase: float = 0.0  # 0 = maintain offset, 1 = final approach

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
	
	# Initial lateral velocity for launch
	velocity_mps = side_direction * torpedo_type.lateral_launch_velocity
	
	# Set initial orientation to ship forward
	orientation = ship_forward.angle()
	rotation = orientation
	
	# Set up approach angle for multi-angle torpedoes
	if torpedo_type.flight_pattern == TorpedoType.FlightPattern.MULTI_ANGLE:
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
		
		# Calculate desired orientation based on flight pattern
		var desired_orientation = 0.0
		match torpedo_type.flight_pattern:
			TorpedoType.FlightPattern.BASIC:
				desired_orientation = calculate_basic_guidance_orientation(delta)
			TorpedoType.FlightPattern.MULTI_ANGLE:
				desired_orientation = calculate_multi_angle_guidance_orientation(delta)
			_:
				desired_orientation = calculate_basic_guidance_orientation(delta)
		
		# Apply rotation limits
		var rotation_diff = angle_difference(orientation, desired_orientation)
		var max_rotation = max_rotation_rate * delta * guidance_strength
		
		if abs(rotation_diff) > max_rotation:
			orientation += sign(rotation_diff) * max_rotation
		else:
			orientation = desired_orientation
		
		# Normalize orientation
		while orientation > PI:
			orientation -= TAU
		while orientation < -PI:
			orientation += TAU
		
		# APPLY THRUST IN THE DIRECTION WE'RE POINTING
		var thrust_direction = Vector2.from_angle(orientation)
		var thrust_force = thrust_direction * torpedo_type.max_acceleration * guidance_strength
		
		# Update velocity
		velocity_mps += thrust_force * delta
		
		# Apply speed limit
		if velocity_mps.length() > max_speed_mps:
			velocity_mps = velocity_mps.normalized() * max_speed_mps
		
		# Debug info every second
		if Engine.get_physics_frames() % 60 == 0:
			var distance_to_target = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
			var orientation_error = rad_to_deg(abs(angle_difference(orientation, velocity_mps.angle())))
			print("Torpedo %s: Speed %.1f m/s, Distance %.1f m, Orientation error: %.1f°" % [
				torpedo_id, 
				velocity_mps.length(),
				distance_to_target,
				orientation_error
			])
		
		# Update visual rotation to match orientation
		rotation = orientation
	else:
		# Lateral launch phase - no thrust
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

func calculate_basic_guidance_orientation(_delta: float) -> float:
	if not target_node:
		return orientation
	
	# Calculate intercept point
	var target_pos = target_node.global_position
	var target_vel = _get_target_velocity()
	var intercept_point = calculate_intercept_point(global_position, velocity_mps, target_pos, target_vel)
	
	# Point directly at intercept
	var to_intercept = intercept_point - global_position
	return to_intercept.angle()

func calculate_multi_angle_guidance_orientation(_delta: float) -> float:
	if not target_node:
		return orientation
	
	var target_pos = target_node.global_position
	var target_vel = _get_target_velocity()
	var to_target = target_pos - global_position
	var distance_to_target_meters = to_target.length() * WorldSettings.meters_per_pixel
	
	# Calculate intercept point
	var intercept_point = calculate_intercept_point(global_position, velocity_mps, target_pos, target_vel)
	var to_intercept = intercept_point - global_position
	
	# Phase transitions based on distance
	if distance_to_target_meters < 500.0:
		arc_phase = 1.0  # Full direct
	elif distance_to_target_meters < 1500.0:
		arc_phase = (distance_to_target_meters - 500.0) / 1000.0
	else:
		arc_phase = 0.0  # Full arc
	
	# Base angle to intercept
	var intercept_angle = to_intercept.angle()
	
	# Apply arc offset
	var effective_arc_strength = torpedo_type.arc_strength * (1.0 - arc_phase)
	var angle_offset = desired_approach_angle * effective_arc_strength
	
	# CRITICAL: At high speeds, we need to lead the target MORE
	# Calculate how far off our current velocity is from ideal
	var velocity_angle = velocity_mps.angle()
	var ideal_angle = intercept_angle + angle_offset
	var velocity_error = angle_difference(velocity_angle, ideal_angle)
	
	# Point ahead of where we want to go to compensate for momentum
	# The faster we're going, the more we need to lead
	var speed_factor = velocity_mps.length() / 1000.0  # Normalize to 1km/s
	var lead_angle = velocity_error * (0.5 + speed_factor * 0.5)  # Lead by 50-100% of error
	
	return ideal_angle + lead_angle

func angle_difference(from: float, to: float) -> float:
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff

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
		print("Torpedo %s: Engines ignited! Max acceleration: %.1f m/s²" % [torpedo_id, torpedo_type.max_acceleration])

func calculate_intercept_point(shooter_pos: Vector2, shooter_vel: Vector2, target_pos: Vector2, target_vel: Vector2) -> Vector2:
	var relative_pos = target_pos - shooter_pos
	var relative_vel = target_vel - shooter_vel
	
	# If target not moving relative to us, aim directly at it
	if relative_vel.length() < 1.0:
		return target_pos
	
	# Use current speed or 80% of max, whichever is higher
	var torpedo_speed = max(velocity_mps.length(), max_speed_mps * 0.8)
	
	# Quadratic equation for intercept
	var a = relative_vel.dot(relative_vel) - torpedo_speed * torpedo_speed
	var b = 2.0 * relative_pos.dot(relative_vel)
	var c = relative_pos.dot(relative_pos)
	
	var discriminant = b * b - 4.0 * a * c
	
	if discriminant < 0.0 or abs(a) < 0.01:
		# No intercept solution, aim ahead of target
		var time_estimate = relative_pos.length() / torpedo_speed
		return target_pos + target_vel * time_estimate
	
	var t1 = (-b + sqrt(discriminant)) / (2.0 * a)
	var t2 = (-b - sqrt(discriminant)) / (2.0 * a)
	
	var intercept_time: float = 0.0
	if t1 > 0 and t2 > 0:
		intercept_time = min(t1, t2)
	elif t1 > 0:
		intercept_time = t1
	elif t2 > 0:
		intercept_time = t2
	else:
		# Both solutions negative, aim ahead
		var time_estimate = relative_pos.length() / torpedo_speed
		return target_pos + target_vel * time_estimate
	
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
