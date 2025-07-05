# Scripts/Entities/Weapons/PDCBullet.gd - SIMPLIFIED VERSION
extends Node2D  # Changed back to Node2D to match the scene
class_name PDCBullet

# Bullet properties
var velocity: Vector2 = Vector2.ZERO
var faction: String = "friendly"
var entity_id: String

# References
@onready var sprite: Sprite2D = $Sprite2D

func _ready():
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(self, "pdc_bullet", faction)
	
	# Set rotation to match velocity
	if velocity.length() > 0:
		rotation = velocity.angle()

func _physics_process(delta):
	# Move bullet
	global_position += velocity * delta
	
	# Update EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.update_entity_position(entity_id, global_position)
	
	# Simple collision check with all entities
	check_collisions()

func check_collisions():
	var entity_manager = get_node_or_null("/root/EntityManager")
	if not entity_manager:
		return
	
	# Check collision with all entities
	for entity_data in entity_manager.get_all_entities():
		if not is_instance_valid(entity_data.node_ref):
			continue
			
		if entity_data.entity_id == entity_id:
			continue  # Don't hit ourselves
		
		# Only check torpedoes that are hostile to us
		if entity_data.entity_type == "torpedo" and is_hostile_to_faction(entity_data.faction):
			var distance = global_position.distance_to(entity_data.position)
			if distance < 20.0:  # Simple collision radius
				# Hit! Destroy both
				entity_data.node_ref.queue_free()
				queue_free()
				return

func is_hostile_to_faction(other_faction: String) -> bool:
	# Simple faction check
	if faction == "friendly":
		return other_faction == "hostile"
	elif faction == "hostile":
		return other_faction == "friendly"
	
	return false

func set_velocity(new_velocity: Vector2):
	velocity = new_velocity
	if velocity.length() > 0:
		rotation = velocity.angle()

func set_faction(new_faction: String):
	faction = new_faction

func _exit_tree():
	# Unregister from EntityManager when destroyed
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.unregister_entity(entity_id)
