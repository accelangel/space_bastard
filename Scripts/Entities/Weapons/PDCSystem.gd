# Scripts/Entities/Weapons/PDCSystem.gd - COMPLETE REWRITE
extends Node2D
class_name PDCSystem

# PDC Configuration
@export var fire_rate: float = 50.0  # Bullets per second
@export var bullet_velocity_mps: float = 200.0  # m/s
@export var bullets_per_stream: int = 25  # Number of bullets in each stream
@export var stream_spread_degrees: float = 5.0  # Much tighter spread for a stream effect
@export var engagement_range_meters: float = 15000.0  # 15km - when to start firing

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# References
var parent_ship: Node2D
var sensor_system: SensorSystem

# Firing control
var fire_timer: float = 0.0
var shots_fired: int = 0
var current_burst_count: int = 0
var burst_interval: float = 0.05  # Time between bullets in a stream

# Statistics
var torpedoes_intercepted: int = 0

func _ready():
	parent_ship = get_parent()
	
	# Find sensor system on parent
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if not sensor_system:
			print("PDCSystem: No sensor system found on parent ship!")
	
	var ship_name: String = "unknown"
	if parent_ship:
		ship_name = parent_ship.name
	print("PDCSystem initialized on ", ship_name)
	print("  Engagement range: ", engagement_range_meters / 1000.0, " km")
	print("  Stream pattern: ", bullets_per_stream, " bullets with ", stream_spread_degrees, "° spread")

func _physics_process(delta):
	fire_timer += delta
	
	if not sensor_system:
		return
	
	# Get all enemy torpedoes
	var torpedoes = sensor_system.get_all_enemy_torpedoes()
	
	for torpedo in torpedoes:
		if should_engage(torpedo):
			# Fire a stream at this torpedo
			if current_burst_count < bullets_per_stream and fire_timer >= burst_interval:
				fire_stream_bullet(torpedo)
				fire_timer = 0.0
				current_burst_count += 1
			elif current_burst_count >= bullets_per_stream:
				# Reset for next stream after a short cooldown
				if fire_timer >= 1.0 / fire_rate:
					current_burst_count = 0
					fire_timer = 0.0
			break  # Only engage one torpedo at a time

func should_engage(torpedo: Node2D) -> bool:
	if not torpedo or not is_instance_valid(torpedo):
		return false
	
	# Check range first
	var distance_meters = global_position.distance_to(torpedo.global_position) * WorldSettings.meters_per_pixel
	if distance_meters > engagement_range_meters:
		return false
	
	# Get torpedo velocity
	var torpedo_vel = Vector2.ZERO
	if torpedo.has_method("get_velocity_mps"):
		torpedo_vel = torpedo.get_velocity_mps()
	elif "velocity_mps" in torpedo:
		torpedo_vel = torpedo.velocity_mps
	
	# Check if torpedo is approaching
	var to_torpedo = torpedo.global_position - global_position
	var approaching = torpedo_vel.dot(-to_torpedo.normalized()) > 0
	
	return approaching

func fire_stream_bullet(torpedo: Node2D):
	# Get torpedo velocity for prediction
	var torpedo_vel = Vector2.ZERO
	if torpedo.has_method("get_velocity_mps"):
		torpedo_vel = torpedo.get_velocity_mps()
	elif "velocity_mps" in torpedo:
		torpedo_vel = torpedo.velocity_mps
	
	if torpedo_vel.length() < 10.0:  # Torpedo not moving much
		return
	
	# Get ship velocity
	var ship_velocity_mps = Vector2.ZERO
	if parent_ship and parent_ship.has_method("get_velocity_mps"):
		ship_velocity_mps = parent_ship.get_velocity_mps()
	
	# Calculate intercept point accounting for ship movement
	var intercept_point = calculate_intercept_with_ship_velocity(
		torpedo.global_position, 
		torpedo_vel,
		ship_velocity_mps
	)
	
	# Calculate base direction to intercept
	var to_intercept = (intercept_point - global_position).normalized()
	
	# Add a small spread to create the stream effect
	# The spread increases slightly with each bullet in the stream
	var spread_factor = (current_burst_count - bullets_per_stream / 2.0) / float(bullets_per_stream)
	var spread_angle = deg_to_rad(stream_spread_degrees) * spread_factor
	
	var bullet_direction = to_intercept.rotated(spread_angle)
	
	# Fire the bullet
	if bullet_scene:
		var bullet = bullet_scene.instantiate()
		get_tree().root.add_child(bullet)
		
		# Set bullet properties
		bullet.global_position = global_position
		
		# Calculate bullet velocity (relative to world, includes ship velocity)
		var bullet_velocity_relative = bullet_direction * bullet_velocity_mps
		var bullet_velocity_world = bullet_velocity_relative + ship_velocity_mps
		var bullet_velocity_pixels = bullet_velocity_world / WorldSettings.meters_per_pixel
		
		if bullet.has_method("set_velocity"):
			bullet.set_velocity(bullet_velocity_pixels)
		
		# Set faction
		if parent_ship and "faction" in parent_ship:
			if bullet.has_method("set_faction"):
				bullet.set_faction(parent_ship.faction)
		
		# Connect to bullet's destruction signal to track interceptions
		if bullet.has_signal("hit_target"):
			bullet.hit_target.connect(_on_torpedo_intercepted)
		
		shots_fired += 1

func calculate_intercept_with_ship_velocity(target_pos: Vector2, target_vel: Vector2, ship_vel: Vector2) -> Vector2:
	# Calculate relative velocity (target relative to ship)
	var relative_target_vel = target_vel - ship_vel
	var relative_pos = target_pos - global_position
	var distance = relative_pos.length()
	
	# Bullet speed relative to ship
	var bullet_speed_mps = bullet_velocity_mps
	var bullet_speed_pixels = bullet_speed_mps / WorldSettings.meters_per_pixel
	
	# More sophisticated intercept calculation accounting for relative motion
	# Using quadratic formula to solve for intercept time
	var a = relative_target_vel.dot(relative_target_vel) - bullet_speed_mps * bullet_speed_mps
	var b = 2.0 * relative_pos.dot(relative_target_vel)
	var c = relative_pos.dot(relative_pos)
	
	var discriminant = b * b - 4.0 * a * c
	
	if discriminant < 0 or abs(a) < 0.01:
		# No intercept possible, aim directly at current position
		return target_pos
	
	var t1 = (-b - sqrt(discriminant)) / (2.0 * a)
	var t2 = (-b + sqrt(discriminant)) / (2.0 * a)
	
	# Choose the earliest positive time
	var intercept_time = 0.0
	if t1 > 0 and t2 > 0:
		intercept_time = min(t1, t2)
	elif t1 > 0:
		intercept_time = t1
	elif t2 > 0:
		intercept_time = t2
	else:
		# No valid intercept time
		return target_pos
	
	# Return predicted intercept position
	return target_pos + target_vel * intercept_time

func _on_torpedo_intercepted():
	torpedoes_intercepted += 1
	print("=== TORPEDO INTERCEPTED! Total intercepted: ", torpedoes_intercepted, " ===")

func get_debug_info() -> String:
	var status = "IDLE"
	if current_burst_count > 0:
		status = "FIRING STREAM"
	
	return "PDC: %d shots | %d intercepts | Status: %s | Range: %.1f km" % [
		shots_fired, torpedoes_intercepted, status, engagement_range_meters / 1000.0
	]
