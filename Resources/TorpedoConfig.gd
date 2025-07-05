# Scripts/Resources/TorpedoConfig.gd
class_name TorpedoConfig
extends Resource

enum LaunchPattern {
	SINGLE,
	RAPID_SALVO,
	COORDINATED_STRIKE
}

@export var torpedo_name: String = "Standard Torpedo"
@export var launch_pattern: LaunchPattern = LaunchPattern.SINGLE
@export var salvo_count: int = 1
@export var approach_angles: Array[float] = []  # For coordinated strikes
@export var fragments_on_approach: bool = false
@export var fragment_count: int = 0
@export var fragment_range_meters: float = 20000.0 # 20 km fragment distance
