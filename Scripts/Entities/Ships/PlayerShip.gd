# ==== UPDATED PlayerShip.gd Integration ====
# Add this to Scripts/Entities/Ships/PlayerShip.gd

extends BaseShip
class_name PlayerShip

@export var rotation_speed: float = 2.0

func _ready():
	super._ready()
	movement_direction = Vector2.ZERO

func _physics_process(delta):
	super._physics_process(delta)
	# Player control logic here

func _get_entity_type() -> int:
	return 1  # EntityManager.EntityType.PLAYER_SHIP

func _get_faction_type() -> int:
	return 1  # EntityManager.FactionType.PLAYER

func get_ship_type() -> String:
	return "PlayerShip"
