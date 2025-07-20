#version 450

// Workgroup layout: x = torpedo index, y = template index
layout(local_size_x = 1, local_size_y = 32, local_size_z = 1) in;

// Input: Multiple torpedoes and their targets
layout(set = 0, binding = 0, std430) restrict readonly buffer TorpedoStates {
    vec4 states[];  // For each torpedo: [x, y, vx, vy] then [orientation, angular_vel, max_accel, max_rotation]
} torpedo_states;

layout(set = 0, binding = 1, std430) restrict readonly buffer TargetStates {
    vec4 states[];  // For each target: [x, y, vx, vy]
} target_states;

layout(set = 0, binding = 2, std430) restrict readonly buffer SimParams {
    vec4 params;    // dt, num_steps, meters_per_pixel, num_torpedoes
} sim_params;

// Input: Shared template bank
layout(set = 0, binding = 3, std430) restrict readonly buffer Templates {
    vec4 template_params[];  // Templates shared by all torpedoes
} templates;

// Output: Best control for each torpedo
layout(set = 0, binding = 4, std430) restrict writeonly buffer Results {
    vec4 best_controls[];    // For each torpedo: [thrust, rotation_rate, best_cost, best_template_idx]
} results;

// Shared memory for reduction within workgroup
shared float shared_costs[32];
shared uint shared_indices[32];

// Helper functions (same as before)
float angle_difference(float from, float to) {
    float diff = to - from;
    const float TAU = 6.28318530718;
    const float PI = 3.14159265359;
    
    while (diff > PI) diff -= TAU;
    while (diff < -PI) diff += TAU;
    
    return diff;
}

void main() {
    uint torpedo_id = gl_WorkGroupID.x;
    uint template_id = gl_LocalInvocationID.y;
    uint num_torpedoes = uint(sim_params.params.w);
    uint num_templates = uint(templates.template_params.length());
    
    // Bounds check
    if (torpedo_id >= num_torpedoes || template_id >= num_templates) return;
    
    // Get this torpedo's state (2 vec4s per torpedo)
    uint torpedo_offset = torpedo_id * 2;
    vec4 torpedo_pos_vel = torpedo_states.states[torpedo_offset];
    vec4 torpedo_orient = torpedo_states.states[torpedo_offset + 1];
    
    // Get target state (assuming one target per torpedo for now)
    vec4 target_pos_vel = target_states.states[torpedo_id];
    
    // Get template
    vec4 template = templates.template_params[template_id];
    float thrust_factor = template.x;
    float rotation_gain = template.y;
    float initial_angle_offset = template.z;
    float alignment_weight = template.w;
    
    // Extract state
    vec2 pos = torpedo_pos_vel.xy;
    vec2 vel = torpedo_pos_vel.zw;
    float orientation = torpedo_orient.x;
    float angular_vel = torpedo_orient.y;
    float max_accel = torpedo_orient.z;
    float max_rotation = torpedo_orient.w;
    
    vec2 target_pos = target_pos_vel.xy;
    vec2 target_vel = target_pos_vel.zw;
    
    // Sim parameters
    float dt = sim_params.params.x;
    uint num_steps = uint(sim_params.params.y);
    float meters_per_pixel = sim_params.params.z;
    
    // Initialize costs
    float total_cost = 0.0;
    float distance_cost = 0.0;
    float control_cost = 0.0;
    float alignment_cost = 0.0;
    
    // Initial angle setup
    vec2 to_target = target_pos - pos;
    float base_angle = atan(to_target.y, to_target.x);
    float desired_angle = base_angle + radians(initial_angle_offset);
    
    // Store first control
    float first_thrust = 0.0;
    float first_rotation = 0.0;
    
    // Simulate trajectory
    for (uint i = 0; i < num_steps; i++) {
        // Predict target position
        vec2 predicted_target = target_pos + target_vel * (float(i) * dt);
        
        // Calculate control
        vec2 to_predicted = predicted_target - pos;
        float target_angle = atan(to_predicted.y, to_predicted.x);
        
        if (i > num_steps / 10) {
            desired_angle = target_angle;
        }
        
        float angle_error = angle_difference(orientation, desired_angle);
        float rotation_rate = clamp(angle_error * rotation_gain, -max_rotation, max_rotation);
        
        float alignment = abs(angle_error);
        float thrust = max_accel * thrust_factor * (1.0 - min(alignment / 3.14159, 0.5));
        
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
        
        if (length(vel) > 10.0) {
            float vel_angle = atan(vel.y, vel.x);
            float align_error = abs(angle_difference(orientation, vel_angle));
            alignment_cost += align_error * alignment_weight;
        }
        
        control_cost += abs(rotation_rate) * 0.1;
    }
    
    // Final position cost
    vec2 final_predicted_target = target_pos + target_vel * (float(num_steps) * dt);
    vec2 final_error = final_predicted_target - pos;
    float final_dist_sq = dot(final_error, final_error);
    distance_cost += final_dist_sq * meters_per_pixel * meters_per_pixel * 10.0;
    
    total_cost = distance_cost + control_cost + alignment_cost;
    
    // Store in shared memory for reduction
    shared_costs[template_id] = total_cost;
    shared_indices[template_id] = template_id;
    barrier();
    
    // Parallel reduction to find best template for this torpedo
    for (uint stride = 16; stride > 0; stride >>= 1) {
        if (template_id < stride && template_id + stride < 32) {
            if (shared_costs[template_id + stride] < shared_costs[template_id]) {
                shared_costs[template_id] = shared_costs[template_id + stride];
                shared_indices[template_id] = shared_indices[template_id + stride];
            }
        }
        barrier();
    }
    
    // Thread 0 writes result for this torpedo
    if (template_id == 0) {
        // Get best template
        uint best_idx = shared_indices[0];
        vec4 best_template = templates.template_params[best_idx];
        
        // Recalculate first control for best template
        vec2 init_to_target = target_pos_vel.xy - torpedo_pos_vel.xy;
        float init_angle = atan(init_to_target.y, init_to_target.x) + radians(best_template.z);
        float init_error = angle_difference(torpedo_orient.x, init_angle);
        
        results.best_controls[torpedo_id] = vec4(
            max_accel * best_template.x,  // thrust
            clamp(init_error * best_template.y, -max_rotation, max_rotation),  // rotation
            shared_costs[0],  // best cost
            float(best_idx)   // best template index
        );
    }
}