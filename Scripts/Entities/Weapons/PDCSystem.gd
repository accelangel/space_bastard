# Scripts/Entities/Weapons/PDCSystem.gd - COMPLETE REWRITE
extends Node2D
class_name PDCSystem

# PDC Configuration
@export var fire_rate: float = 20.0  # Bullets per second
@export var bullet_velocity_mps: float = 800.0  # m/s
@export var wall_spread_angle: float = 15.0  # Degrees of spread for bullet wall
@export var bullets_per_wall: int = 5  # Number of bullets in each wall

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# References
var parent_ship: Node2D
var sensor_system: SensorSystem

# Firing control
var fire_timer: float = 0.0
var shots_fired: int = 0

func _ready():
	parent_ship = get_parent()
	
	# Find sensor system on parent
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if not sensor_system:
			print("PDCSystem: No sensor system found on parent ship!")
	
	var ship_name = parent_ship.name if parent_ship else "unknown"
	print("PDCSystem initialized on ", ship_name)

func _physics_process(delta):
	fire_timer += delta
	
	if not sensor_system:
		return
	
	# Check if we can fire
	var time_between_shots = 1.0 / fire_rate
	if fire_timer < time_between_shots:
		return
	
	# Get all enemy torpedoes
	var torpedoes = sensor_system.get_all_enemy_torpedoes()
	
	for torpedo in torpedoes:
		if should_engage(torpedo):
			create_bullet_wall_across_path(torpedo)
			fire_timer = 0.0  # Reset timer after firing
			break  # Only engage one torpedo per firing cycle

func should_engage(torpedo: Node2D) -> bool:
	if not torpedo or not is_instance_valid(torpedo):
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

func create_bullet_wall_across_path(torpedo: Node2D):
	# Get torpedo velocity
	var torpedo_vel = Vector2.ZERO
	if torpedo.has_method("get_velocity_mps"):
		torpedo_vel = torpedo.get_velocity_mps()
	elif "velocity_mps" in torpedo:
		torpedo_vel = torpedo.velocity_mps
	
	if torpedo_vel.length() < 10.0:  # Torpedo not moving much
		return
	
	# Calculate intercept point
	var intercept_point = calculate_simple_intercept(torpedo.global_position, torpedo_vel)
	
	# Calculate spread perpendicular to line from ship to intercept
	var to_intercept = (intercept_point - global_position).normalized()
	
	# Create wall of bullets
	var angle_step = deg_to_rad(wall_spread_angle) / float(bullets_per_wall - 1)
	var start_angle = -deg_to_rad(wall_spread_angle) / 2.0
	
	for i in range(bullets_per_wall):
		var angle_offset = start_angle + (angle_step * i)
		var bullet_direction = to_intercept.rotated(angle_offset)
		fire_bullet(bullet_direction)
		
	shots_fired += bullets_per_wall
	
	if shots_fired % 100 == 0:  # Log every 100 shots
		print("PDC has fired ", shots_fired, " bullets")

func calculate_simple_intercept(target_pos: Vector2, target_vel: Vector2) -> Vector2:
	# Simple linear intercept - where will target be in 1 second?
	var time_to_intercept = 1.0  # Predict 1 second ahead
	return target_pos + target_vel * time_to_intercept

func fire_bullet(direction: Vector2):
	if not bullet_scene:
		return
	
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# Set bullet properties
	bullet.global_position = global_position
	
	# Set velocity
	var bullet_velocity_pixels = direction * (bullet_velocity_mps / WorldSettings.meters_per_pixel)
	if bullet.has_method("set_velocity"):
		bullet.set_velocity(bullet_velocity_pixels)
	
	# Set faction
	if parent_ship and "faction" in parent_ship:
		if bullet.has_method("set_faction"):
			bullet.set_faction(parent_ship.faction)

func get_debug_info() -> String:
	return "PDC: %d shots fired" % shots_fired
