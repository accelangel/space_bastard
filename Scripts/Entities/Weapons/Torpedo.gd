extends Area2D
class_name Torpedo

# Torpedo specifications
@export var max_acceleration: float = 1470.0    # 150 Gs in m/s²
@export var launch_kick_velocity: float = 50.0   # Initial sideways impulse m/s
@export var proximity_meters: float = 10.0       # Auto-detonate range

# Intercept guidance parameters
@export var navigation_constant: float = 3.0     # Proportional navigation gain
@export var direct_weight: float = 0.05          # Direct intercept influence (0.0 to 1.0)
@export var speed_threshold: float = 200.0       # m/s - speed threshold for guidance transitions

# Direct intercept PID parameters
@export var kp: float = 800.0        # Proportional gain
@export var ki: float = 50.0         # Integral gain
@export var kd: float = 150.0        # Derivative gain

# TARGET DATA SYSTEM - New approach
var target_data: TargetData          # Our target information
var target_id: String               # ID of our target
var use_uncertain_data: bool = true # Whether to use confidence-based positioning

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var launcher_ship: Node2D

# IMPORTANT: No default value! Must be set by launcher
var meters_per_pixel: float

# Intercept guidance state
var previous_los: Vector2 = Vector2.ZERO
var previous_los_rate: float = 0.0
var previous_error: Vector2 = Vector2.ZERO
var integral_error: Vector2 = Vector2.ZERO
var integral_decay: float = 0.95      # Prevents integral windup

# Debug tracking
var launch_time: float = 0.0
var total_distance_traveled: float = 0.0

func _ready():
	launch_time = Time.get_ticks_msec() / 1000.0
	print("TORPEDO _ready() called at time: ", launch_time)
	print("  Initial position: ", global_position)
	print("  Using meters_per_pixel: ", meters_per_pixel)
	
	if not target_data and target_id.is_empty():
		print("No target data or ID set - destroying torpedo")
		queue_free()
		return
	
	# If we have target_id but no target_data, try to get it from TargetManager
	if target_id and not target_data:
		target_data = TargetManager.get_target_data(target_id)
		if not target_data:
			print("Could not find target data for ID: ", target_id)
			queue_free()
			return
	
	if meters_per_pixel <= 0:
		print("ERROR: Invalid meters_per_pixel value: ", meters_per_pixel)
		meters_per_pixel = WorldSettings.meters_per_pixel  # Fallback
		print("  Using fallback from WorldSettings: ", meters_per_pixel)
	
	# Calculate initial direction toward target
	var target_pos = _get_target_position()
	var to_target = (target_pos - global_position).normalized()
	
	# Small perpendicular kick + forward velocity
	var perpendicular = Vector2(-to_target.y, to_target.x)
	var side_kick = perpendicular * launch_kick_velocity * (1.0 if randf() > 0.5 else -1.0)
	var forward_kick = to_target * 100.0
	
	velocity_mps = side_kick + forward_kick
	previous_los = to_target
	
	print("  Applied launch kick: ", velocity_mps, " m/s")
	print("  Distance to target: ", global_position.distance_to(target_pos) * meters_per_pixel, " meters")
	print("  Target confidence: ", target_data.confidence if target_data else "N/A")

func _physics_process(delta):
	# Validate target data
	if not _validate_target():
		print("Target lost or invalid - destroying torpedo")
		queue_free()
		return
	
	# Get current target position (may include uncertainty)
	var target_pos = _get_target_position()
	
	# Check proximity for detonation
	var distance_to_target_pixels = global_position.distance_to(target_pos)
	var distance_to_target_meters = distance_to_target_pixels * meters_per_pixel
	
	if distance_to_target_meters < proximity_meters:
		_impact()
		return
	
	# Track total distance traveled
	var speed_mps = velocity_mps.length()
	total_distance_traveled += speed_mps * delta
	
	# Calculate intercept trajectory using target data
	var commanded_acceleration = calculate_intercept_guidance(delta)
	
	# Apply acceleration
	velocity_mps += commanded_acceleration * delta
	
	# Convert to pixel movement
	var velocity_pixels_per_second = velocity_mps / meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Orient torpedo to face movement direction
	if velocity_mps.length() > 10.0:
		rotation = velocity_mps.angle()
	
	# Debug output
	if Engine.get_process_frames() % 60 == 0:
		debug_output(distance_to_target_meters, distance_to_target_pixels)

# Validate that we still have a valid target
func _validate_target() -> bool:
	if not target_data:
		return false
	
	# Check if target data is still valid
	if not target_data.is_valid():
		print("Target data became invalid (age: ", target_data.data_age, "s, confidence: ", target_data.confidence, ")")
		return false
	
	return true

# Get target position, potentially with uncertainty
func _get_target_position() -> Vector2:
	if not target_data:
		return global_position  # Fallback to avoid crashes
	
	if use_uncertain_data:
		return target_data.get_uncertain_position()
	else:
		return target_data.predicted_position

# Get target velocity for prediction
func _get_target_velocity() -> Vector2:
	if not target_data:
		return Vector2.ZERO
	
	return target_data.velocity

func calculate_intercept_guidance(delta: float) -> Vector2:
	# Calculate proportional navigation component
	var pn_command = calculate_proportional_navigation(delta)
	
	# Calculate direct intercept component  
	var direct_command = calculate_direct_intercept(delta)
	
	# Calculate dynamic mixing based on flight conditions and target data quality
	var current_speed = velocity_mps.length()
	var distance_to_target = global_position.distance_to(_get_target_position()) * meters_per_pixel
	
	# Use more direct guidance when:
	# 1. Moving slowly (startup phase)
	# 2. Very close to target (terminal phase)
	# 3. Target data confidence is low (less reliable proportional navigation)
	
	var effective_direct_weight = direct_weight
	
	# Increase direct guidance when moving slowly
	if current_speed < speed_threshold * 0.5:
		effective_direct_weight = min(1.0, direct_weight + 0.4)
	
	# Increase direct guidance when very close
	if distance_to_target < 200.0:  # Within 200 meters
		effective_direct_weight = min(1.0, direct_weight + 0.3)
	
	# Increase direct guidance when target data confidence is low
	if target_data and target_data.
