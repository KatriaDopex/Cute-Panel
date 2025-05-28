/**
 * swarmTemplate.ts - CutePanel TypeScript Swarm Template
 *
 * This template provides a robust starting point for users to define and launch their own custom swarm objectives
 * and optimization tasks using the CutePanel TypeScript SDK.
 *
 * Features:
 * - Swarm objective registration and configuration
 * - Swarm algorithm selection and parameterization
 * - Real-time monitoring and analytics
 * - Error handling and extensibility
 *
 * For more info, see the CutePanel documentation: https://cute-panel.gitbook.io/cute-panel-documentation-hub/
 */

import { ApiClient } from '@cutepanel/core';

// === User: Configure your swarm objective ===
const swarmObjective = {
  name: 'MyCustomSwarmObjective',
  description: 'A user-defined swarm optimization objective for CutePanel',
  // Define your objective function parameters, constraints, etc.
  // For example, optimize a portfolio, solve a math problem, etc.
  parameters: {
    // Example: { "targetReturn": 0.1, "maxRisk": 0.05 }
  }
};

// === User: Configure your swarm algorithm and parameters ===
const swarmConfig = {
  algorithm: 'PSO', // Options: 'PSO', 'DE', 'GA', etc.
  numParticles: 30,
  maxIterations: 100,
  inertiaWeight: 0.7,
  cognitiveCoeff: 1.5,
  socialCoeff: 1.5,
  // Add more algorithm-specific parameters as needed
};

// === User: Define your swarm logic ===
async function runSwarm() {
  const client = new ApiClient();

  // Example: Register swarm objective
  const objectiveId = await client.swarms.createObjective(swarmObjective);

  // Example: Launch swarm optimization
  const swarmId = await client.swarms.launchSwarm({
    objectiveId,
    config: swarmConfig
  });

  // Example: Monitor swarm progress
  while (true) {
    try {
      const status = await client.swarms.getSwarmStatus(swarmId);
      console.log(`[Swarm] Status:`, status);
      if (status.status === 'COMPLETED' || status.status === 'ERROR' || status.status === 'STOPPED') {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 2000));
    } catch (err) {
      console.error('Swarm monitoring error:', err);
      break;
    }
  }

  // Example: Retrieve and display results
  try {
    const result = await client.swarms.getSwarmResult(swarmId);
    console.log(`[Swarm] Best solution found:`, result.bestSolution);
  } catch (err) {
    console.error('Swarm result retrieval error:', err);
  }
}

// === Start the swarm ===
runSwarm().catch((err) => {
  console.error('Swarm error:', err);
});
