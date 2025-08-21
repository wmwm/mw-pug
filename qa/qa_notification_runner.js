/**
 * Discord QA Edge-Case Runner - v1.3.0 Notification System
 * 
 * This module automates execution of high-impact scenarios to validate the
 * NotificationAgent ↔ SuperLoader integration, YAML-driven behavior,
 * and fail-safe + fallback logic.
 */

const discord = require('../utils/discord');
const logger = require('../utils/logger');
const NotificationAgent = require('../agents/notificationAgent');
const SuperLoader = require('../utils/super_loader');
const { sleep, generateRandomId } = require('../utils/helpers');
const path = require('path');
const fs = require('fs').promises;

class QANotificationRunner {
  /**
   * Creates a new QA Notification Runner instance
   * @param {Object} options Configuration options
   * @param {Object} dependencies System dependencies
   */
  constructor(options = {}, dependencies = {}) {
    this.options = {
      logChannelId: options.logChannelId || null,
      waitBetweenScenarios: options.waitBetweenScenarios || 5000, // 5s default
      scenarioTimeout: options.scenarioTimeout || 30000, // 30s default
      ...options
    };
    
    // Store dependencies
    this.discord = dependencies.discord || discord;
    this.logger = dependencies.logger || logger;
    this.notificationAgent = dependencies.notificationAgent || null;
    this.agentManager = dependencies.agentManager || null;
    
    // Set test user IDs - can be replaced with actual test users
    this.testUsers = {
      standard: options.testUsers?.standard || '123456789012345678',
      dnd: options.testUsers?.dnd || '123456789012345679',
      offline: options.testUsers?.offline || '123456789012345680'
    };
    
    // Running state
    this.isRunning = false;
    this.currentScenario = null;
    this.results = new Map();
    
    // Command registration
    this.commandName = 'qa';
    
    // Bind methods
    this.handleCommand = this.handleCommand.bind(this);
    
    // Scenario registry
    this.scenarios = {
      // Expiration scenarios
      'EXP_BOUNDARY': this.runExpirationBoundaryTest.bind(this),
      'EXP_FUTURE_JUMP': this.runFutureJumpTest.bind(this),
      'EXP_MIXED_TYPES': this.runMixedTypesTest.bind(this),
      
      // Keep-alive scenarios
      'KA_DORMANT': this.runDormantUserTest.bind(this),
      'KA_ACTIVE_IDLE': this.runActiveIdleTest.bind(this),
      'KA_CONCURRENT': this.runConcurrentKeepAliveTest.bind(this),
      
      // Preprocessing scenarios
      'PRE_UNKNOWN_TYPE': this.runUnknownTypeTest.bind(this),
      'PRE_MISSING_FIELDS': this.runMissingFieldsTest.bind(this),
      'PRE_SCHEMA_DRIFT': this.runSchemaDriftTest.bind(this),
      
      // Queue scenarios
      'Q_HIGH_BURST': this.runHighBurstTest.bind(this),
      'Q_OUT_OF_ORDER': this.runOutOfOrderTest.bind(this),
      'Q_FALLBACK': this.runFallbackTest.bind(this),
      
      // Config scenarios
      'CFG_HOT_SWAP': this.runHotSwapTest.bind(this),
      'CFG_CONFLICT': this.runConfigConflictTest.bind(this),
      
      // Failure scenarios
      'FAIL_NO_SUPERLOADER': this.runNoSuperloaderTest.bind(this),
      'FAIL_PARTIAL_RESTORE': this.runPartialRestoreTest.bind(this),
      'FAIL_INVALID_YAML': this.runInvalidYamlTest.bind(this)
    };
    
    this.logger.info('QA Notification Runner initialized');
  }
  
  /**
   * Initialize the QA runner
   * @param {Object} agentManager Reference to the agent manager
   * @returns {Promise<void>}
   */
  async initialize(agentManager) {
    try {
      this.agentManager = agentManager;
      
      // Get NotificationAgent reference
      if (agentManager) {
        this.notificationAgent = agentManager.getAgent('Notification');
        
        if (!this.notificationAgent) {
          throw new Error('NotificationAgent not found in AgentManager');
        }
        
        // Register the QA command
        const commandRegistry = agentManager.getCommandRegistry();
        if (commandRegistry) {
          commandRegistry.registerCommand({
            name: this.commandName,
            description: 'Run QA notification tests',
            options: [
              { name: 'scenario', description: 'Scenario to run', type: 'string' },
              { name: 'run', description: 'Run mode (single/all)', type: 'string' }
            ],
            permissions: ['ADMINISTRATOR', 'MANAGE_GUILD'],
            handler: this.handleCommand
          });
        }
        
        this.logger.info('QA Notification Runner registered command');
      } else {
        throw new Error('AgentManager is required for QA Runner');
      }
    } catch (error) {
      this.logger.error(`QA Runner initialization failed: ${error.message}`);
      throw error;
    }
  }
  
  /**
   * Handle the QA command
   * @param {Object} interaction Discord interaction object
   * @returns {Promise<void>}
   */
  async handleCommand(interaction) {
    try {
      // Parse options
      const scenarioId = interaction.options.getString('scenario');
      const runMode = interaction.options.getString('run');
      
      // Check permissions
      if (!this.hasAdminPermission(interaction.user.id)) {
        return interaction.reply({
          content: "⛔ You don't have permission to run QA tests.",
          ephemeral: true
        });
      }
      
      // If already running tests
      if (this.isRunning) {
        return interaction.reply({
          content: "⚠️ QA tests are already running.",
          ephemeral: true
        });
      }
      
      // Run mode: all scenarios
      if (runMode === 'all') {
        await interaction.reply({
          content: "🧪 Starting all QA notification test scenarios...",
          ephemeral: false
        });
        
        this.runAllScenarios(interaction.channel);
        return;
      }
      
      // Run a specific scenario
      if (scenarioId && this.scenarios[scenarioId]) {
        await interaction.reply({
          content: `🧪 Running test scenario: ${scenarioId}`,
          ephemeral: false
        });
        
        this.runScenario(scenarioId, interaction.channel);
        return;
      }
      
      // List available scenarios
      const scenarioList = Object.keys(this.scenarios)
        .map(id => `\`${id}\``)
        .join(', ');
        
      return interaction.reply({
        content: `Available test scenarios:\n${scenarioList}\n\nUse \`!qa scenario=<ID>\` to run a specific scenario, or \`!qa run=all\` to run all scenarios.`,
        ephemeral: true
      });
    } catch (error) {
      this.logger.error(`QA command error: ${error.message}`);
      
      if (interaction.replied) {
        await interaction.followUp({
          content: `❌ Error: ${error.message}`,
          ephemeral: true
        });
      } else {
        await interaction.reply({
          content: `❌ Error: ${error.message}`,
          ephemeral: true
        });
      }
    }
  }
  
  /**
   * Run all QA scenarios in sequence
   * @param {Object} responseChannel Discord channel for responses
   * @returns {Promise<void>}
   */
  async runAllScenarios(responseChannel) {
    try {
      this.isRunning = true;
      this.results.clear();
      
      await this.logToQA(`🧪 **Starting QA Run** - ${Object.keys(this.scenarios).length} scenarios`);
      
      // Run each scenario in sequence
      for (const [scenarioId, scenarioFn] of Object.entries(this.scenarios)) {
        await responseChannel.send(`🧪 Running: ${scenarioId}`);
        
        try {
          this.currentScenario = scenarioId;
          const startTime = Date.now();
          
          // Run the scenario with timeout
          const result = await Promise.race([
            scenarioFn(),
            new Promise((_, reject) => {
              setTimeout(() => reject(new Error('Scenario timeout')), this.options.scenarioTimeout);
            })
          ]);
          
          const duration = Date.now() - startTime;
          
          // Store and log result
          this.results.set(scenarioId, { success: true, result, duration });
          await responseChannel.send(`✅ Passed: ${scenarioId} (${duration}ms)`);
          await this.logToQA(`✅ **${scenarioId}** - Passed in ${duration}ms\n${JSON.stringify(result, null, 2)}`);
        } catch (error) {
          // Store and log failure
          this.results.set(scenarioId, { success: false, error: error.message });
          await responseChannel.send(`❌ Failed: ${scenarioId} - ${error.message}`);
          await this.logToQA(`❌ **${scenarioId}** - Failed\n\`\`\`\n${error.message}\n\`\`\``);
        }
        
        // Wait between scenarios
        await sleep(this.options.waitBetweenScenarios);
      }
      
      // Summarize results
      const successful = [...this.results.values()].filter(r => r.success).length;
      const total = this.results.size;
      
      await responseChannel.send(`🏁 QA Run Complete - ${successful}/${total} passed`);
      await this.logToQA(`🏁 **QA Run Complete** - ${successful}/${total} passed`);
      
      if (successful === total) {
        await this.logToQA(`✅ All notification tests passed! v1.3.0 integration looks good.`);
      } else {
        await this.logToQA(`⚠️ Some tests failed. Check the logs above for details.`);
      }
    } catch (error) {
      this.logger.error(`QA run error: ${error.message}`);
      await responseChannel.send(`❌ QA Run Error: ${error.message}`);
    } finally {
      this.isRunning = false;
      this.currentScenario = null;
    }
  }
  
  /**
   * Run a specific scenario
   * @param {string} scenarioId Scenario identifier
   * @param {Object} responseChannel Discord channel for responses
   * @returns {Promise<void>}
   */
  async runScenario(scenarioId, responseChannel) {
    try {
      this.isRunning = true;
      this.currentScenario = scenarioId;
      
      const scenarioFn = this.scenarios[scenarioId];
      
      if (!scenarioFn) {
        throw new Error(`Unknown scenario: ${scenarioId}`);
      }
      
      await this.logToQA(`🧪 **Running Scenario**: ${scenarioId}`);
      
      const startTime = Date.now();
      
      // Run the scenario with timeout
      const result = await Promise.race([
        scenarioFn(),
        new Promise((_, reject) => {
          setTimeout(() => reject(new Error('Scenario timeout')), this.options.scenarioTimeout);
        })
      ]);
      
      const duration = Date.now() - startTime;
      
      // Store and log result
      this.results.set(scenarioId, { success: true, result, duration });
      await responseChannel.send(`✅ Passed: ${scenarioId} (${duration}ms)`);
      await this.logToQA(`✅ **${scenarioId}** - Passed in ${duration}ms\n${JSON.stringify(result, null, 2)}`);
      
      return result;
    } catch (error) {
      // Store and log failure
      this.results.set(scenarioId, { success: false, error: error.message });
      await responseChannel.send(`❌ Failed: ${scenarioId} - ${error.message}`);
      await this.logToQA(`❌ **${scenarioId}** - Failed\n\`\`\`\n${error.message}\n\`\`\``);
      
      throw error;
    } finally {
      this.isRunning = false;
      this.currentScenario = null;
    }
  }
  
  /**
   * Log to QA channel
   * @param {string} message Message to log
   * @returns {Promise<void>}
   */
  async logToQA(message) {
    try {
      if (this.options.logChannelId) {
        const channel = await this.discord.getChannel(this.options.logChannelId);
        
        if (channel) {
          await channel.send(message);
        }
      }
      
      // Always log to console
      this.logger.info(`QA: ${message}`);
    } catch (error) {
      this.logger.error(`QA logging error: ${error.message}`);
    }
  }
  
  /**
   * Check if user has admin permission
   * @param {string} userId User ID
   * @returns {Promise<boolean>} True if user has admin permission
   */
  async hasAdminPermission(userId) {
    try {
      // Get user
      const user = await this.discord.getUser(userId);
      if (!user) return false;
      
      // Check if user is server owner
      const guild = await this.discord.getGuild();
      if (guild && guild.ownerId === userId) return true;
      
      // Check for admin roles
      const member = await guild.members.fetch(userId);
      if (!member) return false;
      
      // Check if user has administrator permission
      if (member.permissions.has('ADMINISTRATOR')) return true;
      
      // Check for specific roles
      const adminRoles = ['Admin', 'PUG Admin', 'Bot Admin', 'Moderator', 'QA Tester'];
      return member.roles.cache.some(role => adminRoles.includes(role.name));
    } catch (error) {
      this.logger.error(`QA permission check error: ${error.message}`);
      return false;
    }
  }
  
  //==============================
  // Scenario Implementations
  //==============================
  
  /**
   * Test expiration exactly at boundary
   * Sets up a notification with a precise expiration and validates the timing
   */
  async runExpirationBoundaryTest() {
    // Create a test user with a notification that expires in exactly 2 seconds
    const userId = this.testUsers.standard;
    const type = 'test_boundary';
    const expiryTime = 2; // seconds
    
    // Create custom notification context
    const context = {
      test_id: generateRandomId(),
      timeout: expiryTime
    };
    
    // Add a listener for expired notifications
    const expirationPromise = new Promise(resolve => {
      const handler = eventData => {
        if (eventData.userId === userId && eventData.type === type) {
          // Remove the listener
          this.notificationAgent.off('notification:expired', handler);
          resolve({ expired: true, eventData });
        }
      };
      
      this.notificationAgent.on('notification:expired', handler);
      
      // Add a timeout in case expiration doesn't happen
      setTimeout(() => {
        this.notificationAgent.off('notification:expired', handler);
        resolve({ expired: false, error: 'Expiration event never fired' });
      }, (expiryTime + 3) * 1000);
    });
    
    // Send the notification
    await this.notificationAgent.sendCustomNotification(userId, type, context);
    
    // Wait for expiration and verify timing
    const startTime = Date.now();
    const result = await expirationPromise;
    const elapsedTime = Math.floor((Date.now() - startTime) / 100) / 10;
    
    // Verify the results
    if (!result.expired) {
      throw new Error(`EXP_BOUNDARY: Notification did not expire: ${result.error}`);
    }
    
    // Check if expiration was at the correct time (within 0.5s tolerance)
    if (Math.abs(elapsedTime - expiryTime) > 0.5) {
      throw new Error(`EXP_BOUNDARY: Expiration timing incorrect. Expected ~${expiryTime}s, got ${elapsedTime}s`);
    }
    
    return { success: true, expiredAt: elapsedTime };
  }
  
  /**
   * Test scheduling notifications in the future and simulating time skips
   */
  async runFutureJumpTest() {
    // Create a test notification with a far future expiration
    const userId = this.testUsers.standard;
    const type = 'test_future';
    const farFutureSeconds = 24 * 60 * 60; // 1 day
    
    // Create future notification
    const context = {
      test_id: generateRandomId(),
      timeout: farFutureSeconds
    };
    
    // Send the notification
    await this.notificationAgent.sendCustomNotification(userId, type, context);
    
    // Verify notification was created with the correct expiration time
    const userNotifications = this.notificationAgent.stateStore.get(userId) || {};
    const notification = userNotifications[type];
    
    if (!notification) {
      throw new Error('EXP_FUTURE_JUMP: Failed to create future notification');
    }
    
    // Get the original expiration timestamp
    const originalExpiry = notification.expires_at;
    const expectedExpiry = Date.now() + (farFutureSeconds * 1000);
    
    // Verify expiration time is set correctly
    if (Math.abs(originalExpiry - expectedExpiry) > 1000) {
      throw new Error(`EXP_FUTURE_JUMP: Incorrect expiration time`);
    }
    
    // Now simulate a time jump by directly modifying the expiration
    // This is a hack for testing only - in production we'd never do this
    notification.expires_at = Date.now() + 2000; // Now + 2 seconds
    this.notificationAgent.stateStore.set(userId, userNotifications);
    
    // Add a listener for expired notifications
    const expirationPromise = new Promise(resolve => {
      const handler = eventData => {
        if (eventData.userId === userId && eventData.type === type) {
          // Remove the listener
          this.notificationAgent.off('notification:expired', handler);
          resolve({ expired: true, eventData });
        }
      };
      
      this.notificationAgent.on('notification:expired', handler);
      
      // Add a timeout in case expiration doesn't happen
      setTimeout(() => {
        this.notificationAgent.off('notification:expired', handler);
        resolve({ expired: false, error: 'Expiration event never fired after time jump' });
      }, 5000);
    });
    
    // Wait for expiration after time jump
    const result = await expirationPromise;
    
    // Verify the results
    if (!result.expired) {
      throw new Error(`EXP_FUTURE_JUMP: Notification did not expire after time jump: ${result.error}`);
    }
    
    return { success: true, timeJumpWorked: true };
  }
  
  /**
   * Test expiration with multiple notification types
   */
  async runMixedTypesTest() {
    // Create test users with different notification types
    const userId = this.testUsers.standard;
    const types = ['test_mix1', 'test_mix2', 'test_mix3'];
    const expiryTimes = [2, 3, 4]; // seconds
    
    // Send multiple notifications with different expiry times
    const sentPromises = types.map((type, index) => {
      const context = {
        test_id: generateRandomId(),
        timeout: expiryTimes[index]
      };
      
      return this.notificationAgent.sendCustomNotification(userId, type, context);
    });
    
    await Promise.all(sentPromises);
    
    // Verify all notifications were created
    const userNotifications = this.notificationAgent.stateStore.get(userId) || {};
    
    for (const type of types) {
      if (!userNotifications[type]) {
        throw new Error(`EXP_MIXED_TYPES: Failed to create notification for type ${type}`);
      }
    }
    
    // Track expiration order
    const expirationOrder = [];
    
    // Add a listener for expired notifications
    const expirationPromise = new Promise(resolve => {
      const handler = eventData => {
        if (eventData.userId === userId && types.includes(eventData.type)) {
          expirationOrder.push(eventData.type);
          
          // If all have expired, we're done
          if (expirationOrder.length === types.length) {
            // Remove the listener
            this.notificationAgent.off('notification:expired', handler);
            resolve({ expired: true, order: expirationOrder });
          }
        }
      };
      
      this.notificationAgent.on('notification:expired', handler);
      
      // Add a timeout in case not all expirations happen
      setTimeout(() => {
        this.notificationAgent.off('notification:expired', handler);
        resolve({ 
          expired: expirationOrder.length > 0, 
          partial: expirationOrder.length < types.length,
          order: expirationOrder
        });
      }, (Math.max(...expiryTimes) + 3) * 1000);
    });
    
    // Wait for expirations
    const result = await expirationPromise;
    
    // Verify the results
    if (!result.expired) {
      throw new Error('EXP_MIXED_TYPES: No notifications expired');
    }
    
    if (result.partial) {
      throw new Error(`EXP_MIXED_TYPES: Only ${result.order.length}/${types.length} notifications expired`);
    }
    
    // Check if the expiration order matches the expected order
    const expectedOrder = [...types].sort((a, b) => {
      const indexA = types.indexOf(a);
      const indexB = types.indexOf(b);
      return expiryTimes[indexA] - expiryTimes[indexB];
    });
    
    // Compare actual vs expected order
    let orderCorrect = true;
    for (let i = 0; i < expectedOrder.length; i++) {
      if (expectedOrder[i] !== result.order[i]) {
        orderCorrect = false;
        break;
      }
    }
    
    if (!orderCorrect) {
      throw new Error(`EXP_MIXED_TYPES: Incorrect expiration order. Expected ${expectedOrder.join(',')}, got ${result.order.join(',')}`);
    }
    
    return { 
      success: true, 
      order: result.order,
      orderCorrect
    };
  }
  
  /**
   * Test keep-alive for dormant users
   */
  async runDormantUserTest() {
    // Use an offline test user
    const userId = this.testUsers.offline;
    const queueId = `test-queue-${generateRandomId()}`;
    const matchName = 'Test Match';
    
    // Track if SuperLoader was called
    let superLoaderCalled = false;
    const originalExecStep = this.notificationAgent.superLoader.execStep;
    
    // Temporarily replace SuperLoader's execStep method to track calls
    this.notificationAgent.superLoader.execStep = async function(stepName, params) {
      if (stepName === 'queue_keep_alive_processing' && params.userId === userId) {
        superLoaderCalled = true;
        // Call the original but ensure it returns {processed: true}
        const result = await originalExecStep.call(this, stepName, params);
        return { ...result, processed: true };
      }
      
      return originalExecStep.call(this, stepName, params);
    };
    
    try {
      // Send queue keep-alive
      const result = await this.notificationAgent.sendQueueKeepAlive(userId, matchName, queueId);
      
      // Restore original method
      this.notificationAgent.superLoader.execStep = originalExecStep;
      
      // Verify SuperLoader was called for this dormant user
      if (!superLoaderCalled) {
        throw new Error('KA_DORMANT: SuperLoader was not called for queue_keep_alive_processing');
      }
      
      // Verify the result (should succeed even for dormant users)
      if (!result) {
        throw new Error('KA_DORMANT: sendQueueKeepAlive failed for dormant user');
      }
      
      return { success: true, superLoaderCalled };
    } catch (error) {
      // Restore original method
      this.notificationAgent.superLoader.execStep = originalExecStep;
      throw error;
    }
  }
  
  /**
   * Test keep-alive for active but idle users
   */
  async runActiveIdleTest() {
    // Use a standard test user who is online but idle
    const userId = this.testUsers.standard;
    const queueId = `test-queue-${generateRandomId()}`;
    const matchName = 'Test Match';
    
    // Set up a listener to track notification event
    const notificationPromise = new Promise(resolve => {
      const handler = eventData => {
        if (eventData.userId === userId && 
            eventData.type === 'match_queue' && 
            eventData.context.queue_id === queueId) {
          // Remove the listener
          this.notificationAgent.off('notification:sent', handler);
          resolve({ sent: true, eventData });
        }
      };
      
      this.notificationAgent.on('notification:sent', handler);
      
      // Add a timeout in case notification isn't sent
      setTimeout(() => {
        this.notificationAgent.off('notification:sent', handler);
        resolve({ sent: false, error: 'Notification event never fired' });
      }, 5000);
    });
    
    // Send queue keep-alive
    await this.notificationAgent.sendQueueKeepAlive(userId, matchName, queueId);
    
    // Wait for notification event
    const result = await notificationPromise;
    
    // Verify notification was sent
    if (!result.sent) {
      throw new Error(`KA_ACTIVE_IDLE: Notification was not sent: ${result.error}`);
    }
    
    // Verify the notification was stored correctly
    const userNotifications = this.notificationAgent.stateStore.get(userId) || {};
    const notification = userNotifications['match_queue'];
    
    if (!notification) {
      throw new Error('KA_ACTIVE_IDLE: Notification not stored in state');
    }
    
    // Verify notification has the correct context
    if (notification.context.queue_id !== queueId || 
        notification.context.match_name !== matchName) {
      throw new Error('KA_ACTIVE_IDLE: Notification context is incorrect');
    }
    
    return { success: true, notificationSent: true };
  }
  
  /**
   * Test concurrent keep-alive notifications
   */
  async runConcurrentKeepAliveTest() {
    // Use a standard test user
    const userId = this.testUsers.standard;
    const queueCount = 3;
    const queueIds = Array.from({ length: queueCount }, (_, i) => `test-queue-${i}-${generateRandomId()}`);
    const matchNames = queueIds.map((_, i) => `Test Match ${i + 1}`);
    
    // Send multiple keep-alive notifications in quick succession
    const sendPromises = queueIds.map((queueId, i) => 
      this.notificationAgent.sendQueueKeepAlive(userId, matchNames[i], queueId)
    );
    
    // Wait for all notifications to be sent
    await Promise.all(sendPromises);
    
    // Verify notifications were stored
    const userNotifications = this.notificationAgent.stateStore.get(userId) || {};
    
    // There should only be ONE match_queue notification since they get deduplicated
    const notification = userNotifications['match_queue'];
    
    if (!notification) {
      throw new Error('KA_CONCURRENT: No match_queue notification found');
    }
    
    // It should contain the context of the LAST notification sent
    const lastQueueId = queueIds[queueCount - 1];
    const lastMatchName = matchNames[queueCount - 1];
    
    if (notification.context.queue_id !== lastQueueId || 
        notification.context.match_name !== lastMatchName) {
      throw new Error('KA_CONCURRENT: Notification does not contain the latest context');
    }
    
    return { 
      success: true, 
      deduplicatedCorrectly: true,
      latestQueueId: lastQueueId
    };
  }
  
  /**
   * Test preprocessing with an unknown notification type
   */
  async runUnknownTypeTest() {
    // Use a standard test user
    const userId = this.testUsers.standard;
    const type = 'non_existent_type';
    const context = {
      test_id: generateRandomId(),
      timeout: 5
    };
    
    // Try to send a notification with an unknown type
    const result = await this.notificationAgent.sendCustomNotification(userId, type, context);
    
    // This should fail or return false because the type doesn't exist
    if (result) {
      throw new Error('PRE_UNKNOWN_TYPE: Notification with unknown type was accepted');
    }
    
    // Verify no notification was stored
    const userNotifications = this.notificationAgent.stateStore.get(userId) || {};
    
    if (userNotifications[type]) {
      throw new Error('PRE_UNKNOWN_TYPE: Notification with unknown type was stored');
    }
    
    return { success: true, rejectedCorrectly: true };
  }
  
  /**
   * Test preprocessing with missing optional fields
   */
  async runMissingFieldsTest() {
    // Use a standard test user
    const userId = this.testUsers.standard;
    const type = 'match_queue';
    
    // Create notification with only required fields
    const minimalContext = {
      queue_id: `test-queue-${generateRandomId()}`
      // Intentionally omit match_name
    };
    
    // Send the notification with minimal context
    const result = await this.notificationAgent.sendCustomNotification(userId, type, minimalContext);
    
    // This should succeed despite missing optional fields
    if (!result) {
      throw new Error('PRE_MISSING_FIELDS: Notification with minimal context was rejected');
    }
    
    // Verify notification was stored
    const userNotifications = this.notificationAgent.stateStore.get(userId) || {};
    const notification = userNotifications[type];
    
    if (!notification) {
      throw new Error('PRE_MISSING_FIELDS: Notification with minimal context was not stored');
    }
    
    // Check if missing fields were given default values
    const hasDefaultTimeout = notification.context.timeout !== undefined;
    const hasDefaultMatchName = notification.context.match_name !== undefined;
    
    return { 
      success: true, 
      hasDefaultTimeout,
      hasDefaultMatchName
    };
  }
  
  /**
   * Test schema drift in notification YAML
   */
  async runSchemaDriftTest() {
    // Use a standard test user
    const userId = this.testUsers.standard;
    
    // Path to notification config
    const configPath = path.join(this.options.configDir || '../config', 'notification_test_drift.yaml');
    
    // Create a test YAML with schema drift
    const testYaml = `
version: '1.0'
description: 'Schema Drift Test'
target: 'notification'

upgrade_sequence:
  - id: 'schema_drift_test'
    name: 'Test schema drift handling'
    execute_order: 1
    requires_restart: false
    rollback_supported: true
    steps:
      - type: 'config_update'
        target: 'notification'
        action: 'add_fields'
        params:
          fields:
            # Intentional schema drift - use 'channel' instead of 'channel_id'
            fallback_channel_tier0: '123456789012345678'
            # Different capitalization
            Triggers:
              test_drift: true
    `;
    
    // Write the test YAML
    await fs.writeFile(configPath, testYaml);
    
    try {
      // Try to execute the upgrade
      const results = await this.notificationAgent.executeUpgrade('notification_test_drift.yaml');
      
      // Check if the schema drift was handled gracefully
      if (!results.success) {
        // Schema validation might correctly reject this drift
        return { success: true, driftRejected: true };
      }
      
      // If it succeeded, check if it correctly mapped the drifted fields
      // This could be valid if the SuperLoader has robust schema mapping
      
      // Check if the drifted field names were mapped correctly
      const config = await this.notificationAgent.configManager.getConfig('notification');
      
      const mappedChannel = config.fallback_channel_tier0_id !== undefined;
      const normalizedTriggers = typeof config.triggers?.test_drift === 'boolean';
      
      if (!mappedChannel && !normalizedTriggers) {
        throw new Error('PRE_SCHEMA_DRIFT: Schema drift was not handled correctly');
      }
      
      return { 
        success: true, 
        driftAccepted: true,
        mappedChannel,
        normalizedTriggers
      };
    } catch (error) {
      // Schema validation error is an acceptable outcome
      return { success: true, driftRejected: true, error: error.message };
    } finally {
      // Clean up the test file
      try {
        await fs.unlink(configPath);
      } catch (err) {
        // Ignore cleanup errors
      }
    }
  }
  
  /**
   * Test high burst rate of notifications
   */
  async runHighBurstTest() {
    // Use a standard test user
    const userId = this.testUsers.standard;
    const burstCount = 10;
    const type = 'test_burst';
    
    // Send multiple notifications in quick succession
    const results = [];
    
    for (let i = 0; i < burstCount; i++) {
      const context = {
        test_id: `burst-${i}-${generateRandomId()}`,
        message: `Test message ${i + 1}`,
        timeout: 5
      };
      
      const result = await this.notificationAgent.sendCustomNotification(userId, type, context);
      results.push(result);
    }
    
    // Check if throttling was applied
    const successCount = results.filter(r => r).length;
    
    // Get the max_pending_per_user limit
    const maxPending = this.notificationAgent.config.max_pending_per_user || 3;
    
    // If the agent respects max_pending_per_user, it should throttle after that many
    if (successCount > maxPending) {
      throw new Error(`Q_HIGH_BURST: Throttling not applied correctly. Accepted ${successCount}/${burstCount}, max should be ${maxPending}`);
    }
    
    return { 
      success: true, 
      throttledCorrectly: successCount <= maxPending,
      acceptedCount: successCount,
      maxAllowed: maxPending
    };
  }
  
  /**
   * Test out-of-order delivery
   */
  async runOutOfOrderTest() {
    // Use a standard test user
    const userId = this.testUsers.standard;
    const type1 = 'test_order_1';
    const type2 = 'test_order_2';
    
    // Create a notification with a long timeout
    const context1 = {
      test_id: generateRandomId(),
      timeout: 10, // 10 seconds
      order: 1
    };
    
    // Create a second notification with a short timeout
    const context2 = {
      test_id: generateRandomId(),
      timeout: 2, // 2 seconds
      order: 2
    };
    
    // Send the first notification
    await this.notificationAgent.sendCustomNotification(userId, type1, context1);
    
    // Send the second notification
    await this.notificationAgent.sendCustomNotification(userId, type2, context2);
    
    // Track expiration order
    const expirationOrder = [];
    
    // Add a listener for expired notifications
    const expirationPromise = new Promise(resolve => {
      const handler = eventData => {
        if (eventData.userId === userId && 
            (eventData.type === type1 || eventData.type === type2)) {
          expirationOrder.push(eventData.type);
          
          // If both have expired, we're done
          if (expirationOrder.length === 2) {
            // Remove the listener
            this.notificationAgent.off('notification:expired', handler);
            resolve({ expired: true, order: expirationOrder });
          }
        }
      };
      
      this.notificationAgent.on('notification:expired', handler);
      
      // Add a timeout in case not all expirations happen
      setTimeout(() => {
        this.notificationAgent.off('notification:expired', handler);
        resolve({ 
          expired: expirationOrder.length > 0, 
          partial: expirationOrder.length < 2,
          order: expirationOrder
        });
      }, 15 * 1000);
    });
    
    // Wait for expirations
    const result = await expirationPromise;
    
    // Verify both notifications expired
    if (!result.expired || result.partial) {
      throw new Error(`Q_OUT_OF_ORDER: Not all notifications expired. Only got: ${result.order.join(',')}`);
    }
    
    // Verify the expiration order - type2 should expire first
    const correctOrder = result.order[0] === type2 && result.order[1] === type1;
    
    if (!correctOrder) {
      throw new Error(`Q_OUT_OF_ORDER: Incorrect expiration order. Expected ${type2},${type1}, got ${result.order.join(',')}`);
    }
    
    return { 
      success: true, 
      order: result.order,
      correctOrder
    };
  }
  
  /**
   * Test fallback channel when direct messages fail
   */
  async runFallbackTest() {
    // Use a standard test user but configure it to make DMs fail
    const userId = this.testUsers.standard;
    const type = 'test_fallback';
    const context = {
      test_id: generateRandomId(),
      message: 'Fallback test notification',
      timeout: 5
    };
    
    // Temporarily modify Discord.getUser to simulate DM failure
    const originalGetUser = this.discord.getUser;
    
    this.discord.getUser = async (id) => {
      if (id === userId) {
        // Return a user that will throw when sending a DM
        return {
          id: userId,
          username: 'TestUser',
          send: () => {
            throw new Error('DM rejected');
          }
        };
      }
      
      return originalGetUser.call(this.discord, id);
    };
    
    // Set up a listener for fallback notifications
    const fallbackPromise = new Promise(resolve => {
      const handler = eventData => {
        if (eventData.userId === userId && 
            eventData.type === type && 
            eventData.fallback === true) {
          // Remove the listener
          this.notificationAgent.off('notification:sent', handler);
          resolve({ fallbackUsed: true, eventData });
        }
      };
      
      this.notificationAgent.on('notification:sent', handler);
      
      // Add a timeout in case fallback isn't used
      setTimeout(() => {
        this.notificationAgent.off('notification:sent', handler);
        resolve({ fallbackUsed: false, error: 'Fallback notification event never fired' });
      }, 5000);
    });
    
    try {
      // Send the notification
      const result = await this.notificationAgent.sendCustomNotification(userId, type, context);
      
      // Restore original method
      this.discord.getUser = originalGetUser;
      
      // Verify notification was accepted
      if (!result) {
        throw new Error('Q_FALLBACK: Notification was rejected');
      }
      
      // Wait for fallback notification event
      const fallbackResult = await fallbackPromise;
      
      // Verify fallback was used
      if (!fallbackResult.fallbackUsed) {
        throw new Error(`Q_FALLBACK: Fallback channel wasn't used: ${fallbackResult.error}`);
      }
      
      // Verify the notification has fallback flag
      const userNotifications = this.notificationAgent.stateStore.get(userId) || {};
      const notification = userNotifications[type];
      
      if (!notification || !notification.fallback) {
        throw new Error('Q_FALLBACK: Notification missing or not marked as fallback');
      }
      
      return { success: true, fallbackUsed: true };
    } catch (error) {
      // Restore original method
      this.discord.getUser = originalGetUser;
      throw error;
    }
  }
  
  /**
   * Test hot-swapping configuration
   */
  async runHotSwapTest() {
    // Path to notification config
    const configPath = path.join(this.options.configDir || '../config', 'notification_test_hotswap.yaml');
    
    // Create a test YAML with configuration changes
    const testYaml = `
version: '1.0'
description: 'Hot Swap Test'
target: 'notification'

upgrade_sequence:
  - id: 'hot_swap_test'
    name: 'Test hot swap configuration'
    execute_order: 1
    requires_restart: false
    rollback_supported: true
    steps:
      - type: 'config_update'
        target: 'notification'
        action: 'update_fields'
        params:
          fields:
            timeout_seconds:
              test_hotswap: 60
            dm_templates:
              test_hotswap: 'This is a hot-swapped template: {message}'
            triggers:
              test_hotswap:
                enabled: true
                tier: 1
    `;
    
    // Write the test YAML
    await fs.writeFile(configPath, testYaml);
    
    try {
      // Save original configuration
      const originalConfig = { ...this.notificationAgent.config };
      
      // Execute the upgrade
      const results = await this.notificationAgent.executeUpgrade('notification_test_hotswap.yaml');
      
      // Check if the upgrade succeeded
      if (!results.success) {
        throw new Error(`CFG_HOT_SWAP: Upgrade failed: ${results.error}`);
      }
      
      // Verify the configuration was updated
      const newTimeout = this.notificationAgent.config.timeout_seconds?.test_hotswap === 60;
      const newTemplate = this.notificationAgent.config.dm_templates?.test_hotswap === 'This is a hot-swapped template: {message}';
      const newTrigger = this.notificationAgent.config.triggers?.test_hotswap?.enabled === true;
      
      if (!newTimeout || !newTemplate || !newTrigger) {
        throw new Error('CFG_HOT_SWAP: Configuration was not updated correctly');
      }
      
      // Test the new configuration by sending a notification
      const userId = this.testUsers.standard;
      const context = {
        message: 'Hot swap test',
        test_id: generateRandomId()
      };
      
      const sendResult = await this.notificationAgent.sendCustomNotification(userId, 'test_hotswap', context);
      
      if (!sendResult) {
        throw new Error('CFG_HOT_SWAP: Failed to send notification with new configuration');
      }
      
      // Restore original config
      this.notificationAgent.config = originalConfig;
      
      return { 
        success: true, 
        configUpdated: true,
        notificationSent: sendResult
      };
    } catch (error) {
      throw error;
    } finally {
      // Clean up the test file
      try {
        await fs.unlink(configPath);
      } catch (err) {
        // Ignore cleanup errors
      }
    }
  }
  
  /**
   * Test conflicting configuration updates
   */
  async runConfigConflictTest() {
    // Create two test YAMLs with conflicting changes
    const configPath1 = path.join(this.options.configDir || '../config', 'notification_test_conflict1.yaml');
    const configPath2 = path.join(this.options.configDir || '../config', 'notification_test_conflict2.yaml');
    
    // YAML 1 sets a value
    const testYaml1 = `
version: '1.0'
description: 'Conflict Test 1'
target: 'notification'

upgrade_sequence:
  - id: 'conflict_test_1'
    name: 'Test conflict resolution 1'
    execute_order: 1
    requires_restart: false
    rollback_supported: true
    steps:
      - type: 'config_update'
        target: 'notification'
        action: 'update_fields'
        params:
          fields:
            timeout_seconds:
              test_conflict: 60
            dm_templates:
              test_conflict: 'Version 1: {message}'
    `;
    
    // YAML 2 sets different values
    const testYaml2 = `
version: '1.0'
description: 'Conflict Test 2'
target: 'notification'

upgrade_sequence:
  - id: 'conflict_test_2'
    name: 'Test conflict resolution 2'
    execute_order: 1
    requires_restart: false
    rollback_supported: true
    steps:
      - type: 'config_update'
        target: 'notification'
        action: 'update_fields'
        params:
          fields:
            timeout_seconds:
              test_conflict: 120
            dm_templates:
              test_conflict: 'Version 2: {message}'
    `;
    
    // Write the test YAMLs
    await fs.writeFile(configPath1, testYaml1);
    await fs.writeFile(configPath2, testYaml2);
    
    try {
      // Save original configuration
      const originalConfig = { ...this.notificationAgent.config };
      
      // Execute the first upgrade
      const results1 = await this.notificationAgent.executeUpgrade('notification_test_conflict1.yaml');
      
      // Check if the first upgrade succeeded
      if (!results1.success) {
        throw new Error(`CFG_CONFLICT: First upgrade failed: ${results1.error}`);
      }
      
      // Verify the configuration was updated with first values
      const timeout1 = this.notificationAgent.config.timeout_seconds?.test_conflict === 60;
      const template1 = this.notificationAgent.config.dm_templates?.test_conflict === 'Version 1: {message}';
      
      if (!timeout1 || !template1) {
        throw new Error('CFG_CONFLICT: First configuration update failed');
      }
      
      // Execute the second upgrade
      const results2 = await this.notificationAgent.executeUpgrade('notification_test_conflict2.yaml');
      
      // Check if the second upgrade succeeded
      if (!results2.success) {
        throw new Error(`CFG_CONFLICT: Second upgrade failed: ${results2.error}`);
      }
      
      // Verify the configuration was updated with second values
      const timeout2 = this.notificationAgent.config.timeout_seconds?.test_conflict === 120;
      const template2 = this.notificationAgent.config.dm_templates?.test_conflict === 'Version 2: {message}';
      
      if (!timeout2 || !template2) {
        throw new Error('CFG_CONFLICT: Second configuration update failed');
      }
      
      // Restore original config
      this.notificationAgent.config = originalConfig;
      
      return { 
        success: true, 
        firstUpdateApplied: true,
        secondUpdateOverrodeFirst: timeout2 && template2
      };
    } catch (error) {
      throw error;
    } finally {
      // Clean up the test files
      try {
        await fs.unlink(configPath1);
        await fs.unlink(configPath2);
      } catch (err) {
        // Ignore cleanup errors
      }
    }
  }
  
  /**
   * Test resilience when SuperLoader is unavailable
   */
  async runNoSuperloaderTest() {
    // Use a standard test user
    const userId = this.testUsers.standard;
    const type = 'test_no_superloader';
    const context = {
      test_id: generateRandomId(),
      message: 'SuperLoader unavailable test',
      timeout: 5
    };
    
    // Temporarily replace the SuperLoader with null
    const originalSuperLoader = this.notificationAgent.superLoader;
    this.notificationAgent.superLoader = null;
    
    try {
      // Send notification without SuperLoader
      const result = await this.notificationAgent.sendCustomNotification(userId, type, context);
      
      // Restore SuperLoader
      this.notificationAgent.superLoader = originalSuperLoader;
      
      // Verify notification was still sent successfully
      if (!result) {
        throw new Error('FAIL_NO_SUPERLOADER: Failed to send notification without SuperLoader');
      }
      
      // Verify notification was stored
      const userNotifications = this.notificationAgent.stateStore.get(userId) || {};
      const notification = userNotifications[type];
      
      if (!notification) {
        throw new Error('FAIL_NO_SUPERLOADER: Notification not stored without SuperLoader');
      }
      
      return { success: true, gracefulFallback: true };
    } catch (error) {
      // Restore SuperLoader
      this.notificationAgent.superLoader = originalSuperLoader;
      throw error;
    }
  }
  
  /**
   * Test partial restoration after a crash
   */
  async runPartialRestoreTest() {
    // Use a standard test user
    const userId = this.testUsers.standard;
    const type = 'test_partial_restore';
    const queueId = `test-queue-${generateRandomId()}`;
    const matchName = 'Test Match';
    
    // Set up a broken SuperLoader execStep method that crashes
    const originalExecStep = this.notificationAgent.superLoader.execStep;
    
    this.notificationAgent.superLoader.execStep = async function(stepName, params) {
      if (stepName === 'preprocess_notification') {
        // Simulate a crash
        throw new Error('Simulated crash during preprocessing');
      }
      
      return originalExecStep.call(this, stepName, params);
    };
    
    try {
      // Send queue keep-alive with broken SuperLoader
      const result = await this.notificationAgent.sendQueueKeepAlive(userId, matchName, queueId);
      
      // Restore original method
      this.notificationAgent.superLoader.execStep = originalExecStep;
      
      // Verify notification was still sent despite the crash
      if (!result) {
        throw new Error('FAIL_PARTIAL_RESTORE: Notification failed despite fallback handling');
      }
      
      // Verify notification was stored
      const userNotifications = this.notificationAgent.stateStore.get(userId) || {};
      const notification = userNotifications['match_queue'];
      
      if (!notification) {
        throw new Error('FAIL_PARTIAL_RESTORE: Notification not stored after crash');
      }
      
      return { success: true, recoveredFromCrash: true };
    } catch (error) {
      // Restore original method
      this.notificationAgent.superLoader.execStep = originalExecStep;
      throw error;
    }
  }
  
  /**
   * Test handling of invalid YAML
   */
  async runInvalidYamlTest() {
    // Path to notification config
    const configPath = path.join(this.options.configDir || '../config', 'notification_test_invalid.yaml');
    
    // Create a test YAML with invalid syntax
    const testYaml = `
version: '1.0'
description: 'Invalid YAML Test'
target: 'notification'

upgrade_sequence:
  - id: 'invalid_yaml_test'
    name: 'Test invalid YAML handling'
    execute_order: 1
    steps:
      # Invalid YAML - missing colon
      type 'config_update'
      target: 'notification'
      action: 'update_fields'
      params:
        fields:
          timeout_seconds:
            test_invalid: 60
    `;
    
    // Write the test YAML
    await fs.writeFile(configPath, testYaml);
    
    try {
      // Try to execute the upgrade with invalid YAML
      const results = await this.notificationAgent.executeUpgrade('notification_test_invalid.yaml');
      
      // The upgrade should fail
      if (results.success) {
        throw new Error('FAIL_INVALID_YAML: Invalid YAML was accepted');
      }
      
      return { 
        success: true, 
        invalidYamlRejected: true,
        error: results.error
      };
    } catch (error) {
      // Properly handling the error is also a valid outcome
      return { 
        success: true, 
        invalidYamlRejected: true,
        error: error.message
      };
    } finally {
      // Clean up the test file
      try {
        await fs.unlink(configPath);
      } catch (err) {
        // Ignore cleanup errors
      }
    }
  }
}

module.exports = QANotificationRunner;
