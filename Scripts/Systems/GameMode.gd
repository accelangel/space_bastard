# GameMode.gd - Autoload singleton
extends Node

enum Mode {
	NONE,           # No mode selected yet
	BATTLE,         # Normal battle mode
	PID_TUNING      # PID tuning mode
}

var current_mode: Mode = Mode.NONE
var mode_start_time: float = 0.0

signal mode_changed(new_mode: Mode)

func _ready():
	print("GameMode singleton initialized")

func set_mode(new_mode: Mode):
	if current_mode == new_mode:
		return
	
	var old_mode = current_mode
	
	# Clean up previous mode
	match current_mode:
		Mode.BATTLE:
			_cleanup_battle_mode()
		Mode.PID_TUNING:
			_cleanup_pid_tuning_mode()
	
	# Set new mode
	current_mode = new_mode
	mode_start_time = Time.get_ticks_msec() / 1000.0
	
	print("\n" + "=".repeat(50))
	print("GAME MODE CHANGED: %s -> %s" % [Mode.keys()[old_mode], Mode.keys()[new_mode]])
	print("=".repeat(50) + "\n")
	
	# Emit signal for all systems to reconfigure
	emit_signal("mode_changed", new_mode)

func is_battle_mode() -> bool:
	return current_mode == Mode.BATTLE

func is_pid_tuning_mode() -> bool:
	return current_mode == Mode.PID_TUNING

func get_mode_name() -> String:
	return Mode.keys()[current_mode]

func _cleanup_battle_mode():
	# Force end any active battle
	var battle_managers = get_tree().get_nodes_in_group("battle_managers")
	for bm in battle_managers:
		if bm.has_method("force_end_battle"):
			bm.force_end_battle()
	
	# Clean up all combat entities
	_cleanup_all_combat_entities()

func _cleanup_pid_tuning_mode():
	# Stop any active tuning
	if Engine.has_singleton("TunerSystem"):
		var tuner = Engine.get_singleton("TunerSystem")
		if tuner and tuner.has_method("emergency_stop"):
			tuner.emergency_stop()
	
	# Clean up all combat entities
	_cleanup_all_combat_entities()

func _cleanup_all_combat_entities():
	# Remove all torpedoes
	for torpedo in get_tree().get_nodes_in_group("torpedoes"):
		if is_instance_valid(torpedo):
			torpedo.queue_free()
	
	# Remove all bullets
	for bullet in get_tree().get_nodes_in_group("bullets"):
		if is_instance_valid(bullet):
			bullet.queue_free()
	
	print("Cleaned up all combat entities")
