# Scripts/Resources/EnemyShipConfig.gd
class_name EnemyShipConfig
extends Resource

@export var ship_name: String = "Standard Enemy"
@export var acceleration_gs: float = 0.35
@export var max_speed_mps: float = 1000.0
@export var pdc_fire_rate: float = 10.0  # Bullets per second
@export var pdc_bullet_velocity_mps: float = 800.0
@export var torpedo_count: int = 6
@export var ship_texture: Texture2D
