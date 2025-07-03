# Enhanced Torpedo.gd with smooth transition from lateral launch to guidance
extends Area2D
class_name Torpedo

var entity_id: String  # NEW: EntityManager ID

# Torpedo specifications
@export var max_acceleration: float = 1430.0    # 150 Gs in m/s²
@export var proximity_meters: float = 10.0       # Auto-detonate range

# ENHANCED LAUNCH SYSTEM
@export var lateral_launch_velocity: float = 80.0   # Much stronger lateral impulse (m/s)
@export var lateral_launch_distance: float = 40.0   # Distance to travel laterally (meters)
@export var engine_ignition_delay: float = 0.8       # Seconds before engines ignite

# SMOOTH TRANSITION SYSTEM
@export var transition_duration: float = 0.8        # Time to smoothly transition guidance
@export var rotation_transition_duration: float = 1.6 # Time to smoothly rotate to velocity direction
@export var guidance_ramp_duration: float = 0.8      # Time to ramp up guidance strength

# Launch state tracking
var launch_side: int = 1  # 1 for right, -1 for left (set by launcher)
var engines_ignited: bool = false
var launch_start_time: float = 0.0
var lateral_distance_traveled: float = 0.0
var initial_facing_direction: Vector2  # Store the ship's facing direction at launch

# Smooth transition state
var engine_ignition_time: float = 0.0
var transition_progress: float = 0.0      # 0.0 to 1.0 for guidance transition
var rotation_progress: float = 0.0       # 0.0 to 1.0 for rotation transition
var guidance_strength: float = 0.0       # 0.0 to 1.0 for guidance ramp-up

# Target rotation tracking
var target_rotation: float = 0.0
var initial_rotation: float = 0.0

# Intercept guidance parameters (only active after engine ignition)
@export var navigation_constant: float = 3.0     # Proportional navigation gain
@export var direct_weight: float = 0.05          # Direct intercept influence (0.0 to 1.0)
@export var speed_threshold: float = 200.0       # m/s - speed threshold for guidance transitions

# Direct intercept PID parameters
@export var kp: float = 800.0        # Proportional gain
@export var ki: float = 50.0         # Integral gain
@export var kd: float = 150.0        # Derivative gain

# TARGET DATA SYSTEM
var target_data: TargetData
var target_id: String

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var launcher_ship: Node2D
var meters_per_pixel: float

# Guidance state (only used after engine ignition)
var previous_los: Vector2 = Vector2.ZERO
var previous_los_rate: float = 0.0
var previous_error: Vector2 = Vector2.ZERO
var integral_error: Vector2 = Vector2.ZERO
var integral_decay: float = 0.95

func _ready():
	launch_start_time = Time.get_ticks_msec() / 1000.0
	
	if not target_data and target_id.is_empty():
		queue_free()
		return
	
	# Get target data if we only have ID
	if target_id and not target_data:
		var target_manager = get_node_or_null("/root/TargetManager")
		if target_manager and target_manager.has_method("get_target_data"):
			target_data = target_manager.get_target_data(target_id)
		if not target_data:
			queue_free()
			return
	
	if meters_per_pixel <= 0:
		meters_per_pixel = WorldSettings.meters_per_pixel
	
	# LATERAL LAUNCH: Launch sideways relative to ship direction
	var ship_forward = Vector2.UP  # Default ship forward direction
	if launcher_ship:
		# Get the ship's forward direction (assuming ships face "up" in local coordinates)
		ship_forward = Vector2.UP.rotated(launcher_ship.rotation)
	
	# Store the ship's facing direction for the torpedo's orientation
	initial_facing_direction = ship_forward
	
	# Calculate side direction perpendicular to ship's forward direction
	var side_direction = Vector2(-ship_forward.y, ship_forward.x) * launch_side
	
	# Launch velocity is LATERAL (sideways) to the ship
	velocity_mps = side_direction * lateral_launch_velocity
	
	# Torpedo FACES the same direction as the ship (not the movement direction)
	rotation = ship_forward.angle()
	initial_rotation = rotation  # Store initial rotation for smooth transition
	
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		var owner_entity_id = ""
		if launcher_ship:
			var launcher_entity = entity_manager.get_entity_for_node(launcher_ship)
			if launcher_entity:
				owner_entity_id = launcher_entity.entity_id
		
		entity_id = entity_manager.register_entity(
			self, 
			4,  # EntityManager.EntityType.TORPEDO
			1 if owner_entity_id.begins_with("Player") else 2,  # Player or Enemy faction
			owner_entity_id
		)
		
		# Set targeting relationship if we have a target
		if target_data and target_data.target_node:
			var target_entity = entity_manager.get_entity_for_node(target_data.target_node)
			if target_entity:
				entity_manager.set_targeting_relationship(entity_id, target_entity.entity_id)

func _physics_process(delta):
	# Validate target data
	if not _validate_target():
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
	
	var target_pos = _get_target_position()
	var distance_to_target_pixels = global_position.distance_to(target_pos)
	var distance_to_target_meters = distance_to_target_pixels * meters_per_pixel
	
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
		# Torpedo keeps facing the original ship direction
		rotation = initial_facing_direction.angle()
		# No acceleration applied - torpedo coasts laterally
	
	# Convert to pixel movement and update position
	var velocity_pixels_per_second = velocity_mps / meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Update EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.update_entity(entity_id)

func should_ignite_engines(time_since_launch: float) -> bool:
	# Ignite engines based on EITHER time OR distance criteria
	var distance_criteria_met = lateral_distance_traveled >= lateral_launch_distance
	var time_criteria_met = time_since_launch >= engine_ignition_delay
	
	return distance_criteria_met or time_criteria_met

func ignite_engines():
	engines_ignited = true
	var target_pos = _get_target_position()
	var to_target = (target_pos - global_position).normalized()
	
	# Initialize guidance system
	previous_los = to_target

func update_smooth_rotation(delta: float):
	if velocity_mps.length() < 10.0:
		return  # Don't rotate if moving very slowly
	
	# Calculate target rotation (direction of velocity)
	target_rotation = velocity_mps.angle()
	
	# Smooth interpolation between initial rotation and target rotation
	var current_target = lerp_angle(initial_rotation, target_rotation, rotation_progress)
	
	# Apply smooth rotation with easing
	var rotation_speed = 3.0 * (1.0 + rotation_progress)  # Speed up rotation as we transition
	rotation = rotate_toward(rotation, current_target, rotation_speed * delta)

# Enhanced guidance system with smooth transition
func calculate_smooth_guidance(delta: float) -> Vector2:
	if not engines_ignited:
		return Vector2.ZERO
	
	# Calculate normal guidance commands
	var pn_command = calculate_proportional_navigation(delta)
	var direct_command = calculate_direct_intercept(delta)
	
	# Calculate dynamic mixing based on flight conditions
	var current_speed = velocity_mps.length()
	var distance_to_target = global_position.distance_to(_get_target_position()) * meters_per_pixel
	
	var effective_direct_weight = direct_weight
	
	# Increase direct guidance when moving slowly
	if current_speed < speed_threshold * 0.5:
		effective_direct_weight = min(1.0, direct_weight + 0.4)
	
	# Increase direct guidance when very close
	if distance_to_target < 200.0:
		effective_direct_weight = min(1.0, direct_weight + 0.3)
	
	# Increase direct guidance when target data confidence is low
	if target_data and target_data.confidence < 0.5:
		if not (target_data.target_node and is_instance_valid(target_data.target_node)):
			effective_direct_weight = min(1.0, direct_weight + 0.25)
	
	# Combine commands with dynamic weighting
	var pn_weight = 1.0 - effective_direct_weight
	var guidance_command = pn_command * pn_weight + direct_command * effective_direct_weight
	
	# SMOOTH TRANSITION: Gradually ramp up guidance strength
	# During early transition, add a gentle steering toward target
	var gentle_steering = Vector2.ZERO
	if transition_progress < 1.0:
		var target_pos = _get_target_position()
		var to_target = (target_pos - global_position).normalized()
		var current_velocity_normalized = velocity_mps.normalized()
		
		# Calculate gentle steering perpendicular to current velocity
		var perpendicular = Vector2(-current_velocity_normalized.y, current_velocity_normalized.x)
		var steering_amount = to_target.dot(perpendicular)
		
		# Apply gentle steering (much less aggressive than full guidance)
		gentle_steering = perpendicular * steering_amount * max_acceleration * 0.3
	
	# Blend between gentle steering and full guidance based on transition progress
	var transition_factor = smoothstep(0.0, 1.0, transition_progress)  # Smooth S-curve
	var final_command = lerp(gentle_steering, guidance_command, transition_factor)
	
	# Apply guidance strength ramp-up
	final_command *= guidance_strength
	
	# Limit maximum acceleration
	if final_command.length() > max_acceleration:
		final_command = final_command.normalized() * max_acceleration
	
	return final_command

func calculate_proportional_navigation(delta: float) -> Vector2:
	var target_pos = _get_target_position()
	var target_vel = _get_target_velocity()
	
	# Calculate line of sight vector and range
	var los_vector = target_pos - global_position
	var range_to_target = los_vector.length()
	
	if range_to_target < 1.0:
		return Vector2.ZERO
	
	var los_unit = los_vector / range_to_target
	
	# Calculate line of sight rate with proper direction
	var los_rate_vector = Vector2.ZERO
	if previous_los.length() > 0.1 and delta > 0:
		var los_change = los_unit - previous_los
		los_rate_vector = los_change / delta
	
	previous_los = los_unit
	
	# Calculate closing velocity
	var relative_velocity = target_vel - velocity_mps
	var closing_velocity = -relative_velocity.dot(los_unit)
	
	if closing_velocity <= 0:
		return Vector2.ZERO
	
	# Use the full LOS rate vector with proper direction
	var lateral_command = navigation_constant * closing_velocity
	var acceleration_command = los_rate_vector * lateral_command
	
	return acceleration_command

func calculate_direct_intercept(delta: float) -> Vector2:
	var target_pos = _get_target_position()
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

func _validate_target() -> bool:
	if not target_data:
		return false
	
	if target_data.data_source == TargetData.DataSource.DIRECT_VISUAL:
		return target_data.validate_target_node()
	
	if not target_data.is_valid():
		return false
	
	return true

func _get_target_position() -> Vector2:
	if not target_data:
		return global_position
	
	match target_data.data_source:
		TargetData.DataSource.DIRECT_VISUAL:
			if target_data.target_node and is_instance_valid(target_data.target_node):
				return target_data.target_node.global_position
			else:
				return target_data.predicted_position
		
		TargetData.DataSource.RADAR_CONTACT, TargetData.DataSource.LIDAR_CONTACT:
			if target_data.confidence >= 1.0:
				return target_data.predicted_position
			else:
				return target_data.get_uncertain_position()
		
		TargetData.DataSource.ESTIMATED, TargetData.DataSource.LOST_CONTACT:
			return target_data.get_uncertain_position()
		
		_:
			return target_data.predicted_position

func _get_target_velocity() -> Vector2:
	if not target_data:
		return Vector2.ZERO
	
	if target_data.target_node and is_instance_valid(target_data.target_node):
		if target_data.target_node.has_method("get_velocity_mps"):
			return target_data.target_node.get_velocity_mps()
		elif "velocity_mps" in target_data.target_node:
			return target_data.target_node.velocity_mps
	
	return target_data.velocity

func _impact():
	# Clean up EntityManager registration before destroying
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.queue_destroy_entity(entity_id)
	
	queue_free()

# Methods called by launcher
func set_target(target: Node2D):
	if target:
		target_id = target.name + "_" + str(target.get_instance_id())
		var target_manager = get_node_or_null("/root/TargetManager")
		if target_manager and target_manager.has_method("register_target"):
			target_data = target_manager.register_target(target)
		else:
			target_data = TargetData.new(target_id, target, target.global_position)

func set_launcher(ship: Node2D):
	launcher_ship = ship

func set_meters_per_pixel(value: float):
	meters_per_pixel = value

func set_launch_side(side: int):
	launch_side = side
