# Scripts/Entities/Weapons/PDCBullet.gd - FIXED VERSION
extends Area2D
class_name PDCBullet

# Signals
signal hit_target

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
	
	# Connect collision signal
	area_entered.connect(_on_area_entered)
	
	# Set rotation to match velocity
	if velocity.length() > 0:
		# Try different offsets to match your sprite orientation
		# Start with PI (180 degrees) since you mentioned it's shooting backwards
		rotation = velocity.angle() +3*PI/2 # I have tried + PI, PI/2, - PI/2, nothing changes, it just shoots backwards!!!

func _physics_process(delta):
	# Move bullet
	global_position += velocity * delta
	
	# Update EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.update_entity_position(entity_id, global_position)

func _on_area_entered(area: Area2D):
	# DEBUG: Log all collisions
	var area_name = "Unknown"
	if area.has_method("get_name"):
		area_name = str(area.name)
	
	print("🎯 BULLET COLLISION: Bullet hit %s (faction: %s)" % [
		area_name,
		area.faction if "faction" in area else "Unknown"
	])
	
	# Check if we hit something hostile
	if is_hostile_to(area):
		print("✅ CONFIRMED HIT: Bullet from faction %s hit hostile %s" % [faction, area.faction])
		
		# Emit signal before destroying
		hit_target.emit()
		print("📡 SIGNAL EMITTED: hit_target signal sent")
		
		# Both bullet and target die instantly
		area.queue_free()
		queue_free()
	else:
		print("❌ FRIENDLY FIRE AVOIDED: Same faction collision")

func is_hostile_to(other: Node) -> bool:
	if not "faction" in other:
		print("⚠️ NO FACTION: Target has no faction property")
		return false
	
	# Simple faction check
	if faction == "friendly":
		return other.faction == "hostile"
	elif faction == "hostile":
		return other.faction == "friendly"
	
	return false

func set_velocity(new_velocity: Vector2):
	velocity = new_velocity
	if velocity.length() > 0:
		# Apply the same offset here
		rotation = velocity.angle() +3*PI/2 # I have tried + PI, PI/2, - PI/2, nothing changes, it just shoots backwards!!!

func set_faction(new_faction: String):
	faction = new_faction

func _exit_tree():
	# Unregister from EntityManager when destroyed
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.unregister_entity(entity_id)
