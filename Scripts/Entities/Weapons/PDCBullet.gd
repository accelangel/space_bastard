# Scripts/Weapons/PDCBullet.gd
extends Node2D
class_name PDCBullet

@export var damage: float = 25.0
@export var max_lifetime: float = 3.0  # Seconds before bullet despawns
@export var collision_radius: float = 5.0  # Pixels

# Movement
var velocity: Vector2 = Vector2.ZERO
var faction_type: int = 1  # FactionType.PLAYER by default

# Lifecycle
var lifetime: float = 0.0
var entity_id: String

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

func _physics_process(delta):
	lifetime += delta
	
	# Move bullet
	global_position += velocity * delta
	
	# Check for collisions with entities
	check_collisions()
	
	# Despawn if too old
	if lifetime >= max_lifetime:
		despawn()

func check_collisions():
	var entity_manager = get_node_or_null("/root/EntityManager")
	if not entity_manager:
		return
	
	# Get entities in collision radius
	var nearby_entities = entity_manager.get_entities_in_radius(
		global_position,
		collision_radius,
		[EntityManager.EntityType.ENEMY_SHIP, EntityManager.EntityType.TORPEDO, EntityManager.EntityType.MISSILE],
		[EntityManager.FactionType.ENEMY],  # Only hit enemies
		[EntityManager.EntityState.DESTROYED, EntityManager.EntityState.CLEANUP]
	)
	
	# Check for actual collision
	for entity_data in nearby_entities:
		if entity_data.entity_id == entity_id:
			continue  # Don't hit ourselves
		
		var distance = global_position.distance_to(entity_data.position)
		var combined_radius = collision_radius + entity_data.radius
		
		if distance <= combined_radius:
			# Hit!
			hit_target(entity_data)
			break

func hit_target(target_entity):
	print("PDC bullet hit: ", target_entity.entity_id)
	
	# Deal damage if target has health
	if target_entity.node_ref and target_entity.node_ref.has_method("take_damage"):
		target_entity.node_ref.take_damage(damage)
	
	# Remove bullet
	despawn()

func set_velocity(new_velocity: Vector2):
	velocity = new_velocity
	if velocity.length() > 0:
		rotation = velocity.angle()

func set_faction(new_faction: int):
	faction_type = new_faction

func despawn():
	# Unregister from EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.queue_destroy_entity(entity_id)
	
	# Remove from scene
	queue_free()
