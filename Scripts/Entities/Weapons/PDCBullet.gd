# Scripts/Entities/Weapons/PDCBullet.gd - FIXED COLLISION ROUTING
extends Area2D
class_name PDCBullet

# Bullet properties
var velocity: Vector2 = Vector2.ZERO
var faction: String = ""
var entity_id: String = ""  # This will be set by EntityManager
var source_pdc_id: String = ""  # NEW: Track which PDC fired this bullet

# References
@onready var sprite: Sprite2D = $Sprite2D

func _ready():
	# Connect collision signal
	area_entered.connect(_on_area_entered)
	
	# Set rotation to match velocity
	if velocity.length() > 0:
		rotation = velocity.angle() + 3*PI/2

func _physics_process(delta):
	# Move bullet
	global_position += velocity * delta
	
	# Update EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.update_entity_position(entity_id, global_position)

func _on_area_entered(area: Area2D):
	var entity_manager = get_node_or_null("/root/EntityManager")
	if not entity_manager or not entity_id:
		return
	
	var other_entity_id = ""
	
	# Get entity_id from the other object
	if area.has_meta("entity_id"):
		other_entity_id = area.get_meta("entity_id")
	elif "entity_id" in area and area.entity_id != "":
		other_entity_id = area.entity_id
	else:
		# NO WARNING - too spammy
		return
	
	# Report collision - EntityManager will handle destruction
	entity_manager.report_collision(entity_id, other_entity_id, global_position)

func set_velocity(new_velocity: Vector2):
	velocity = new_velocity
	if velocity.length() > 0:
		rotation = velocity.angle() + 3*PI/2

func set_faction(new_faction: String):
	faction = new_faction

func set_source_pdc(pdc_id: String):
	source_pdc_id = pdc_id

# ENHANCED: Initialize bullet with EntityManager registration
func initialize_bullet(bullet_faction: String, pdc_id: String):
	faction = bullet_faction
	source_pdc_id = pdc_id
	
	# Register with EntityManager, passing source PDC info
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(self, "pdc_bullet", faction, source_pdc_id)

func _exit_tree():
	# Unregister from EntityManager when destroyed
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.unregister_entity(entity_id)
