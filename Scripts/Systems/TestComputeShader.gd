# TestComputeShader.gd
# Add this script to any Node in your scene to test if GPU compute works
extends Node

func _ready():
	print("\n=== TESTING BASIC GPU COMPUTE ===")
	
	# Create rendering device
	var rd = RenderingServer.create_local_rendering_device()
	
	if not rd:
		print("FAILED: Cannot create rendering device")
		print("Your GPU doesn't support compute shaders in Godot")
		return
	
	print("SUCCESS: Created rendering device")
	print("Device: %s" % rd.get_device_name())
	
	# Create the simplest possible compute shader
	var shader_source = """
#version 450

layout(local_size_x = 1) in;

layout(set = 0, binding = 0, std430) buffer DataBuffer {
	float data[];
} buf;

void main() {
	uint i = gl_GlobalInvocationID.x;
	buf.data[i] = buf.data[i] * 2.0;
}
"""
	
	# Create shader file
	var shader_file = RDShaderFile.new()
	shader_file.set_stage_source(RDShaderFile.STAGE_COMPUTE, shader_source)
	
	# Try to compile
	var shader_spirv = shader_file.get_spirv()
	
	if not shader_spirv:
		print("FAILED: Cannot compile shader")
		var error = shader_file.get_base_error()
		if error:
			print("Error: %s" % error)
		return
	
	print("SUCCESS: Shader compiled to SPIR-V")
	
	# Create shader
	var shader = rd.shader_create_from_spirv(shader_spirv)
	
	if not shader:
		print("FAILED: Cannot create shader from SPIR-V")
		return
	
	print("SUCCESS: Created shader")
	
	# Create pipeline
	var pipeline = rd.compute_pipeline_create(shader)
	
	if not pipeline:
		print("FAILED: Cannot create pipeline")
		return
	
	print("SUCCESS: Created pipeline")
	
	# Create test data
	var test_data = PackedFloat32Array([1.0, 2.0, 3.0, 4.0])
	var buffer = rd.storage_buffer_create(test_data.size() * 4, test_data.to_byte_array())
	
	# Create uniform set
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(buffer)
	var uniform_set = rd.uniform_set_create([uniform], shader, 0)
	
	# Run compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, 4, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	# Read results
	var output_bytes = rd.buffer_get_data(buffer)
	var output = output_bytes.to_float32_array()
	
	print("Input data: %s" % str(test_data))
	print("Output data: %s" % str(output))
	
	# Verify it worked
	if output[0] == 2.0 and output[1] == 4.0 and output[2] == 6.0 and output[3] == 8.0:
		print("\n*** GPU COMPUTE IS WORKING! ***")
		print("The problem is with the complex MPC shader, not GPU support")
	else:
		print("\n*** GPU COMPUTE FAILED ***")
		print("Results are wrong - GPU compute isn't working properly")
	
	# Cleanup
	rd.free_rid(buffer)
	rd.free_rid(uniform_set)
	rd.free_rid(shader)
	rd.free_rid(pipeline)
	
	print("=== TEST COMPLETE ===\n")
