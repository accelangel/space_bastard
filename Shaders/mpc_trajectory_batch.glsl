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

// NEW: Flight plan data for each torpedo
layout(set = 0, binding = 4, std430) restrict readonly buffer FlightPlans {
    vec4 flight_plans[];  // For each torpedo: [type, side/angle, impact_time, reserved]
} flight_plans;

// Output: Best control for each torpedo
layout(set = 0, binding = 5, std430) restrict writeonly buffer Results {
    vec4 best_controls[];    // For each torpedo: [thrust, rotation_rate, best_cost, best_template_idx]
} results;

// Shared memory for reduction within workgroup
shared float shared_costs[32];
shared uint shared_indices[32];

// Constants for trajectory types
const uint TRAJECTORY_STRAIGHT = 0;
const uint TRAJECTORY_MULTI_ANGLE = 1;
const uint TRAJECTORY_SIMULTANEOUS = 2;

// Helper functions
float angle_difference(float from, float to) {
    float diff = to - from;
    const float TAU = 6.28318530718;
    const float PI = 3.14159265359;
    
    while (diff > PI) diff -= TAU;
    while (diff < -PI) diff += TAU;
    
    return diff;
}

// Calculate control based on trajectory type
vec2 calculate_trajectory_control(
    uint trajectory_type,
    vec2 pos,
    vec2 vel,
    float orientation,
    vec2 target_pos,
    vec2 target_vel,
    float progress,
    vec4 template_params,
    vec4 flight_plan
) {
    float thrust_factor = template_params.x;
    float rotation_gain = template_params.y;
    float initial_angle_offset = template_params.z;
    float alignment_weight = template_params.w;
    
    float desired_angle = 0.0;
    float thrust_modulation = 1.0;
    
    if (trajectory_type == TRAJECTORY_STRAIGHT) {
        // Simple direct intercept
        vec2 to_target = target_pos - pos;
        desired_angle = atan(to_target.y, to_target.x) + radians(initial_angle_offset);
        
        // After initial phase, track predicted position
        if (progress > 0.1) {
            desired_angle = atan(to_target.y, to_target.x);
        }
        
    } else if (trajectory_type == TRAJECTORY_MULTI_ANGLE) {
        // Arc approach from side
        float approach_side = flight_plan.y;  // -1 for port, 1 for starboard
        vec2 to_target = target_pos - pos;
        float direct_angle = atan(to_target.y, to_target.x);
        float perpendicular = direct_angle + (3.14159/2.0) * approach_side;
        
        // Arc phases from template
        float arc_start = 0.1;
        float arc_peak = 0.5;
        float final_approach = 0.8;
        
        if (progress < arc_start) {
            desired_angle = direct_angle + radians(initial_angle_offset);
        } else if (progress < arc_peak) {
            float arc_progress = (progress - arc_start) / (arc_peak - arc_start);
            desired_angle = mix(direct_angle, perpendicular, arc_progress * 0.4);
        } else if (progress < final_approach) {
            desired_angle = mix(direct_angle, perpendicular, 0.4);
        } else {
            float return_progress = (progress - final_approach) / (1.0 - final_approach);
            desired_angle = mix(perpendicular, direct_angle, return_progress);
        }
        
    } else if (trajectory_type == TRAJECTORY_SIMULTANEOUS) {
        // Fan out then converge
        float assigned_angle = flight_plan.y;  // Assigned approach angle
        vec2 to_target = target_pos - pos;
        float center_angle = atan(to_target.y, to_target.x);
        float fan_angle = center_angle + assigned_angle;
        
        // Phase transitions
        float fan_duration = 0.3;
        float converge_start = 0.7;
        
        if (progress < fan_duration) {
            float fan_progress = progress / fan_duration;
            desired_angle = mix(orientation, fan_angle, fan_progress);
            thrust_modulation = 0.8;
        } else if (progress < converge_start) {
            desired_angle = fan_angle;
            thrust_modulation = 0.9;
        } else {
            float converge_progress = (progress - converge_start) / (1.0 - converge_start);
            vec2 current_to_target = target_pos - pos;
            float target_angle = atan(current_to_target.y, current_to_target.x);
            desired_angle = mix(fan_angle, target_angle, converge_progress);
            thrust_modulation = 0.8 + 0.2 * converge_progress;
        }
    }
    
    // Calculate control outputs
    float angle_error = angle_difference(orientation, desired_angle);
    float rotation_rate = clamp(angle_error * rotation_gain, -3.14159, 3.14159);  // Assuming normalized max_rotation
    
    // Thrust based on alignment
    float alignment = abs(angle_error);
    float alignment_penalty = 1.0 - min(alignment / 3.14159, 0.5);
    float thrust = thrust_factor * thrust_modulation * alignment_penalty;
    
    return vec2(thrust, rotation_rate);
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
    
    // Get target state
    vec4 target_pos_vel = target_states.states[torpedo_id];
    
    // Get flight plan
    vec4 flight_plan = flight_plans.flight_plans[torpedo_id];
    uint trajectory_type = uint(flight_plan.x);
    
    // Get template
    vec4 template_params = templates.template_params[template_id];
    
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
    float type_specific_cost = 0.0;
    
    // Store first control
    float first_thrust = 0.0;
    float first_rotation = 0.0;
    
    // Simulate trajectory
    for (uint i = 0; i < num_steps; i++) {
        float progress = float(i) / float(num_steps);
        
        // Get control for this step based on trajectory type
        vec2 control = calculate_trajectory_control(
            trajectory_type,
            pos, vel, orientation,
            target_pos + target_vel * (float(i) * dt),
            target_vel,
            progress,
            template_params,
            flight_plan
        );
        
        float thrust = control.x * max_accel;
        float rotation_rate = control.y * max_rotation;
        
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
        vec2 to_predicted = (target_pos + target_vel * (float(i) * dt)) - pos;
        float dist_sq = dot(to_predicted, to_predicted);
        distance_cost += dist_sq * meters_per_pixel * meters_per_pixel;
        
        if (length(vel) > 10.0) {
            float vel_angle = atan(vel.y, vel.x);
            float align_error = abs(angle_difference(orientation, vel_angle));
            alignment_cost += align_error * template_params.w;
        }
        
        control_cost += abs(rotation_rate) * 0.1;
    }
    
    // Final position cost
    vec2 final_predicted_target = target_pos + target_vel * (float(num_steps) * dt);
    vec2 final_error = final_predicted_target - pos;
    float final_dist_sq = dot(final_error, final_error);
    distance_cost += final_dist_sq * meters_per_pixel * meters_per_pixel * 10.0;
    
    // Type-specific final costs
    if (trajectory_type == TRAJECTORY_MULTI_ANGLE) {
        // Check if we achieved good angle separation
        float final_velocity_angle = atan(vel.y, vel.x);
        float expected_perpendicular = flight_plan.y * 1.5708;  // ±90 degrees
        float angle_error = abs(angle_difference(final_velocity_angle, expected_perpendicular));
        type_specific_cost = angle_error * 100.0;
        
    } else if (trajectory_type == TRAJECTORY_SIMULTANEOUS) {
        // Check if we're on track for simultaneous impact
        float target_impact_time = flight_plan.z;
        float time_error = abs(float(num_steps) * dt - target_impact_time);
        type_specific_cost = time_error * 50.0;
    }
    
    total_cost = distance_cost + control_cost + alignment_cost + type_specific_cost;
    
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
        
        // Recalculate first control for best template using proper trajectory type
        vec2 init_control = calculate_trajectory_control(
            trajectory_type,
            torpedo_pos_vel.xy,
            torpedo_pos_vel.zw,
            torpedo_orient.x,
            target_pos_vel.xy,
            target_pos_vel.zw,
            0.0,  // progress = 0 for first control
            best_template,
            flight_plan
        );
        
        results.best_controls[torpedo_id] = vec4(
            init_control.x * max_accel,  // thrust
            init_control.y * max_rotation,  // rotation
            shared_costs[0],  // best cost
            float(best_idx)   // best template index
        );
    }
}