# Data/TargetData.gd
class_name TargetData
extends RefCounted

var target_id: String
var position: Vector2
var velocity: Vector2
var confidence: float = 1.0
var last_update_time: float
