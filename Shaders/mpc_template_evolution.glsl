#version 450

// GPU Template Evolution for MPC System
// Evolves trajectory templates based on fitness scores

layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;

// Current template population
layout(set = 0, binding = 0, std430) restrict buffer TemplatePopulation {
    vec4 templates[];     // Each template: [thrust_factor, rotation_gain, angle_offset, alignment_weight]
} population;

// Fitness scores from recent trajectory evaluations
layout(set = 0, binding = 1, std430) restrict buffer FitnessData {
    vec4 fitness[];       // [fitness_score, success_rate, usage_count, age]
} fitness_data;

// Evolution parameters
layout(set = 0, binding = 2, std430) restrict readonly buffer EvolutionParams {
    vec4 params;          // [mutation_rate, crossover_rate, elite_ratio, tournament_size]
    vec4 constraints;     // [min_thrust, max_thrust, min_rotation, max_rotation]
} evolution;

// Random number generation
layout(set = 0, binding = 3, std430) restrict buffer RandomState {
    uint states[];        // PCG random states
} random_state;

// Shared memory for tournament selection
shared uint tournament_pool[32];
shared float tournament_fitness[32];

// PCG random number generator
uint pcg_hash(uint input) {
    uint state = input * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float random_float(inout uint state) {
    state = pcg_hash(state);
    return float(state) / 4294967295.0;
}

// Gaussian random using Box-Muller transform
float random_gaussian(inout uint rng_state, float mean, float stddev) {
    float u1 = random_float(rng_state);
    float u2 = random_float(rng_state);
    float z0 = sqrt(-2.0 * log(u1)) * cos(6.28318530718 * u2);
    return z0 * stddev + mean;
}

// Tournament selection - returns index of winner
uint tournament_select(uint tid, uint population_size) {
    uint tournament_size = uint(evolution.params.w);
    uint rng_state = random_state.states[tid];
    
    // Fill tournament pool
    for (uint i = 0; i < tournament_size; i++) {
        uint idx = uint(random_float(rng_state) * float(population_size));
        tournament_pool[tid % 32] = idx;
        tournament_fitness[tid % 32] = fitness_data.fitness[idx].x;
    }
    
    barrier();
    
    // Find winner (highest fitness)
    uint winner_idx = tournament_pool[tid % 32];
    float best_fitness = tournament_fitness[tid % 32];
    
    for (uint i = 1; i < tournament_size; i++) {
        uint idx = (tid % 32 + i) % tournament_size;
        if (tournament_fitness[idx] > best_fitness) {
            best_fitness = tournament_fitness[idx];
            winner_idx = tournament_pool[idx];
        }
    }
    
    random_state.states[tid] = rng_state;
    return winner_idx;
}

// Crossover between two templates
vec4 crossover(vec4 parent1, vec4 parent2, inout uint rng_state) {
    vec4 child;
    
    // Uniform crossover - each parameter has 50% chance from each parent
    child.x = random_float(rng_state) < 0.5 ? parent1.x : parent2.x;
    child.y = random_float(rng_state) < 0.5 ? parent1.y : parent2.y;
    child.z = random_float(rng_state) < 0.5 ? parent1.z : parent2.z;
    child.w = random_float(rng_state) < 0.5 ? parent1.w : parent2.w;
    
    return child;
}

// Mutate a template
vec4 mutate(vec4 template, inout uint rng_state) {
    float mutation_rate = evolution.params.x;
    vec4 mutated = template;
    
    // Mutate thrust factor
    if (random_float(rng_state) < mutation_rate) {
        mutated.x += random_gaussian(rng_state, 0.0, 0.05);
        mutated.x = clamp(mutated.x, evolution.constraints.x, evolution.constraints.y);
    }
    
    // Mutate rotation gain
    if (random_float(rng_state) < mutation_rate) {
        mutated.y += random_gaussian(rng_state, 0.0, 1.0);
        mutated.y = clamp(mutated.y, evolution.constraints.z, evolution.constraints.w);
    }
    
    // Mutate angle offset
    if (random_float(rng_state) < mutation_rate) {
        mutated.z += random_gaussian(rng_state, 0.0, 2.0);
        mutated.z = clamp(mutated.z, -15.0, 15.0);
    }
    
    // Mutate alignment weight
    if (random_float(rng_state) < mutation_rate) {
        mutated.w += random_gaussian(rng_state, 0.0, 0.1);
        mutated.w = clamp(mutated.w, 0.1, 2.0);
    }
    
    return mutated;
}

void main() {
    uint tid = gl_GlobalInvocationID.x;
    uint population_size = uint(population.templates.length());
    
    if (tid >= population_size) return;
    
    // Get RNG state
    uint rng_state = random_state.states[tid];
    
    // Check if this template is in the elite set
    float elite_ratio = evolution.params.z;
    uint elite_count = uint(float(population_size) * elite_ratio);
    
    // Sort index based on fitness (simplified - assumes pre-sorted)
    bool is_elite = tid < elite_count;
    
    if (!is_elite) {
        // Non-elite templates undergo evolution
        
        // Tournament selection for parents
        uint parent1_idx = tournament_select(tid, population_size);
        uint parent2_idx = tournament_select(tid + 32, population_size);
        
        vec4 parent1 = population.templates[parent1_idx];
        vec4 parent2 = population.templates[parent2_idx];
        
        // Crossover
        vec4 child = crossover(parent1, parent2, rng_state);
        
        // Mutation
        child = mutate(child, rng_state);
        
        // Replace current template with evolved child
        population.templates[tid] = child;
        
        // Reset fitness for new template
        fitness_data.fitness[tid] = vec4(0.0, 0.0, 0.0, 0.0);
    } else {
        // Elite templates are preserved but age is incremented
        fitness_data.fitness[tid].w += 1.0;
        
        // Optional: Add small mutations to old elite templates
        if (fitness_data.fitness[tid].w > 100.0) {
            population.templates[tid] = mutate(population.templates[tid], rng_state);
            fitness_data.fitness[tid].w = 0.0;
        }
    }
    
    // Update random state
    random_state.states[tid] = rng_state;
}