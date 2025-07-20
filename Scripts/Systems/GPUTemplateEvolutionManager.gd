# Scripts/Systems/GPUTemplateEvolution.gd
class_name GPUTemplateEvolution
extends RefCounted

var rd: RenderingDevice
var shader: RID
var pipeline: RID

# Persistent buffers
var template_buffer: RID
var fitness_buffer: RID
var evolution_params_buffer: RID
var random_state_buffer: RID

# Evolution parameters
var population_size: int = 60
var mutation_rate: float = 0.1
var crossover_rate: float = 0.7
var elite_ratio: float = 0.2
var tournament_size: int = 3

# Template constraints by type
var template_constraints: Dictionary = {
	"straight": {
		"thrust": {"min": 0.5, "max": 1.0},
		"rotation": {"min": 5.0, "max": 15.0}
	},
	"multi_angle": {
		"thrust": {"min": 0.6, "max": 1.0},
		"rotation": {"min": 8.0, "max": 20.0}
	},
	"simultaneous": {
		"thrust": {"min": 0.7, "max": 1.0},
		"rotation": {"min": 10.0, "max": 25.0}
	}
}

# Fitness tracking
var fitness_history: Dictionary = {}  # template_id -> Array of fitness scores
var generation_count: int = 0

# Debug
var debug_enabled: bool = true

func _init():
	print("[GPU Template Evolution] Initializing...")
	
	# Get rendering device
	rd = RenderingServer.create_local_rendering_device()
	
	if not rd:
		push_error("[GPU Template Evolution] Failed to create rendering device!")
		return
	
	# Load evolution shader
	_setup_shader()
	
	# Initialize buffers
	_create_persistent_buffers()

func _setup_shader():
	# Try to load the evolution shader
	var shader_paths = [
		"res://Shaders/mpc_template_evolution.glsl",
		"res://Scripts/Systems/mpc_template_evolution.glsl",
		"res://shaders/mpc_template_evolution.glsl"
	]
	
	var shader_file = null
	for path in shader_paths:
		if ResourceLoader.exists(path):
			shader_file = load(path)
			if shader_file:
				print("[GPU Template Evolution] Loaded shader from: %s" % path)
				break
	
	if not shader_file:
		push_error("[GPU Template Evolution] Failed to load evolution shader!")
		return
	
	# Create shader and pipeline
	var shader_spirv = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)
	
	if not shader.is_valid():
		push_error("[GPU Template Evolution] Failed to create shader!")
		return
	
	pipeline = rd.compute_pipeline_create(shader)
	
	if not pipeline.is_valid():
		push_error("[GPU Template Evolution] Failed to create pipeline!")
		return
	
	print("[GPU Template Evolution] Shader initialized successfully!")

func _create_persistent_buffers():
	"""Create reusable buffers for evolution"""
	
	# Template buffer - vec4 per template
	var template_data = PackedFloat32Array()
	template_data.resize(population_size * 4)
	
	# Initialize with random templates
	for i in range(population_size):
		var offset = i * 4
		template_data[offset] = randf_range(0.7, 1.0)      # thrust_factor
		template_data[offset + 1] = randf_range(8.0, 12.0) # rotation_gain
		template_data[offset + 2] = randf_range(-5.0, 5.0) # angle_offset
		template_data[offset + 3] = randf_range(0.3, 0.7)  # alignment_weight
	
	template_buffer = rd.storage_buffer_create(
		template_data.size() * 4,
		template_data.to_byte_array()
	)
	
	# Fitness buffer - vec4 per template (fitness, success_rate, usage_count, age)
	var fitness_data = PackedFloat32Array()
	fitness_data.resize(population_size * 4)
	# Initialize all to zero
	fitness_buffer = rd.storage_buffer_create(
		fitness_data.size() * 4,
		fitness_data.to_byte_array()
	)
	
	# Evolution parameters buffer
	var evolution_data = PackedFloat32Array([
		mutation_rate,
		crossover_rate,
		elite_ratio,
		float(tournament_size),
		# Constraints (using default "straight" for now)
		0.5, 1.0,  # min/max thrust
		5.0, 15.0  # min/max rotation
	])
	
	evolution_params_buffer = rd.storage_buffer_create(
		evolution_data.size() * 4,
		evolution_data.to_byte_array()
	)
	
	# Random state buffer - one uint per template
	var random_data = PackedByteArray()
	random_data.resize(population_size * 4)
	
	# Initialize with random seeds
	for i in range(population_size):
		var seed_value = randi()
		# Pack uint as 4 bytes
		random_data[i * 4] = seed_value & 0xFF
		random_data[i * 4 + 1] = (seed_value >> 8) & 0xFF
		random_data[i * 4 + 2] = (seed_value >> 16) & 0xFF
		random_data[i * 4 + 3] = (seed_value >> 24) & 0xFF
	
	random_state_buffer = rd.storage_buffer_create(
		random_data.size(),
		random_data
	)
	
	print("[GPU Template Evolution] Created buffers for %d templates" % population_size)

func evolve_population(trajectory_type: String = "straight"):
	"""Run one generation of evolution on GPU"""
	
	if not rd or not pipeline.is_valid():
		push_error("[GPU Template Evolution] GPU not initialized!")
		return
	
	var start_time = Time.get_ticks_usec()
	
	# Update evolution parameters for trajectory type
	_update_evolution_parameters(trajectory_type)
	
	# Sort templates by fitness (CPU side for now)
	_sort_templates_by_fitness()
	
	# Create uniform set with bindings
	var bindings = [
		_create_buffer_binding(0, template_buffer),
		_create_buffer_binding(1, fitness_buffer),
		_create_buffer_binding(2, evolution_params_buffer),
		_create_buffer_binding(3, random_state_buffer)
	]
	
	var uniform_set = rd.uniform_set_create(bindings, shader, 0)
	
	# Dispatch compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# One thread per template
	var workgroup_count = ceili(float(population_size) / 32.0)
	rd.compute_list_dispatch(compute_list, workgroup_count, 1, 1)
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	# Clean up uniform set
	rd.free_rid(uniform_set)
	
	generation_count += 1
	
	var evolution_time = (Time.get_ticks_usec() - start_time) / 1000.0
	
	if debug_enabled:
		print("[GPU Template Evolution] Generation %d complete in %.2fms" % [
			generation_count, evolution_time
		])

func update_template_fitness(template_index: int, hit_success: bool, trajectory_quality: float = 0.0):
	"""Update fitness score for a specific template"""
	
	if template_index < 0 or template_index >= population_size:
		return
	
	# Read current fitness data
	var fitness_bytes = rd.buffer_get_data(fitness_buffer)
	var fitness_data = fitness_bytes.to_float32_array()
	
	var offset = template_index * 4
	var current_fitness = fitness_data[offset]
	var success_rate = fitness_data[offset + 1]
	var usage_count = fitness_data[offset + 2]
	var age = fitness_data[offset + 3]
	
	# Update fitness with exponential moving average
	var fitness_delta = 1.0 if hit_success else -0.5
	fitness_delta += trajectory_quality * 0.5  # Bonus for smooth trajectories
	
	var alpha = 0.1
	current_fitness = (1.0 - alpha) * current_fitness + alpha * fitness_delta
	
	# Update success rate
	var success_value = 1.0 if hit_success else 0.0
	success_rate = (1.0 - alpha) * success_rate + alpha * success_value
	
	# Increment usage count
	usage_count += 1
	
	# Update buffer
	fitness_data[offset] = current_fitness
	fitness_data[offset + 1] = success_rate
	fitness_data[offset + 2] = usage_count
	fitness_data[offset + 3] = age
	
	rd.buffer_update(fitness_buffer, offset * 4, 16, fitness_data.slice(offset, offset + 4).to_byte_array())
	
	# Track in history
	var template_id = "template_%d" % template_index
	if not fitness_history.has(template_id):
		fitness_history[template_id] = []
	fitness_history[template_id].append(current_fitness)

func get_template(index: int) -> Dictionary:
	"""Get a specific template's parameters"""
	
	if index < 0 or index >= population_size:
		return {}
	
	# Read template data
	var template_bytes = rd.buffer_get_data(template_buffer)
	var template_data = template_bytes.to_float32_array()
	
	var offset = index * 4
	return {
		"thrust_factor": template_data[offset],
		"rotation_gain": template_data[offset + 1],
		"initial_angle_offset": template_data[offset + 2],
		"alignment_weight": template_data[offset + 3],
		"template_index": index
	}

func get_best_templates(count: int = 10) -> Array:
	"""Get the top N templates by fitness"""
	
	# Read all fitness scores
	var fitness_bytes = rd.buffer_get_data(fitness_buffer)
	var fitness_data = fitness_bytes.to_float32_array()
	
	# Create array of (index, fitness) pairs
	var template_fitness_pairs = []
	for i in range(population_size):
		template_fitness_pairs.append({
			"index": i,
			"fitness": fitness_data[i * 4]
		})
	
	# Sort by fitness (descending)
	template_fitness_pairs.sort_custom(func(a, b): return a.fitness > b.fitness)
	
	# Get top N templates
	var best_templates = []
	for i in range(min(count, template_fitness_pairs.size())):
		var index = template_fitness_pairs[i].index
		var template = get_template(index)
		template["fitness"] = template_fitness_pairs[i].fitness
		best_templates.append(template)
	
	return best_templates

func select_template_for_torpedo() -> Dictionary:
	"""Select a template using weighted random selection based on fitness"""
	
	# Get all templates with their fitness
	var templates = []
	var fitness_bytes = rd.buffer_get_data(fitness_buffer)
	var fitness_data = fitness_bytes.to_float32_array()
	
	var total_fitness = 0.0
	for i in range(population_size):
		var fitness = fitness_data[i * 4]
		# Add small constant to avoid zero fitness
		fitness = max(fitness + 1.0, 0.1)
		templates.append({"index": i, "fitness": fitness})
		total_fitness += fitness
	
	# Weighted random selection
	var random_value = randf() * total_fitness
	var cumulative = 0.0
	
	for template in templates:
		cumulative += template.fitness
		if cumulative >= random_value:
			return get_template(template.index)
	
	# Fallback to last template
	return get_template(population_size - 1)

func _update_evolution_parameters(trajectory_type: String):
	"""Update evolution parameters buffer for specific trajectory type"""
	
	var constraints = template_constraints.get(trajectory_type, template_constraints["straight"])
	
	var evolution_data = PackedFloat32Array([
		mutation_rate,
		crossover_rate,
		elite_ratio,
		float(tournament_size),
		constraints.thrust.min,
		constraints.thrust.max,
		constraints.rotation.min,
		constraints.rotation.max
	])
	
	rd.buffer_update(evolution_params_buffer, 0, evolution_data.size() * 4, evolution_data.to_byte_array())

func _sort_templates_by_fitness():
	"""Sort templates by fitness (CPU side) to establish elite set"""
	
	# Read current data
	var template_bytes = rd.buffer_get_data(template_buffer)
	var template_data = template_bytes.to_float32_array()
	
	var fitness_bytes = rd.buffer_get_data(fitness_buffer)
	var fitness_data = fitness_bytes.to_float32_array()
	
	# Create sortable array
	var templates = []
	for i in range(population_size):
		templates.append({
			"index": i,
			"template": template_data.slice(i * 4, (i + 1) * 4),
			"fitness": fitness_data.slice(i * 4, (i + 1) * 4)
		})
	
	# Sort by fitness
	templates.sort_custom(func(a, b): return a.fitness[0] > b.fitness[0])
	
	# Repack into buffers
	var sorted_template_data = PackedFloat32Array()
	var sorted_fitness_data = PackedFloat32Array()
	
	for template in templates:
		sorted_template_data.append_array(template.template)
		sorted_fitness_data.append_array(template.fitness)
	
	# Update buffers
	rd.buffer_update(template_buffer, 0, sorted_template_data.size() * 4, sorted_template_data.to_byte_array())
	rd.buffer_update(fitness_buffer, 0, sorted_fitness_data.size() * 4, sorted_fitness_data.to_byte_array())

func _create_buffer_binding(binding: int, buffer: RID) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform

func get_evolution_stats() -> Dictionary:
	"""Get statistics about the evolution process"""
	
	# Calculate average fitness
	var fitness_bytes = rd.buffer_get_data(fitness_buffer)
	var fitness_data = fitness_bytes.to_float32_array()
	
	var total_fitness = 0.0
	var best_fitness = -INF
	var worst_fitness = INF
	var total_usage = 0
	
	for i in range(population_size):
		var offset = i * 4
		var fitness = fitness_data[offset]
		var usage = int(fitness_data[offset + 2])
		
		total_fitness += fitness
		best_fitness = max(best_fitness, fitness)
		worst_fitness = min(worst_fitness, fitness)
		total_usage += usage
	
	return {
		"generation": generation_count,
		"population_size": population_size,
		"avg_fitness": total_fitness / population_size,
		"best_fitness": best_fitness,
		"worst_fitness": worst_fitness,
		"total_template_uses": total_usage,
		"mutation_rate": mutation_rate,
		"elite_ratio": elite_ratio
	}

func cleanup():
	"""Clean up GPU resources"""
	if rd:
		if template_buffer.is_valid():
			rd.free_rid(template_buffer)
		if fitness_buffer.is_valid():
			rd.free_rid(fitness_buffer)
		if evolution_params_buffer.is_valid():
			rd.free_rid(evolution_params_buffer)
		if random_state_buffer.is_valid():
			rd.free_rid(random_state_buffer)
		if shader.is_valid():
			rd.free_rid(shader)
		if pipeline.is_valid():
			rd.free_rid(pipeline)
	print("[GPU Template Evolution] Cleaned up GPU resources")
