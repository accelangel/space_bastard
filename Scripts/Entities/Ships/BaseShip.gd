# ==== UPDATED BaseShip.gd Integration ====
# Add this to Scripts/Entities/Ships/BaseShip.gd

extends Node2D
class_name BaseShip

@export var acceleration_gs: float = 0.35

var acceleration_mps2: float
var velocity_mps: Vector2 = Vector2.ZERO
var ship_id: String
var entity_id: String  # NEW: EntityManager ID

var movement_direction: Vector2 = Vector2(0, 1)

var meters_per_pixel: float:
	get:
		return WorldSettings.meters_per_pixel

func _ready():
	ship_id = name + "_" + str(get_instance_id())
	acceleration_mps2 = acceleration_gs * 9.81
	
	# Register with new EntityManager instead of just ShipManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		var entity_type = _get_entity_type()
		var faction = _get_faction_type()
		entity_id = entity_manager.register_entity(self, entity_type, faction)
		print("Ship registered with EntityManager: ", entity_id)
	
	# Keep ShipManager registration for backward compatibility
	if has_node("/root/ShipManager"):
		get_node("/root/ShipManager").register_ship(self)

func _physics_process(_delta):
	# Update EntityManager with our new position
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.update_entity(entity_id)

# Override in subclasses
func _get_entity_type() -> int:  # EntityManager.EntityType
	return 0  # EntityManager.EntityType.UNKNOWN

func _get_faction_type() -> int:  # EntityManager.FactionType
	return 0  # EntityManager.FactionType.NEUTRAL

func get_ship_type() -> String:
	return "BaseShip"

func get_velocity_mps() -> Vector2:
	return velocity_mps

func set_movement_direction(new_direction: Vector2):
	movement_direction = new_direction.normalized()

func set_acceleration(gs: float):
	acceleration_gs = gs
	acceleration_mps2 = acceleration_gs * 9.81
