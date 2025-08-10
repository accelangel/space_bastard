# Scripts/Entities/Weapons/SimpleTorpedo.gd
extends Area2D
class_name SimpleTorpedo

# Guidance parameters (simplified)
@export var turn_speed: float = 3.0          # How fast torpedo rotates toward target
@export var acceleration: float = 980.0      # 100G forward thrust

# Torpedo identity
var torpedo_id: String = ""
var faction: String = "friendly"
var target_node: Node2D = null
var launch_time: float = 0.0

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var is_alive: bool = true
var marked_for_death: bool = false

func _ready():
	# Cap FPS for consistent debugging
	Engine.max_fps = 60
	
	# Generate unique ID
	torpedo_id = "torpedo_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	launch_time = Time.get_ticks_msec() / 1000.0
	
	# Add to groups
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	# Store identity
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	# Connect collision
	area_entered.connect(_on_area_entered)
	
	# Start animation if present
	var sprite = get_node_or_null("AnimatedSprite2D")
	if sprite:
		sprite.play()
	
	print("SimpleTorpedo %s launched" % torpedo_id)

func _physics_process(delta):
	if marked_for_death or not is_alive or not target_node:
		return
	
	# Validate target still exists
	if not is_instance_valid(target_node):
		mark_for_destruction("lost_target")
		return
	
	# Calculate current speed
	var current_speed = velocity_mps.length()
	
	# Get target state directly
	var target_pos = target_node.global_position
	var target_velocity = Vector2.ZERO
	if target_node.has_method("get_velocity_mps"):
		target_velocity = target_node.get_velocity_mps()
	
	# Calculate intercept point using proper physics
	var intercept_point = calculate_intercept(global_position, velocity_mps, target_pos, target_velocity)
	
	# Aim at intercept point
	var to_intercept = intercept_point - global_position
	
	# Calculate desired direction  
	var desired_direction = to_intercept.normalized()
	var desired_angle = desired_direction.angle()
	
	# Proportional control - turn toward desired direction
	var angle_diff = angle_difference(rotation, desired_angle)
	var rotation_rate = angle_diff * turn_speed
	rotation += rotation_rate * delta
	
	# Always accelerate forward at full thrust
	var thrust_direction = Vector2.from_angle(rotation)
	velocity_mps += thrust_direction * acceleration * delta
	
	# Debug print every 2 seconds
	if int(Time.get_ticks_msec() / 2000.0) != int((Time.get_ticks_msec() - delta * 1000) / 2000.0):
		var speed_kms = current_speed / 1000.0
		var distance_km = (target_pos - global_position).length() * WorldSettings.meters_per_pixel / 1000.0
		var target_vel_kms = target_velocity.length() / 1000.0
		var intercept_distance_km = to_intercept.length() * WorldSettings.meters_per_pixel / 1000.0
		var angle_to_target = rad_to_deg(desired_angle)
		var current_heading = rad_to_deg(rotation)
		var angle_error = rad_to_deg(angle_diff)
		print("Torpedo %s: Speed=%.1f km/s, TargetDist=%.1f km, TargetVel=%.1f km/s, InterceptDist=%.1f km, Heading=%.1f°, Error=%.1f°" % 
			  [torpedo_id, speed_kms, distance_km, target_vel_kms, intercept_distance_km, current_heading, angle_error])
	
	# Update position
	var velocity_pixels = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels * delta
	
	# Check bounds
	check_world_bounds()

func calculate_intercept(torpedo_pos: Vector2, torpedo_vel: Vector2, target_pos: Vector2, target_vel: Vector2) -> Vector2:
	"""Calculate intercept point using iterative approach"""
	
	# If target is stationary, aim directly at it
	if target_vel.length() < 1.0:  # Effectively stationary
		return target_pos
	
	# Initial estimate: assume torpedo current speed is maintained
	var torpedo_speed = torpedo_vel.length()
	if torpedo_speed < 1000.0:  # If too slow, assume we'll accelerate to 5 km/s
		torpedo_speed = 5000.0
	
	# Simple linear prediction
	var range_to_target = (target_pos - torpedo_pos).length() * WorldSettings.meters_per_pixel
	var time_estimate = range_to_target / torpedo_speed
	
	# Predict where target will be
	var target_vel_pixels = target_vel / WorldSettings.meters_per_pixel
	var intercept_point = target_pos + target_vel_pixels * time_estimate
	
	return intercept_point

func angle_difference(from: float, to: float) -> float:
	var diff = fmod(to - from + PI, TAU) - PI
	return diff

func check_world_bounds():
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		mark_for_destruction("out_of_bounds")

func _on_area_entered(area: Area2D):
	if marked_for_death or not is_alive:
		return
	
	# Check for ship collision
	if area.is_in_group("ships"):
		# Don't hit friendly ships
		if area.get("faction") == faction:
			return
		
		print("SimpleTorpedo %s hit target!" % torpedo_id)
		
		# Destroy target ship if it has the method
		if area.has_method("mark_for_destruction"):
			area.mark_for_destruction("torpedo_impact")
		
		mark_for_destruction("target_impact")

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	print("SimpleTorpedo %s destroyed: %s" % [torpedo_id, reason])
	
	# Disable physics and collision
	set_physics_process(false)
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	queue_free()

# Public interface for launcher
func set_target(target: Node2D):
	target_node = target

func set_launcher(launcher_ship: Node2D):
	if "faction" in launcher_ship:
		faction = launcher_ship.faction

# Compatibility methods (not used but may be called)
func set_launch_side(_side: int):
	pass

func set_flight_plan(_plan: String, _data: Dictionary = {}):
	pass

func get_velocity_mps() -> Vector2:
	return velocity_mps
