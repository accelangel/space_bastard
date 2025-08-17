# Scripts/Entities/Ships/PlayerShip.gd - WITH FLOATING ORIGIN SUPPORT
extends Area2D
class_name PlayerShip

# Ship properties
@export var acceleration_gs: float = 0.0
@export var rotation_speed: float = 2.0
@export var faction: String = "friendly"

# Movement
var acceleration_mps2: float
var velocity_mps: Vector2 = Vector2.ZERO
var movement_direction: Vector2 = Vector2(1, -1).normalized()  # Default movement direction

# TRUE POSITION TRACKING (for floating origin)
var true_position: Vector2 = Vector2.ZERO

# Identity
var entity_id: String = ""
var ship_name: String = "Player Ship"
var is_alive: bool = true
var marked_for_death: bool = false

# Child nodes
@onready var sensor_system: SensorSystem = $SensorSystem
@onready var torpedo_launcher: Node2D = $TorpedoLauncher
@onready var fire_control_manager = $FireControlManager

# DEBUG CONTROL
@export var debug_enabled: bool = false

func _ready():
	print("[PlayerShip] _ready() called")
	acceleration_mps2 = acceleration_gs * 9.81
	
	# Generate unique ID
	entity_id = "player_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	# Self-identify
	add_to_group("ships")
	add_to_group("player_ships")
	add_to_group("combat_entities")
	
	# Store identity as metadata
	set_meta("entity_id", entity_id)
	set_meta("faction", faction)
	set_meta("entity_type", "player_ship")
	
	FloatingOrigin.origin_shifted.connect(_on_origin_shifted)
	
	# Initialize true position
	true_position = FloatingOrigin.visual_to_true(global_position)
	
	# SHIP SCALE DEBUG
	var sprite = get_node_or_null("Sprite2D")
	if sprite:
		var texture_size = sprite.texture.get_size()
		var scaled_size = texture_size * sprite.scale
		var size_in_meters = scaled_size * WorldSettings.meters_per_pixel
		
		print("\n=== PLAYER SHIP SCALE DEBUG ===")
		print("  Texture size: %s pixels" % texture_size)
		print("  Sprite scale: %s" % sprite.scale)
		print("  Final sprite size: %s pixels" % scaled_size)
		print("  Meters per pixel: %.1f" % WorldSettings.meters_per_pixel)
		print("  ACTUAL SIZE: %.1f m long x %.1f m wide" % [size_in_meters.y, size_in_meters.x])
		
		# Calculate what scale would be needed for different ship sizes
		var donnager_length_m = 500.0
		var roci_length_m = 46.0  # The actual Rocinante size
		var required_scale_donnager = donnager_length_m / (texture_size.y * WorldSettings.meters_per_pixel)
		var required_scale_roci = roci_length_m / (texture_size.y * WorldSettings.meters_per_pixel)
		print("  For 500m Donnager-class, would need scale: %.6f" % required_scale_donnager)
		print("  For 46m Rocinante-class, would need scale: %.6f" % required_scale_roci)
		print("================================\n")
	
	# ALWAYS enable movement immediately
	enable_movement()
	
	print("Player ship spawned: %s" % entity_id)

func _on_origin_shifted(shift_amount: Vector2):
	"""Handle floating origin shifts - visual position already shifted by FloatingOrigin"""
	# Update our true position to compensate for the visual shift
	true_position -= shift_amount
	if debug_enabled:
		print("[PlayerShip] Origin shifted, true pos: %s, visual pos: %s" % [true_position, global_position])

func _physics_process(delta):
	if marked_for_death or not is_alive:
		return
	
	# Update movement in true space
	var acceleration_vector = movement_direction * acceleration_mps2
	velocity_mps += acceleration_vector * delta
	
	# Update true position
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	true_position += velocity_pixels_per_second * delta
	
	# Convert true position to visual position for rendering
	global_position = FloatingOrigin.true_to_visual(true_position)

func enable_movement():
	print("[PlayerShip] Movement ENABLED")
	set_movement_direction(movement_direction)
	if debug_enabled:
		print("PlayerShip movement enabled at %.1fG" % acceleration_gs)

func _input(event):
	if marked_for_death or not is_alive:
		return
	
	# SPACE key - direct torpedo fire
	if event.is_action_pressed("ui_accept"):
		print("[PlayerShip] SPACE key pressed - firing torpedo")
		fire_torpedoes_at_enemy()

func fire_torpedoes_at_enemy():
	if not torpedo_launcher:
		print("No torpedo launcher!")
		return
		
	# Find closest enemy ship
	var enemy_ships = get_tree().get_nodes_in_group("enemy_ships")
	var closest_enemy = null
	var closest_distance = INF
	
	for ship in enemy_ships:
		if "is_alive" in ship and ship.is_alive:
			var distance = global_position.distance_to(ship.global_position)
			if distance < closest_distance:
				closest_distance = distance
				closest_enemy = ship
	
	if closest_enemy:
		print("Player firing torpedo at enemy ship")
		torpedo_launcher.fire_torpedo(closest_enemy)
	else:
		print("No enemy ships found to target")

func set_movement_direction(new_direction: Vector2):
	movement_direction = new_direction.normalized()

func set_acceleration(gs: float):
	acceleration_gs = gs
	acceleration_mps2 = acceleration_gs * 9.81

func get_velocity_mps() -> Vector2:
	return velocity_mps

func mark_for_destruction(_reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	# Disable physics
	set_physics_process(false)
	set_process_input(false)
	
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	print("Player ship destroyed!")

func get_faction() -> String:
	return faction

func get_entity_id() -> String:
	return entity_id

func get_true_position() -> Vector2:
	"""Get true world position for accurate distance calculations"""
	return true_position

func get_true_distance_to(other_pos: Vector2) -> float:
	"""Calculate true distance to another position"""
	# If other_pos is visual, it's already in the same space as our visual position
	return global_position.distance_to(other_pos)
