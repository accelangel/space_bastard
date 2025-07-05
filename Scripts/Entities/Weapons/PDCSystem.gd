# Scripts/Entities/Weapons/PDCSystem.gd - IMPROVED VERSION
extends Node2D
class_name PDCSystem

# PDC Configuration
@export var fire_rate: float = 200.0  # Bullets per second
@export var bullet_velocity_mps: float = 300.0  # Increased from 200 m/s
@export var bullets_per_stream: int = 25  # Increased from 25
@export var stream_spread_degrees: float = 1.0  # Increased spread for better coverage
@export var engagement_range_meters: float = 12000.0  # Reduced from 15km for earlier engagement
@export var prediction_time_seconds: float = 0.5  # How far ahead to predict torpedo path

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# References
var parent_ship: Node2D
var sensor_system: SensorSystem

# Firing control
var fire_timer: float = 0.0
var shots_fired: int = 0
var current_burst_count: int = 0
var burst_interval: float = 0.03  # Faster burst rate
var cooldown_timer: float = 0.0

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
	cooldown_timer += delta
	
	if not sensor_system:
		return
	
	# Get all enemy torpedoes
	var torpedoes = sensor_system.get_all_enemy_torpedoes()
	
	# Find the closest threatening torpedo
	var target_torpedo = find_most_threatening_torpedo(torpedoes)
	
	if target_torpedo and should_engage(target_torpedo):
		# Fire stream at torpedo path
		if current_burst_count < bullets_per_stream and fire_timer >= burst_interval:
			fire_path_saturation_bullet(target_torpedo)
			fire_timer = 0.0
			current_burst_count += 1
		elif current_burst_count >= bullets_per_stream:
			# Reset for next stream after cooldown
			if cooldown_timer >= 0.5:  # Half second between streams
				current_burst_count = 0
				cooldown_timer = 0.0
				fire_timer = 0.0

func find_most_threatening_torpedo(torpedoes: Array) -> Node2D:
	var closest_torpedo: Node2D = null
	var closest_distance: float = INF
	
	for torpedo in torpedoes:
		if not torpedo or not is_instance_valid(torpedo):
			continue
			
		var distance = global_position.distance_to(torpedo.global_position)
		if distance < closest_distance:
			closest_distance = distance
			closest_torpedo = torpedo
	
	return closest_torpedo

func should_engage(torpedo: Node2D) -> bool:
	if not torpedo or not is_instance_valid(torpedo):
		return false
	
	# Check range
	var distance_meters = global_position.distance_to(torpedo.global_position) * WorldSettings.meters_per_pixel
	if distance_meters > engagement_range_meters:
		return false
	
	# Get torpedo velocity
	var torpedo_vel = Vector2.ZERO
	if torpedo.has_method("get_velocity_mps"):
		torpedo_vel = torpedo.get_velocity_mps()
	elif "velocity_mps" in torpedo:
		torpedo_vel = torpedo.velocity_mps
	
	# Only engage if torpedo is moving towards us
	var to_torpedo = torpedo.global_position - global_position
	var approaching = torpedo_vel.dot(-to_torpedo.normalized()) > 0
	
	return approaching and torpedo_vel.length() > 10.0

func fire_path_saturation_bullet(torpedo: Node2D):
	# Get torpedo current position and velocity
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = Vector2.ZERO
	if torpedo.has_method("get_velocity_mps"):
		torpedo_vel = torpedo.get_velocity_mps()
	elif "velocity_mps" in torpedo:
		torpedo_vel = torpedo.velocity_mps
	
	# Get ship velocity
	var ship_velocity_mps = Vector2.ZERO
	if parent_ship and parent_ship.has_method("get_velocity_mps"):
		ship_velocity_mps = parent_ship.get_velocity_mps()
	
	# Calculate where torpedo will be along its path
	var prediction_times = []
	for i in range(bullets_per_stream):
		var time_factor = float(i) / float(bullets_per_stream - 1)
		var prediction_time = 0.5 + (prediction_time_seconds * time_factor)  # 0.5 to 3.0 seconds ahead
		prediction_times.append(prediction_time)
	
	# Use the current bullet's prediction time
	var bullet_prediction_time = prediction_times[current_burst_count]
	var predicted_torpedo_pos = torpedo_pos + (torpedo_vel * bullet_prediction_time)
	
	# Calculate bullet direction (from ship to predicted position)
	var base_direction = (predicted_torpedo_pos - global_position).normalized()
	
	# Add spread to create a wall across the torpedo's path
	var spread_factor = (current_burst_count - bullets_per_stream / 2.0) / float(bullets_per_stream)
	var spread_angle = deg_to_rad(stream_spread_degrees) * spread_factor
	
	# Also add some perpendicular spread to create a wider wall
	var perpendicular = base_direction.rotated(PI / 2.0)
	var perpendicular_spread = perpendicular * spread_factor * 0.3  # 30% of the main spread
	
	var bullet_direction = (base_direction + perpendicular_spread).normalized().rotated(spread_angle)
	
	# Fire the bullet
	if bullet_scene:
		var bullet = bullet_scene.instantiate()
		get_tree().root.add_child(bullet)
		
		# Set bullet properties
		bullet.global_position = global_position
		
		# Calculate bullet velocity in world space
		# Bullet velocity is relative to the ship, so add ship velocity
		var bullet_velocity_world = (bullet_direction * bullet_velocity_mps) + ship_velocity_mps
		var bullet_velocity_pixels = bullet_velocity_world / WorldSettings.meters_per_pixel
		
		if bullet.has_method("set_velocity"):
			bullet.set_velocity(bullet_velocity_pixels)
		
		# Set faction
		if parent_ship and "faction" in parent_ship:
			if bullet.has_method("set_faction"):
				bullet.set_faction(parent_ship.faction)
		
		# Connect to bullet's destruction signal
		if bullet.has_signal("hit_target"):
			bullet.hit_target.connect(_on_torpedo_intercepted)
		
		shots_fired += 1

func _on_torpedo_intercepted():
	torpedoes_intercepted += 1
	print("=== TORPEDO INTERCEPTED! Total intercepted: ", torpedoes_intercepted, " ===")

func get_debug_info() -> String:
	var status = "IDLE"
	if current_burst_count > 0:
		status = "FIRING STREAM (%d/%d)" % [current_burst_count, bullets_per_stream]
	
	return "PDC: %d shots | %d intercepts | Status: %s | Range: %.1f km" % [
		shots_fired, torpedoes_intercepted, status, engagement_range_meters / 1000.0
	]
