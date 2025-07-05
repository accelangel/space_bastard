# Scripts/Weapons/PDCBullet.gd - FIXED LIFETIME AND COLLISION
extends Node2D
class_name PDCBullet

@export var damage: float = 25.0
@export var max_lifetime: float = 20.0  # FIXED: Much longer lifetime - 20 seconds
@export var collision_radius: float = 10.0  # Slightly larger collision radius

# Movement
var velocity: Vector2 = Vector2.ZERO
var faction_type: int = 1

# Lifecycle
var lifetime: float = 0.0
var entity_id: String
var distance_traveled: float = 0.0

# Node references
@onready var sprite: Sprite2D = $Sprite2D

func _ready():
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(
			self,
			EntityManager.EntityType.PROJECTILE,
			faction_type
		)
	
	# Set initial rotation to match movement direction
	if velocity.length() > 0:
		rotation = velocity.angle()
	
	print("PDC Bullet created with velocity: ", velocity.length(), " pixels/second")

func _physics_process(delta):
	lifetime += delta
	
	# Move bullet
	var movement_this_frame = velocity * delta
	global_position += movement_this_frame
	distance_traveled += movement_this_frame.length()
	
	# Check for collisions with entities
	check_collisions()
	
	# FIXED: More reasonable despawn conditions
	var max_distance_pixels = 25000.0  # 25km in pixels (25000 * 0.25m = 6.25km actual)
	
	# Despawn if too old OR traveled too far
	if lifetime >= max_lifetime:
		print("PDC Bullet despawned: max lifetime reached (", lifetime, "s)")
		despawn()
	elif distance_traveled >= max_distance_pixels:
		print("PDC Bullet despawned: max distance reached (", distance_traveled * WorldSettings.meters_per_pixel / 1000.0, " km)")
		despawn()

func check_collisions():
	var entity_manager = get_node_or_null("/root/EntityManager")
	if not entity_manager:
		return
	
	# Target enemy projectiles (torpedoes, missiles)
	var target_entity_types: Array[EntityManager.EntityType] = [
		EntityManager.EntityType.TORPEDO, 
		EntityManager.EntityType.MISSILE
	]
	
	# Target entities from enemy factions only
	var enemy_factions: Array[EntityManager.FactionType] = []
	if faction_type == 1:  # Player bullet targets enemy projectiles
		enemy_factions = [EntityManager.FactionType.ENEMY]
	else:  # Enemy bullet targets player projectiles
		enemy_factions = [EntityManager.FactionType.PLAYER]
	
	var exclude_states: Array[EntityManager.EntityState] = [
		EntityManager.EntityState.DESTROYED, 
		EntityManager.EntityState.CLEANUP
	]
	
	# Get entities in collision radius
	var nearby_entities = entity_manager.get_entities_in_radius(
		global_position,
		collision_radius,
		target_entity_types,
		enemy_factions,
		exclude_states
	)
	
	# Check for actual collision
	for entity_data in nearby_entities:
		if entity_data.entity_id == entity_id:
			continue  # Don't hit ourselves
		
		# Don't hit entities of our own faction
		if entity_data.faction == faction_type:
			continue
		
		var distance = global_position.distance_to(entity_data.position)
		var combined_radius = collision_radius + entity_data.radius
		
		if distance <= combined_radius:
			# Hit!
			hit_target(entity_data)
			break

func hit_target(target_entity):
	print("PDC bullet (faction %d) hit target: %s at distance %.1f km" % [
		faction_type, 
		target_entity.entity_id, 
		distance_traveled * WorldSettings.meters_per_pixel / 1000.0
	])
	
	# Deal damage if target has health
	if target_entity.node_ref and target_entity.node_ref.has_method("take_damage"):
		target_entity.node_ref.take_damage(damage)
	
	# Remove bullet
	despawn()

func set_velocity(new_velocity: Vector2):
	velocity = new_velocity
	if velocity.length() > 0:
		rotation = velocity.angle()
	
	# Log the velocity for debugging
	var speed_mps = velocity.length() * WorldSettings.meters_per_pixel
	print("PDC Bullet velocity set: ", speed_mps, " m/s (", velocity.length(), " pixels/s)")

func set_faction(new_faction: int):
	faction_type = new_faction

func despawn():
	# Unregister from EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.queue_destroy_entity(entity_id)
	
	# Remove from scene
	queue_free()

func get_debug_info() -> String:
	var speed_mps = velocity.length() * WorldSettings.meters_per_pixel
	var distance_km = distance_traveled * WorldSettings.meters_per_pixel / 1000.0
	
	return "PDC Bullet: %.0f m/s, %.2f km traveled, %.1fs old" % [speed_mps, distance_km, lifetime]
