#version 450

// Each thread evaluates one trajectory candidate
layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;

// Input: Current torpedo and target states
layout(set = 0, binding = 0, std430) restrict readonly buffer InputData {
    vec4 torpedo_state;      // x, y, vx, vy
    vec4 torpedo_orient;     // orientation, angular_vel, max_accel, max_rotation
    vec4 target_state;       // x, y, vx, vy
    vec4 sim_params;         // dt, num_steps, meters_per_pixel, 0
} input_data;

// Input: Template parameters for trajectory generation
layout(set = 0, binding = 1, std430) restrict readonly buffer Templates {
    vec4 template_params[];  // thrust_factor, rotation_gain, initial_angle_offset, alignment_weight
} templates;

// Output: Costs and best control
layout(set = 0, binding = 2, std430) restrict writeonly buffer Results {
    float costs[];           // Cost for each trajectory
    uint best_index;         // Index of best template
    float best_cost;         // Best cost found
    vec4 best_control;       // Best control (thrust, rotation_rate, 0, 0)
} results;

// Shared memory for parallel reduction
shared float shared_costs[32];
shared uint shared_indices[32];

// Helper functions
vec2 rotate_vector(vec2 v, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float angle_difference(float from, float to) {
    float diff = to - from;
    const float TAU = 6.28318530718;
    const float PI = 3.14159265359;
    
    while (diff > PI) diff -= TAU;
    while (diff < -PI) diff += TAU;
    
    return diff;
}

void main() {
    uint tid = gl_GlobalInvocationID.x;
    uint local_tid = gl_LocalInvocationID.x;
    
    // Don't run extra threads
    uint num_templates = uint(templates.template_params.length());
    if (tid >= num_templates) return;
    
    // Get template parameters
    vec4 template = templates.template_params[tid];
    float thrust_factor = template.x;
    float rotation_gain = template.y;
    float initial_angle_offset = template.z;
    float alignment_weight = template.w;
    
    // Extract input data
    vec2 pos = input_data.torpedo_state.xy;
    vec2 vel = input_data.torpedo_state.zw;
    float orientation = input_data.torpedo_orient.x;
    float angular_vel = input_data.torpedo_orient.y;
    float max_accel = input_data.torpedo_orient.z;
    float max_rotation = input_data.torpedo_orient.w;
    
    vec2 target_pos = input_data.target_state.xy;
    vec2 target_vel = input_data.target_state.zw;
    
    float dt = input_data.sim_params.x;
    uint num_steps = uint(input_data.sim_params.y);
    float meters_per_pixel = input_data.sim_params.z;
    
    // Initialize trajectory cost
    float total_cost = 0.0;
    float distance_cost = 0.0;
    float control_cost = 0.0;
    float alignment_cost = 0.0;
    
    // Add initial angle offset
    vec2 to_target = target_pos - pos;
    float base_angle = atan(to_target.y, to_target.x);
    float desired_angle = base_angle + radians(initial_angle_offset);
    
    // Store first control for output
    float first_thrust = 0.0;
    float first_rotation = 0.0;
    
    // Simulate trajectory
    for (uint i = 0; i < num_steps; i++) {
        // Predict target position
        vec2 predicted_target = target_pos + target_vel * (float(i) * dt);
        
        // Calculate desired orientation
        vec2 to_predicted = predicted_target - pos;
        float target_angle = atan(to_predicted.y, to_predicted.x);
        
        // After initial phase, track the target
        if (i > num_steps / 10) {
            desired_angle = target_angle;
        }
        
        // Calculate control
        float angle_error = angle_difference(orientation, desired_angle);
        float rotation_rate = clamp(angle_error * rotation_gain, -max_rotation, max_rotation);
        
        // Thrust based on alignment
        float alignment = abs(angle_error);
        float thrust = max_accel * thrust_factor * (1.0 - min(alignment / 3.14159, 0.5));
        
        // Store first control
        if (i == 0) {
            first_thrust = thrust;
            first_rotation = rotation_rate;
        }
        
        // Update physics
        orientation += rotation_rate * dt;
        angular_vel = rotation_rate;
        
        vec2 thrust_dir = vec2(cos(orientation), sin(orientation));
        vec2 accel = thrust_dir * thrust;
        vel += accel * dt;
        pos += vel * dt;
        
        // Accumulate costs
        float dist_sq = dot(to_predicted, to_predicted);
        distance_cost += dist_sq * meters_per_pixel * meters_per_pixel;
        
        // Alignment cost
        if (length(vel) > 10.0) {
            float vel_angle = atan(vel.y, vel.x);
            float align_error = abs(angle_difference(orientation, vel_angle));
            alignment_cost += align_error * alignment_weight;
        }
        
        // Control smoothness (simplified for first version)
        control_cost += abs(rotation_rate) * 0.1;
    }
    
    // Final position cost (most important)
    vec2 final_predicted_target = target_pos + target_vel * (float(num_steps) * dt);
    vec2 final_error = final_predicted_target - pos;
    float final_dist_sq = dot(final_error, final_error);
    distance_cost += final_dist_sq * meters_per_pixel * meters_per_pixel * 10.0; // Weight final position more
    
    // Total cost
    total_cost = distance_cost + control_cost + alignment_cost;
    
    // Store result
    results.costs[tid] = total_cost;
    
    // Parallel reduction to find best template
    shared_costs[local_tid] = total_cost;
    shared_indices[local_tid] = tid;
    barrier();
    
    // Reduction
    for (uint stride = 16; stride > 0; stride >>= 1) {
        if (local_tid < stride && local_tid + stride < 32) {
            if (shared_costs[local_tid + stride] < shared_costs[local_tid]) {
                shared_costs[local_tid] = shared_costs[local_tid + stride];
                shared_indices[local_tid] = shared_indices[local_tid + stride];
            }
        }
        barrier();
    }
    
    // Thread 0 writes the result
    if (local_tid == 0) {
        results.best_index = shared_indices[0];
        results.best_cost = shared_costs[0];
        // Get the best template's first control
        vec4 best_template = templates.template_params[shared_indices[0]];
        
        // Recalculate first control for best template (simplified)
        vec2 init_to_target = target_pos - input_data.torpedo_state.xy;
        float init_angle = atan(init_to_target.y, init_to_target.x) + radians(best_template.z);
        float init_error = angle_difference(input_data.torpedo_orient.x, init_angle);
        
        results.best_control = vec4(
            max_accel * best_template.x,  // thrust
            clamp(init_error * best_template.y, -max_rotation, max_rotation),  // rotation
            0.0,
            0.0
        );
    }
}