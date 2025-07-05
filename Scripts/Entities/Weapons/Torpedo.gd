# Scripts/Entities/Weapons/Torpedo.gd - REFACTORED (Preserving all guidance logic)
extends Area2D
class_name Torpedo

# Core properties
var entity_id: String
var faction: String = "friendly"
var target_node: Node2D

# Torpedo specifications (KEEP ALL OF THESE)
@export var max_acceleration: float = 1430.0    # 150 Gs in m/s²
@export var proximity_meters: float = 10.0       # Auto-detonate range

# ENHANCED LAUNCH SYSTEM (MUST KEEP)
@export var lateral_launch_velocity: float = 60.0   # Lateral impulse (m/s)
@export var lateral_launch_distance: float = 80.0   # Distance to travel laterally (meters)
@export var engine_ignition_delay: float = 1.6     # Seconds before engines ignite

# SMOOTH TRANSITION SYSTEM (MUST KEEP)
@export var transition_duration: float = 1.6        # Time to smoothly transition guidance
@export var rotation_transition_duration: float = 3.2 # Time to smoothly rotate to velocity direction
@export var guidance_ramp_duration: float = 0.8      # Time to ramp up guidance strength

# Launch state tracking (KEEP ALL)
var launch_side: int = 1  # 1 for right, -1 for left
var engines_ignited: bool = false
var launch_start_time: float = 0.0
var lateral_distance_traveled: float = 0.0
var initial_facing_direction: Vector2

# Smooth transition state (KEEP ALL)
var engine_ignition_time: float = 0.0
var transition_progress: float = 0.0
var rotation_progress: float = 0.0
var guidance_strength: float = 0.0

# Target rotation tracking
var target_rotation: float = 0.0
var initial_rotation: float = 0.0

# Intercept guidance parameters (KEEP ALL)
@export var navigation_constant: float = 3.0     # Proportional navigation gain
@export var direct_weight: float = 0.05          # Direct intercept influence
@export var speed_threshold: float = 200.0       # m/s - speed threshold for guidance

# Direct intercept PID parameters (KEEP ALL)
@export var kp: float = 800.0        # Proportional gain
@export var ki: float = 50.0         # Integral gain
@export var kd: float = 150.0        # Derivative gain

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var launcher_ship: Node2D

# Guidance state (KEEP ALL)
var previous_los: Vector2 = Vector2.ZERO
var previous_los_rate: float = 0.0
var previous_error: Vector2 = Vector2.ZERO
var integral_error: Vector2 = Vector2.ZERO
var integral_decay: float = 0.95

func _ready():
	launch_start_time = Time.get_ticks_msec() / 1000.0
	
	# Add to torpedoes group for identification
	add_to_group("torpedoes")
	
	if not target_node:
		print("Torpedo: No target provided, self-destructing")
		queue_free()
		return
	
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		if launcher_ship and "faction" in launcher_ship:
			faction = launcher_ship.faction
		entity_id = entity_manager.register_entity(self, "torpedo", faction)
	
	# LATERAL LAUNCH SETUP (KEEP ALL OF THIS)
	var ship_forward = Vector2.UP
	if launcher_ship:
		ship_forward = Vector2.UP.rotated(launcher_ship.rotation)
	
	initial_facing_direction = ship_forward
	var side_direction = Vector2(-ship_forward.y, ship_forward.x) * launch_side
	
	# Launch velocity is LATERAL (sideways) to the ship
	velocity_mps = side_direction * lateral_launch_velocity
	
	# Torpedo FACES the same direction as the ship
	rotation = ship_forward.angle()
	initial_rotation = rotation
	
	# Connect collision
	area_entered.connect(_on_area_entered)

func _physics_process(delta):
	# Validate target
	if not is_instance_valid(target_node):
		queue_free()
		return
	
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
	
	var target_pos = target_node.global_position
	var distance_to_target_pixels = global_position.distance_to(target_pos)
	var distance_to_target_meters = distance_to_target_pixels * WorldSettings.meters_per_pixel
	
	# Check proximity for detonation
	if distance_to_target_meters < proximity_meters:
		_impact()
		return
	
	# Apply appropriate movement logic based on engine state
	if engines_ignited:
		# Update transition progress
		var time_since_ignition = current_time - engine_ignition_time
		transition_progress = clamp(time_since_ignition / transition_duration, 0.0, 1.0)
		rotation_progress = clamp(time_since_ignition / rotation_transition_duration, 0.0, 1.0)
		guidance_strength = clamp(time_since_ignition / guidance_ramp_duration, 0.0, 1.0)
		
		# SMOOTH GUIDANCE: Gradually apply intercept calculations
		var commanded_acceleration = calculate_smooth_guidance(delta)
		velocity_mps += commanded_acceleration * delta
		
		# SMOOTH ROTATION: Gradually rotate from initial direction to velocity direction
		update_smooth_rotation(delta)
	else:
		# LATERAL LAUNCH PHASE: Continue lateral movement
		rotation = initial_facing_direction.angle()
	
	# Convert to pixel movement and update position
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Update EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.update_entity_position(entity_id, global_position)

func should_ignite_engines(time_since_launch: float) -> bool:
	var distance_criteria_met = lateral_distance_traveled >= lateral_launch_distance
	var time_criteria_met = time_since_launch >= engine_ignition_delay
	return distance_criteria_met or time_criteria_met

func ignite_engines():
	engines_ignited = true
	var to_target = (target_node.global_position - global_position).normalized()
	previous_los = to_target

func update_smooth_rotation(delta: float):
	if velocity_mps.length() < 10.0:
		return
	
	target_rotation = velocity_mps.angle()
	var current_target = lerp_angle(initial_rotation, target_rotation, rotation_progress)
	var rotation_speed = 3.0 * (1.0 + rotation_progress)
	rotation = rotate_toward(rotation, current_target, rotation_speed * delta)

# ALL GUIDANCE FUNCTIONS PRESERVED EXACTLY AS THEY WERE
func calculate_smooth_guidance(delta: float) -> Vector2:
	if not engines_ignited:
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
	# Check if we hit something we should destroy
	if "faction" in area and area.faction != faction:
		_impact()

func _impact():
	# Clean up and destroy
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.unregister_entity(entity_id)
	queue_free()

# Methods called by launcher
func set_target(target: Node2D):
	target_node = target

func set_launcher(ship: Node2D):
	launcher_ship = ship

func set_launch_side(side: int):
	launch_side = side

func get_velocity_mps() -> Vector2:
	return velocity_mps
