# Scripts/Systems/BatchMPCManager.gd
# Singleton that batches all torpedo MPC updates into single GPU calls
extends Node

var gpu_compute: GPUBatchCompute = null
var gpu_available: bool = false

# Torpedo tracking
var pending_torpedoes: Array = []
var active_torpedoes: Dictionary = {}  # torpedo_id -> weakref

# Update scheduling
var update_timer: float = 0.0
var update_interval: float = 0.016  # 60 FPS updates
var min_batch_size: int = 1
var max_batch_size: int = 256

# Performance tracking
var total_batches: int = 0
var total_torpedoes_processed: int = 0
var last_batch_time: float = 0.0
var largest_batch: int = 0

# Debug
var debug_enabled: bool = true

func _ready():
	# Set up as singleton
	set_process(true)
	
	# Initialize GPU compute
	gpu_compute = GPUBatchCompute.new()
	gpu_available = gpu_compute.is_available()
	
	if gpu_available:
		print("[BatchMPC] GPU batch processing available!")
	else:
		print("[BatchMPC] GPU not available - torpedoes will use individual CPU fallback")
	
	# Listen for game mode changes
	if GameMode:
		GameMode.mode_changed.connect(_on_mode_changed)

func _on_mode_changed(new_mode: GameMode.Mode):
	if new_mode != GameMode.Mode.BATTLE:
		# Clear all pending updates when leaving battle mode
		clear_all_pending()

func register_torpedo(torpedo: Node2D):
	"""Called by torpedoes to register for batch updates"""
	if not gpu_available:
		return  # Let torpedo handle its own updates
	
	var torpedo_id = torpedo.get("torpedo_id")
	if not torpedo_id:
		push_error("[BatchMPC] Torpedo has no ID!")
		return
	
	# Store weak reference to avoid keeping dead torpedoes
	active_torpedoes[torpedo_id] = weakref(torpedo)
	
	if debug_enabled:
		print("[BatchMPC] Registered torpedo: %s" % torpedo_id)

func unregister_torpedo(torpedo_id: String):
	"""Called when torpedo is destroyed"""
	active_torpedoes.erase(torpedo_id)
	
	# Remove from pending if queued
	for i in range(pending_torpedoes.size() - 1, -1, -1):
		if pending_torpedoes[i].torpedo_id == torpedo_id:
			pending_torpedoes.remove_at(i)

func request_update(torpedo: Node2D, update_priority: float = 1.0):
	"""Queue a torpedo for batch update"""
	if not gpu_available:
		return
	
	# Check if already pending
	for pending in pending_torpedoes:
		if pending.torpedo == torpedo:
			pending.priority = max(pending.priority, update_priority)
			return
	
	# Add to pending queue
	pending_torpedoes.append({
		"torpedo": torpedo,
		"torpedo_id": torpedo.get("torpedo_id"),
		"priority": update_priority,
		"request_time": Time.get_ticks_msec() / 1000.0
	})

func _process(delta):
	if not gpu_available:
		return
	
	update_timer += delta
	
	# Process batch at update interval
	if update_timer >= update_interval:
		update_timer = 0.0
		process_pending_batch()
	
	# Clean up dead references periodically
	if Engine.get_physics_frames() % 300 == 0:  # Every 5 seconds at 60 FPS
		cleanup_dead_references()

func process_pending_batch():
	"""Process all pending torpedoes in one GPU batch"""
	if pending_torpedoes.is_empty():
		return
	
	var start_time = Time.get_ticks_usec()
	
	# Sort by priority (highest first)
	pending_torpedoes.sort_custom(func(a, b): return a.priority > b.priority)
	
	# Prepare batch data
	var batch_torpedoes = []
	var batch_states = []
	var batch_targets = []
	var batch_flight_plans = []
	
	# Process up to max_batch_size torpedoes
	var count = min(pending_torpedoes.size(), max_batch_size)
	
	for i in range(count):
		var pending = pending_torpedoes[i]
		var torpedo = pending.torpedo
		
		# Validate torpedo still exists
		if not is_instance_valid(torpedo) or torpedo.get("marked_for_death"):
			continue
		
		# Get torpedo state
		var state = {
			"position": torpedo.global_position,
			"velocity": torpedo.get("velocity_mps"),
			"orientation": torpedo.get("orientation"),
			"angular_velocity": torpedo.get("angular_velocity"),
			"max_acceleration": torpedo.get("max_acceleration"),
			"max_rotation_rate": torpedo.get("max_rotation_rate")
		}
		
		# Get target state
		var target = torpedo.get("target_node")
		if not target or not is_instance_valid(target):
			continue
			
		var target_state = {
			"position": target.global_position,
			"velocity": target.get("velocity_mps") if target.has_method("get_velocity_mps") else Vector2.ZERO
		}
		
		# Get flight plan data
		var flight_plan = {
			"type": torpedo.get("flight_plan_type", "straight"),
			"side": 0.0,
			"impact_time": 0.0
		}
		
		# For multi-angle, determine side
		if flight_plan.type == "multi_angle":
			var launch_side = torpedo.get("launch_side", 1)
			flight_plan.side = float(launch_side)
		
		# For simultaneous, get assigned angle and impact time
		elif flight_plan.type == "simultaneous":
			var flight_data = torpedo.get("flight_plan_data", {})
			if flight_data.has("impact_angle"):
				flight_plan.side = flight_data.impact_angle  # Using side field for angle
			if flight_data.has("impact_time"):
				flight_plan.impact_time = flight_data.impact_time
		
		batch_torpedoes.append(torpedo)
		batch_states.append(state)
		batch_targets.append(target_state)
		batch_flight_plans.append(flight_plan)
	
	# Clear processed items
	pending_torpedoes = pending_torpedoes.slice(count)
	
	if batch_torpedoes.is_empty():
		return
	
	# Process batch on GPU
	var results = gpu_compute.evaluate_torpedo_batch(batch_states, batch_targets, batch_flight_plans)
	
	# Apply results
	for i in range(batch_torpedoes.size()):
		var torpedo = batch_torpedoes[i]
		if is_instance_valid(torpedo) and i < results.size():
			# Let torpedo apply the control
			if torpedo.has_method("apply_mpc_control"):
				torpedo.apply_mpc_control(results[i])
	
	# Update stats
	var batch_time = (Time.get_ticks_usec() - start_time) / 1000.0
	last_batch_time = batch_time
	total_batches += 1
	total_torpedoes_processed += batch_torpedoes.size()
	largest_batch = max(largest_batch, batch_torpedoes.size())
	
	if debug_enabled:
		print("[BatchMPC] Processed %d torpedoes in %.2fms" % [
			batch_torpedoes.size(), batch_time
		])

func cleanup_dead_references():
	"""Remove dead torpedo references"""
	var dead_ids = []
	
	for id in active_torpedoes:
		var ref = active_torpedoes[id]
		if not ref.get_ref():
			dead_ids.append(id)
	
	for id in dead_ids:
		active_torpedoes.erase(id)
	
	if dead_ids.size() > 0 and debug_enabled:
		print("[BatchMPC] Cleaned up %d dead torpedo references" % dead_ids.size())

func clear_all_pending():
	"""Clear all pending updates"""
	pending_torpedoes.clear()
	update_timer = 0.0

func get_stats() -> Dictionary:
	return {
		"active_torpedoes": active_torpedoes.size(),
		"pending_updates": pending_torpedoes.size(),
		"total_batches": total_batches,
		"total_processed": total_torpedoes_processed,
		"last_batch_time_ms": last_batch_time,
		"largest_batch": largest_batch,
		"gpu_available": gpu_available
	}

# Priority calculation helpers
static func calculate_priority(torpedo: Node2D) -> float:
	"""Calculate update priority for a torpedo"""
	var update_priority = 1.0
	
	# Higher priority if close to target
	var target = torpedo.get("target_node")
	if target and is_instance_valid(target):
		var distance = torpedo.global_position.distance_to(target.global_position)
		if distance < 5000:  # Very close
			update_priority += 10.0
		elif distance < 10000:  # Close
			update_priority += 5.0
	
	# Higher priority if just launched
	var launch_time = torpedo.get("launch_start_time")
	if launch_time == null:
		launch_time = 0.0
	var age = Time.get_ticks_msec() / 1000.0 - launch_time
	if age < 2.0:
		update_priority += 3.0
	
	return update_priority
