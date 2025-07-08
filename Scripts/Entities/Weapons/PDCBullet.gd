# Scripts/Entities/Weapons/PDCBullet.gd - FIXED SOURCE TRACKING
extends Area2D
class_name PDCBullet

# Bullet properties
var velocity: Vector2 = Vector2.ZERO
var faction: String = ""
var entity_id: String = ""
var source_pdc_id: String = ""  # FIXED: Better tracking of source PDC

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
	
	# Get entity_id from the other object - try multiple methods
	if area.has_meta("entity_id"):
		other_entity_id = area.get_meta("entity_id")
	elif "entity_id" in area and area.entity_id != "":
		other_entity_id = area.entity_id
	else:
		# Can't identify the other entity, skip collision
		return
	
	# Validate that we have both IDs
	if other_entity_id == "" or entity_id == "":
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

# ENHANCED: Initialize bullet with proper source tracking
func initialize_bullet(bullet_faction: String, pdc_id: String):
	faction = bullet_faction
	source_pdc_id = pdc_id
	
	# Register with EntityManager, ensuring source PDC is properly tracked
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(self, "pdc_bullet", faction, pdc_id)
		# FIXED: Also store on the node for collision detection
		set_meta("entity_id", entity_id)
		set_meta("source_pdc_id", pdc_id)

func _exit_tree():
	# Unregister from EntityManager when destroyed
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.unregister_entity(entity_id)
