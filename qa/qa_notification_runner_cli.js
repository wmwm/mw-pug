/**
 * QA Notification Runner CLI
 * 
 * This script allows running the QA notification tests from the command line.
 * Usage: node qa_notification_runner_cli.js [scenario_id]
 * 
 * If no scenario ID is provided, all tests will be run.
 */

const QANotificationRunner = require('./qa_notification_runner');
const NotificationAgent = require('../agents/notificationAgent');
const SuperLoader = require('../utils/super_loader');
const discord = require('../utils/discord');
const logger = require('../utils/logger');
const configManager = require('../utils/config_manager');
const fs = require('fs').promises;
const path = require('path');
const yaml = require('js-yaml');

// Mock agent manager for testing
class MockAgentManager {
  constructor() {
    this.agents = new Map();
    this.commands = new Map();
  }
  
  getAgent(name) {
    return this.agents.get(name);
  }
  
  registerAgent(name, agent) {
    this.agents.set(name, agent);
  }
  
  getCommandRegistry() {
    return {
      registerCommand: (command) => {
        this.commands.set(command.name, command);
        logger.info(`Registered command: ${command.name}`);
      }
    };
  }
  
  emit(event, data) {
    logger.info(`Event emitted: ${event}`);
    console.log(data);
  }
}

// Load QA test configuration
async function loadQAConfig() {
  try {
    const configPath = path.join(__dirname, '../config/qa_notification_test.yaml');
    const fileContent = await fs.readFile(configPath, 'utf8');
    return yaml.load(fileContent);
  } catch (error) {
    console.error(`Failed to load QA config: ${error.message}`);
    process.exit(1);
  }
}

// Setup mock dependencies
async function setupMockDependencies(qaConfig) {
  // Mock discord
  const mockDiscord = {
    getUser: async (id) => {
      const user = {
        id,
        username: `TestUser_${id}`,
        send: async (message) => {
          logger.info(`Sent DM to ${id}: ${message}`);
          return { id: `msg_${Date.now()}` };
        },
        presence: {
          status: id === qaConfig.test_users.dnd ? 'dnd' : 
                  id === qaConfig.test_users.offline ? 'offline' : 'online'
        }
      };
      return user;
    },
    getChannel: async (id) => {
      return {
        id,
        name: `test-channel-${id}`,
        send: async (message) => {
          logger.info(`Sent message to channel ${id}: ${message}`);
          return { id: `msg_${Date.now()}` };
        }
      };
    },
    getGuild: async () => {
      return {
        id: 'test-guild',
        ownerId: qaConfig.test_users.standard,
        members: {
          fetch: async (id) => {
            return {
              id,
              permissions: {
                has: (perm) => true
              },
              roles: {
                cache: [
                  { name: 'Admin' },
                  { name: 'QA Tester' }
                ]
              }
            };
          }
        }
      };
    },
    on: (event, handler) => {
      logger.info(`Registered handler for Discord event: ${event}`);
    },
    off: (event, handler) => {
      logger.info(`Unregistered handler for Discord event: ${event}`);
    }
  };
  
  // Mock database
  const mockDatabase = {
    logEvent: async (category, eventType, userId, details) => {
      logger.info(`DB Log: ${category} - ${eventType} - ${userId}`);
    },
    getUserQueueHistory: async (userId, since) => {
      return { count: 15 }; // Simulate an active user
    },
    tableExists: async (name) => false,
    createTable: async (name, schema) => {},
  };
  
  // Mock config manager
  const mockConfigManager = {
    configPath: path.join(__dirname, '../config'),
    getConfig: async (name) => {
      if (name === 'notification') {
        return {
          enabled: true,
          triggers: {
            match_queue: { enabled: true, tier: 0 },
            pre_game: { enabled: true, tier: 0 },
            role_retention: { enabled: true, tier: 1 },
            test_boundary: { enabled: true, tier: 0 },
            test_future: { enabled: true, tier: 0 },
            test_mix1: { enabled: true, tier: 1 },
            test_mix2: { enabled: true, tier: 1 },
            test_mix3: { enabled: true, tier: 1 },
            test_burst: { enabled: true, tier: 2 },
            test_order_1: { enabled: true, tier: 1 },
            test_order_2: { enabled: true, tier: 1 },
            test_fallback: { enabled: true, tier: 0 },
            test_no_superloader: { enabled: true, tier: 1 },
            test_partial_restore: { enabled: true, tier: 1 },
            test_hotswap: { enabled: true, tier: 1 },
            announcements: { enabled: true, tier: 2 },
            tips: { enabled: true, tier: 2 }
          },
          timeout_seconds: {
            match_queue: 300,
            pre_game: 60,
            role_retention: 86400,
            test_boundary: 2,
            test_future: 86400,
            test_mix1: 2,
            test_mix2: 3,
            test_mix3: 4,
            test_burst: 5,
            test_order_1: 10,
            test_order_2: 2,
            test_fallback: 5,
            test_no_superloader: 5,
            test_partial_restore: 5,
            announcements: 0,
            tips: 0
          },
          dm_templates: {
            match_queue: '**Queue Keep-Alive** for {match_name} - Reply with `!ready` to stay in queue!',
            pre_game: '**Match Ready!** Your match is about to start. Reply with `!ready` to confirm.',
            role_retention: '**Role Retention** - Reply with `!active` to keep your {role_name} role.',
            test_boundary: 'Test boundary notification',
            test_future: 'Test future notification',
            test_mix1: 'Test mix notification 1',
            test_mix2: 'Test mix notification 2',
            test_mix3: 'Test mix notification 3',
            test_burst: 'Test burst notification {message}',
            test_order_1: 'Test order notification 1',
            test_order_2: 'Test order notification 2',
            test_fallback: 'Test fallback notification {message}',
            test_no_superloader: 'Test no superloader {message}',
            test_partial_restore: 'Test partial restore {message}',
            announcements: '{message}',
            tips: '{message}'
          },
          fallback_channel_id: 'fallback-channel',
          fallback_channel_tier0_id: 'tier0-fallback',
          fallback_channel_tier1_id: 'tier1-fallback',
          fallback_channel_tier2_id: 'tier2-fallback',
          log_channel_id: 'log-channel',
          audit_log: true,
          max_pending_per_user: 3
        };
      }
      return {};
    },
    updateConfig: async (name, fields) => {
      logger.info(`Updating ${name} config with: ${JSON.stringify(fields)}`);
    },
    transformSchema: async (target, fromVersion, toVersion, transforms) => {
      logger.info(`Transforming ${target} schema from ${fromVersion} to ${toVersion}`);
    },
    setConfig: async (name, config) => {
      logger.info(`Setting ${name} config`);
    }
  };
  
  return { 
    discord: mockDiscord, 
    database: mockDatabase, 
    configManager: mockConfigManager 
  };
}

// Initialize the notification agent and QA runner
async function initializeAgents(dependencies, qaConfig) {
  // Create notification agent
  const notificationAgent = new NotificationAgent({}, dependencies);
  
  // Create agent manager
  const agentManager = new MockAgentManager();
  agentManager.registerAgent('Notification', notificationAgent);
  
  // Initialize notification agent
  await notificationAgent.initialize(agentManager);
  
  // Create QA runner
  const qaRunner = new QANotificationRunner({
    logChannelId: qaConfig?.channels?.qa_logs,
    waitBetweenScenarios: 2000,
    scenarioTimeout: 10000,
    testUsers: qaConfig?.test_users,
    configDir: path.join(__dirname, '../config')
  }, {
    ...dependencies,
    notificationAgent,
    agentManager
  });
  
  // Initialize QA runner
  await qaRunner.initialize(agentManager);
  
  return { notificationAgent, qaRunner, agentManager };
}

// Run the specified scenario or all scenarios
async function runTests(qaRunner, scenarioId) {
  try {
    // Create a mock channel for responses
    const mockChannel = {
      send: async (message) => {
        console.log(`[Channel] ${message}`);
      }
    };
    
    if (scenarioId) {
      console.log(`Running scenario: ${scenarioId}`);
      await qaRunner.runScenario(scenarioId, mockChannel);
    } else {
      console.log('Running all scenarios');
      await qaRunner.runAllScenarios(mockChannel);
    }
  } catch (error) {
    console.error(`Test execution error: ${error.message}`);
    process.exit(1);
  }
}

// Main function
async function main() {
  try {
    // Get scenario ID from command line if provided
    const scenarioId = process.argv[2];
    
    // Load QA config
    console.log('Loading QA configuration...');
    const qaConfig = await loadQAConfig();
    
    // Setup mock dependencies
    console.log('Setting up test environment...');
    const dependencies = await setupMockDependencies(qaConfig.test_config);
    
    // Initialize agents
    console.log('Initializing agents...');
    const { notificationAgent, qaRunner } = await initializeAgents(dependencies, qaConfig.test_config);
    
    // Run tests
    console.log('Running tests...');
    await runTests(qaRunner, scenarioId);
    
    console.log('Tests completed!');
    process.exit(0);
  } catch (error) {
    console.error(`Fatal error: ${error.message}`);
    process.exit(1);
  }
}

// Run the main function
main();
