/**
 * Super Loader
 * 
 * A utility for executing YAML-driven upgrade steps for the PugBot system.
 * This loader handles schema migrations, configuration updates, and other
 * automated deployment tasks defined in YAML configuration files.
 */

const fs = require('fs').promises;
const path = require('path');
const yaml = require('js-yaml');
const { EventEmitter } = require('events');
const logger = require('../utils/logger');
const discord = require('../utils/discord');
const database = require('../utils/database');

class SuperLoader extends EventEmitter {
  /**
   * Creates a new SuperLoader instance
   * @param {Object} options Configuration options
   * @param {string} options.configPath Path to the directory containing loader YAML files
   * @param {Object} options.dependencies Dependencies injected into the loader
   * @param {boolean} options.dryRun If true, simulates execution without making actual changes
   */
  constructor(options = {}) {
    super();
    this.configPath = options.configPath || path.join(__dirname, '../config');
    this.dependencies = options.dependencies || {};
    this.dryRun = options.dryRun || false;
    
    this.resourceCache = {
      channels: new Map(),
      roles: new Map(),
      configValues: new Map()
    };
    
    // Registry of step handlers
    this.handlers = {
      schema_update: this.handleSchemaUpdate.bind(this),
      data_migration: this.handleDataMigration.bind(this),
      discord_resources: this.handleDiscordResources.bind(this),
      config_update: this.handleConfigUpdate.bind(this),
      command_registry: this.handleCommandRegistry.bind(this),
      agent_binding: this.handleAgentBinding.bind(this),
      database_schema: this.handleDatabaseSchema.bind(this),
      preprocess_notification: this.handlePreprocessNotification.bind(this),
      check_expirations: this.handleCheckExpirations.bind(this),
      queue_keep_alive_processing: this.handleQueueKeepAliveProcessing.bind(this)
    };
    
    // Rollback registry
    this.rollbackSteps = [];
    
    logger.info('SuperLoader initialized');
  }
  
  /**
   * Loads and parses a YAML configuration file
   * @param {string} filename The name of the YAML file to load
   * @returns {Promise<Object>} The parsed YAML configuration
   */
  async loadConfig(filename) {
    try {
      const filePath = path.join(this.configPath, filename);
      const fileContent = await fs.readFile(filePath, 'utf8');
      const config = yaml.load(fileContent);
      
      logger.info(`Loaded configuration from ${filename}`);
      return config;
    } catch (error) {
      logger.error(`Failed to load configuration from ${filename}: ${error.message}`);
      throw error;
    }
  }
  
  /**
   * Executes an upgrade sequence from a YAML configuration
   * @param {string} filename The name of the YAML file containing the upgrade sequence
   * @returns {Promise<Object>} Results of the upgrade
   */
  async executeUpgrade(filename) {
    try {
      const config = await this.loadConfig(filename);
      
      logger.info(`Executing upgrade sequence: ${config.description}`);
      this.emit('upgrade:start', { config });
      
      // Sort upgrade steps by execute_order
      const orderedSteps = [...config.upgrade_sequence].sort(
        (a, b) => a.execute_order - b.execute_order
      );
      
      const results = [];
      let requiresRestart = false;
      
      // Execute each step in order
      for (const step of orderedSteps) {
        logger.info(`Executing step ${step.id}: ${step.name}`);
        this.emit('step:start', { step });
        
        const stepResult = await this.executeStep(step);
        requiresRestart = requiresRestart || step.requires_restart;
        
        results.push({
          id: step.id,
          name: step.name,
          success: stepResult.success,
          details: stepResult.details
        });
        
        this.emit('step:complete', { step, result: stepResult });
        
        // If a step fails, stop the execution
        if (!stepResult.success) {
          logger.error(`Step ${step.id} failed: ${stepResult.error}`);
          
          // Attempt rollback if supported
          if (step.rollback_supported) {
            await this.executeRollback();
          }
          
          this.emit('upgrade:error', { step, error: stepResult.error });
          throw new Error(`Upgrade failed at step ${step.id}: ${stepResult.error}`);
        }
      }
      
      this.emit('upgrade:complete', { results, requiresRestart });
      logger.info('Upgrade sequence completed successfully');
      
      return {
        success: true,
        results,
        requiresRestart
      };
    } catch (error) {
      logger.error(`Upgrade failed: ${error.message}`);
      return {
        success: false,
        error: error.message
      };
    }
  }
  
  /**
   * Executes a single upgrade step
   * @param {Object} step The step configuration
   * @returns {Promise<Object>} Result of the step execution
   */
  async executeStep(step) {
    try {
      const results = [];
      
      // Execute each sub-step
      for (const subStep of step.steps) {
        const handler = this.handlers[subStep.type];
        
        if (!handler) {
          throw new Error(`Unknown step type: ${subStep.type}`);
        }
        
        logger.debug(`Executing sub-step: ${subStep.type} - ${subStep.action}`);
        
        // If this is a dry run, don't actually execute the step
        if (this.dryRun) {
          logger.info(`[DRY RUN] Would execute ${subStep.type}:${subStep.action}`);
          results.push({ success: true, dryRun: true });
          continue;
        }
        
        const result = await handler(subStep);
        
        // If the step supports rollback, register a rollback step
        if (step.rollback_supported && result.rollback) {
          this.rollbackSteps.unshift(result.rollback);
        }
        
        results.push(result);
      }
      
      return {
        success: true,
        details: results
      };
    } catch (error) {
      logger.error(`Step execution error: ${error.message}`);
      return {
        success: false,
        error: error.message
      };
    }
  }
  
  /**
   * Executes rollback steps in reverse order
   * @returns {Promise<void>}
   */
  async executeRollback() {
    logger.warn('Executing rollback steps');
    this.emit('rollback:start');
    
    for (const rollbackStep of this.rollbackSteps) {
      try {
        logger.debug(`Executing rollback: ${rollbackStep.description}`);
        await rollbackStep.execute();
      } catch (error) {
        logger.error(`Rollback step failed: ${error.message}`);
      }
    }
    
    this.emit('rollback:complete');
    this.rollbackSteps = [];
  }
  
  /**
   * Validates if dependencies are available
   * @param {string[]} requiredDeps List of required dependency names
   * @returns {boolean} True if all dependencies are available
   */
  validateDependencies(requiredDeps) {
    for (const dep of requiredDeps) {
      if (!this.dependencies[dep]) {
        logger.error(`Missing required dependency: ${dep}`);
        return false;
      }
    }
    return true;
  }
  
  /**
   * Resolves template variables in configuration values
   * @param {string} value The template string to resolve
   * @returns {string} The resolved value
   */
  resolveTemplateValues(value) {
    if (typeof value !== 'string') return value;
    
    return value.replace(/\{([^}]+)\}/g, (match, key) => {
      const [type, id] = key.split(':');
      
      switch (type) {
        case 'channel':
          return this.resourceCache.channels.get(id) || match;
        case 'role':
          return this.resourceCache.roles.get(id) || match;
        case 'config':
          return this.resourceCache.configValues.get(id) || match;
        default:
          return match;
      }
    });
  }
  
  //==============================
  // Step Handlers
  //==============================
  
  /**
   * Handles schema_update steps
   * @param {Object} step Step configuration
   * @returns {Promise<Object>} Step result
   */
  async handleSchemaUpdate(step) {
    if (!this.validateDependencies(['configManager'])) {
      return { success: false, error: 'Missing configManager dependency' };
    }
    
    const { configManager } = this.dependencies;
    const { target, action, params } = step;
    
    try {
      switch (action) {
        case 'transform':
          await configManager.transformSchema(target, params.from_version, params.to_version, params.transforms);
          break;
        default:
          throw new Error(`Unknown action: ${action}`);
      }
      
      return {
        success: true,
        rollback: {
          description: `Revert schema from ${params.to_version} to ${params.from_version}`,
          execute: async () => {
            await configManager.revertSchema(target, params.to_version, params.from_version);
          }
        }
      };
    } catch (error) {
      return { success: false, error: error.message };
    }
  }
  
  /**
   * Handles data_migration steps
   * @param {Object} step Step configuration
   * @returns {Promise<Object>} Step result
   */
  async handleDataMigration(step) {
    if (!this.validateDependencies(['database'])) {
      return { success: false, error: 'Missing database dependency' };
    }
    
    const { database } = this.dependencies;
    const { target, action, params } = step;
    
    try {
      switch (action) {
        case 'add_field':
          await database.addField(target, params.field_name, params.default_value);
          break;
        case 'transform_data':
          await database.transformData(target, params.transform_function);
          break;
        default:
          throw new Error(`Unknown action: ${action}`);
      }
      
      return {
        success: true,
        rollback: {
          description: `Revert data migration on ${target}`,
          execute: async () => {
            if (action === 'add_field') {
              await database.removeField(target, params.field_name);
            } else if (action === 'transform_data' && params.revert_function) {
              await database.transformData(target, params.revert_function);
            }
          }
        }
      };
    } catch (error) {
      return { success: false, error: error.message };
    }
  }
  
  /**
   * Handles discord_resources steps
   * @param {Object} step Step configuration
   * @returns {Promise<Object>} Step result
   */
  async handleDiscordResources(step) {
    if (!this.validateDependencies(['discord'])) {
      return { success: false, error: 'Missing discord dependency' };
    }
    
    const { discord } = this.dependencies;
    const { target, action, params } = step;
    
    try {
      switch (target) {
        case 'channels':
          if (action === 'ensure_exists') {
            const createdChannels = [];
            
            for (const channelConfig of params.channels) {
              const channel = await discord.ensureChannel(channelConfig);
              
              if (channelConfig.store_id_as) {
                this.resourceCache.channels.set(channelConfig.store_id_as, channel.id);
              }
              
              createdChannels.push({
                name: channel.name,
                id: channel.id,
                store_id_as: channelConfig.store_id_as
              });
            }
            
            return {
              success: true,
              resources: createdChannels,
              rollback: {
                description: `Remove created channels`,
                execute: async () => {
                  for (const channel of createdChannels) {
                    if (channel.store_id_as) {
                      this.resourceCache.channels.delete(channel.store_id_as);
                    }
                    await discord.deleteChannel(channel.id);
                  }
                }
              }
            };
          }
          break;
          
        case 'roles':
          if (action === 'ensure_exists') {
            const createdRoles = [];
            
            for (const roleConfig of params.roles) {
              const role = await discord.ensureRole(roleConfig);
              
              if (roleConfig.store_id_as) {
                this.resourceCache.roles.set(roleConfig.store_id_as, role.id);
              }
              
              createdRoles.push({
                name: role.name,
                id: role.id,
                store_id_as: roleConfig.store_id_as
              });
            }
            
            return {
              success: true,
              resources: createdRoles,
              rollback: {
                description: `Remove created roles`,
                execute: async () => {
                  for (const role of createdRoles) {
                    if (role.store_id_as) {
                      this.resourceCache.roles.delete(role.store_id_as);
                    }
                    await discord.deleteRole(role.id);
                  }
                }
              }
            };
          }
          break;
          
        default:
          throw new Error(`Unknown target: ${target}`);
      }
      
      throw new Error(`Unknown action: ${action} for target: ${target}`);
    } catch (error) {
      return { success: false, error: error.message };
    }
  }
  
  /**
   * Handles config_update steps
   * @param {Object} step Step configuration
   * @returns {Promise<Object>} Step result
   */
  async handleConfigUpdate(step) {
    if (!this.validateDependencies(['configManager'])) {
      return { success: false, error: 'Missing configManager dependency' };
    }
    
    const { configManager } = this.dependencies;
    const { target, action, params } = step;
    
    try {
      const oldConfig = await configManager.getConfig(target);
      
      switch (action) {
        case 'add_fields':
          const resolvedFields = {};
          
          // Resolve template values
          for (const [key, value] of Object.entries(params.fields)) {
            resolvedFields[key] = this.resolveTemplateValues(value);
            
            if (params.store_as && key in params.store_as) {
              this.resourceCache.configValues.set(params.store_as[key], resolvedFields[key]);
            }
          }
          
          await configManager.updateConfig(target, resolvedFields);
          break;
          
        case 'update_fields':
          const resolvedUpdates = {};
          
          // Resolve template values
          for (const [key, value] of Object.entries(params.fields)) {
            resolvedUpdates[key] = this.resolveTemplateValues(value);
          }
          
          await configManager.updateConfig(target, resolvedUpdates);
          break;
          
        case 'remove_fields':
          await configManager.removeFields(target, params.fields);
          break;
          
        default:
          throw new Error(`Unknown action: ${action}`);
      }
      
      return {
        success: true,
        rollback: {
          description: `Revert config changes to ${target}`,
          execute: async () => {
            await configManager.setConfig(target, oldConfig);
          }
        }
      };
    } catch (error) {
      return { success: false, error: error.message };
    }
  }
  
  /**
   * Handles command_registry steps
   * @param {Object} step Step configuration
   * @returns {Promise<Object>} Step result
   */
  async handleCommandRegistry(step) {
    if (!this.validateDependencies(['commandRegistry'])) {
      return { success: false, error: 'Missing commandRegistry dependency' };
    }
    
    const { commandRegistry } = this.dependencies;
    const { target, action, params } = step;
    
    try {
      const registeredCommands = [];
      
      switch (action) {
        case 'register':
          for (const command of params.commands) {
            await commandRegistry.registerCommand(command);
            registeredCommands.push(command.name);
          }
          break;
          
        case 'unregister':
          for (const commandName of params.commands) {
            await commandRegistry.unregisterCommand(commandName);
          }
          break;
          
        default:
          throw new Error(`Unknown action: ${action}`);
      }
      
      return {
        success: true,
        commands: registeredCommands,
        rollback: action === 'register' ? {
          description: `Unregister commands`,
          execute: async () => {
            for (const commandName of registeredCommands) {
              await commandRegistry.unregisterCommand(commandName);
            }
          }
        } : null
      };
    } catch (error) {
      return { success: false, error: error.message };
    }
  }
  
  /**
   * Handles agent_binding steps
   * @param {Object} step Step configuration
   * @returns {Promise<Object>} Step result
   */
  async handleAgentBinding(step) {
    if (!this.validateDependencies(['agentManager'])) {
      return { success: false, error: 'Missing agentManager dependency' };
    }
    
    const { agentManager } = this.dependencies;
    const { target, action, params } = step;
    
    try {
      const bindings = [];
      
      switch (target) {
        case 'event_bus':
          if (action === 'subscribe') {
            for (const event of params.events) {
              await agentManager.subscribeToEvent(
                params.source_agent, 
                event.event, 
                event.handler
              );
              
              bindings.push({
                source: params.source_agent,
                event: event.event,
                handler: event.handler
              });
            }
          } else if (action === 'unsubscribe') {
            for (const event of params.events) {
              await agentManager.unsubscribeFromEvent(
                params.source_agent,
                event.event,
                event.handler
              );
            }
          }
          break;
          
        case 'api':
          if (action === 'expose') {
            for (const method of params.methods) {
              await agentManager.exposeMethod(
                method.name,
                method.handler
              );
              
              bindings.push({
                method: method.name,
                handler: method.handler
              });
            }
          } else if (action === 'unexpose') {
            for (const methodName of params.methods) {
              await agentManager.unexposeMethod(methodName);
            }
          }
          break;
          
        default:
          throw new Error(`Unknown target: ${target}`);
      }
      
      return {
        success: true,
        bindings,
        rollback: {
          description: `Revert agent bindings`,
          execute: async () => {
            if (target === 'event_bus' && action === 'subscribe') {
              for (const binding of bindings) {
                await agentManager.unsubscribeFromEvent(
                  binding.source,
                  binding.event,
                  binding.handler
                );
              }
            } else if (target === 'api' && action === 'expose') {
              for (const binding of bindings) {
                await agentManager.unexposeMethod(binding.method);
              }
            }
          }
        }
      };
    } catch (error) {
      return { success: false, error: error.message };
    }
  }
  
  /**
   * Handles database_schema steps
   * @param {Object} step Step configuration
   * @returns {Promise<Object>} Step result
   */
  async handleDatabaseSchema(step) {
    if (!this.validateDependencies(['database'])) {
      return { success: false, error: 'Missing database dependency' };
    }
    
    const { database } = this.dependencies;
    const { target, action, params } = step;
    
    try {
      switch (action) {
        case 'ensure_table':
          const tableExists = await database.tableExists(params.table_name);
          
          if (!tableExists) {
            await database.createTable(params.table_name, params.schema);
          }
          break;
          
        case 'add_columns':
          await database.addColumns(params.table_name, params.columns);
          break;
          
        case 'drop_table':
          await database.dropTable(params.table_name);
          break;
          
        default:
          throw new Error(`Unknown action: ${action}`);
      }
      
      return {
        success: true,
        rollback: action !== 'drop_table' ? {
          description: `Revert database schema changes`,
          execute: async () => {
            if (action === 'ensure_table' && !tableExists) {
              await database.dropTable(params.table_name);
            } else if (action === 'add_columns') {
              await database.dropColumns(params.table_name, params.columns.map(c => c.name));
            }
          }
        } : null
      };
    } catch (error) {
      return { success: false, error: error.message };
    }
  }
  
  /**
   * Handles notification preprocessing steps
   * @param {Object} step Step configuration
   * @returns {Promise<Object>} Step result
   */
  async handlePreprocessNotification(step) {
    if (!this.validateDependencies(['agentManager'])) {
      return { success: false, error: 'Missing agentManager dependency' };
    }
    
    try {
      const { userId, type, context } = step.params;
      
      // Apply any transformations defined in the config
      let modifiedContext = { ...context };
      let skipNotification = false;
      let resultValue = true;
      
      // Get notification tier if available
      let notificationTier = 2; // Default to tier 2 (Informational)
      
      // Get NotificationAgent instance if available
      const notificationAgent = this.dependencies.agentManager.getAgent('Notification');
      if (notificationAgent && typeof notificationAgent.getNotificationTier === 'function') {
        notificationTier = notificationAgent.getNotificationTier(type);
      } else if (notificationAgent && notificationAgent.config && 
                notificationAgent.config.triggers && 
                notificationAgent.config.triggers[type] && 
                typeof notificationAgent.config.triggers[type].tier === 'number') {
        notificationTier = notificationAgent.config.triggers[type].tier;
      }
      
      // Get user status if possible
      let userStatus = 'online'; // Default to online
      try {
        if (this.dependencies.discord) {
          const user = await this.dependencies.discord.getUser(userId);
          if (user && user.presence) {
            userStatus = user.presence.status;
          }
        }
      } catch (err) {
        logger.error(`Error checking user status: ${err.message}`);
      }
      
      // Enhanced preprocessing logic based on notification type and tier
      switch (type) {
        case 'match_queue':
          // Tier 0 (Critical) - Check if user is already in an active match
          try {
            if (this.dependencies.matchManager) {
              const userMatches = await this.dependencies.matchManager.getUserActiveMatches(userId);
              if (userMatches && userMatches.length > 0) {
                // User is in an active match, skip the notification
                logger.info(`Skipping match_queue notification for ${userId} - already in active match`);
                skipNotification = true;
              }
            }
          } catch (err) {
            logger.error(`Error checking match status: ${err.message}`);
          }
          
          // For offline users, update the context to increase visibility
          if (userStatus === 'offline' || userStatus === 'idle') {
            modifiedContext = {
              ...modifiedContext,
              urgent: true,
              timeout: Math.max(modifiedContext.timeout || 300, 600) // Extend timeout for offline users
            };
            logger.info(`Enhanced match_queue notification for ${userId} - offline/idle status detected`);
          }
          break;
          
        case 'pre_game':
          // Tier 0 (Critical) - Always process these regardless of status
          // But add more context based on user's status
          if (userStatus === 'offline') {
            modifiedContext = {
              ...modifiedContext,
              urgent: true,
              require_confirmation: true
            };
            logger.info(`Enhanced pre_game notification for offline user ${userId}`);
          }
          break;
          
        case 'role_retention':
          // Tier 1 (Important) - Check user status and activity
          try {
            if (this.dependencies.discord) {
              const user = await this.dependencies.discord.getUser(userId);
              if (user && user.presence && user.presence.status === 'dnd') {
                // Add additional context about dnd status
                modifiedContext = {
                  ...modifiedContext,
                  user_status: 'dnd',
                  extension_days: 3 // Give DND users extra days
                };
                
                logger.info(`Modified role_retention notification for ${userId} - DND status detected`);
              }
            }
            
            // Check user's recent activity if available
            if (this.dependencies.playerStateAgent) {
              const lastActive = await this.dependencies.playerStateAgent.getLastActiveTime(userId);
              
              // If user was active in last 72 hours, auto-confirm and skip notification
              if (lastActive && (Date.now() - lastActive) < 259200000) { // 72 hours in ms
                logger.info(`Auto-confirming role retention for recently active user ${userId}`);
                
                // Emit event for notification agent to handle
                if (this.dependencies.agentManager) {
                  this.dependencies.agentManager.emit('role:retention_auto_confirmed', { 
                    userId, 
                    roleName: modifiedContext.role_name,
                    reason: 'recent_activity'
                  });
                  
                  skipNotification = true;
                  resultValue = true; // Return success
                }
              }
            }
          } catch (err) {
            logger.error(`Error processing role_retention status: ${err.message}`);
          }
          break;
          
        case 'match_result':
        case 'announcements':
        case 'tips':
          // For lower priority notifications (Tier 1-2), respect user preferences
          try {
            // Check user preferences if available
            if (this.dependencies.playerStateAgent && 
                typeof this.dependencies.playerStateAgent.getUserNotificationPreferences === 'function') {
              const prefs = await this.dependencies.playerStateAgent.getUserNotificationPreferences(userId);
              
              // Skip if user doesn't want this tier
              if (prefs && typeof prefs.max_tier === 'number' && notificationTier > prefs.max_tier) {
                logger.info(`Skipping tier ${notificationTier} notification for ${userId} based on user preferences`);
                skipNotification = true;
                resultValue = true;
              }
              
              // For DND status, skip non-critical notifications
              if (userStatus === 'dnd' && notificationTier > 0) {
                logger.info(`Skipping tier ${notificationTier} notification for DND user ${userId}`);
                skipNotification = true;
                resultValue = true;
              }
            }
          } catch (err) {
            logger.error(`Error checking user preferences: ${err.message}`);
          }
          break;
      }
      
      // If specific handler functions defined, execute them
      if (step.params.handler) {
        const handlerFn = this.dependencies[step.params.handler];
        if (typeof handlerFn === 'function') {
          const result = await handlerFn(userId, type, modifiedContext);
          
          // Handler can return modified context or indicate to skip notification
          if (result) {
            if (result.skip) {
              skipNotification = true;
              if (result.result !== undefined) {
                resultValue = result.result;
              }
            }
            
            if (result.context) {
              modifiedContext = result.context;
            }
          }
        }
      }
      
      // Add metadata to the context
      modifiedContext = {
        ...modifiedContext,
        _meta: {
          tier: notificationTier,
          user_status: userStatus,
          processed_at: Date.now()
        }
      };
      
      // If notification should be skipped, return early
      if (skipNotification) {
        return { 
          success: true, 
          skip: true,
          result: resultValue
        };
      }
      
      return {
        success: true,
        context: modifiedContext
      };
    } catch (error) {
      logger.error(`Error in preprocess_notification step: ${error.message}`);
      return { 
        success: true, 
        error: error.message,
        context: step.params.context // Return original context on error
      };
    }
  }
  
  /**
   * Handles custom expiration logic for notifications
   * @param {Object} step Step configuration
   * @returns {Promise<Object>} Step result
   */
  async handleCheckExpirations(step) {
    if (!this.validateDependencies(['agentManager'])) {
      return { success: false, error: 'Missing agentManager dependency' };
    }
    
    try {
      const { stateStore } = step.params;
      let handled = false;
      
      // If a custom handler is specified, use it first
      if (step.params.handler) {
        const handlerFn = this.dependencies[step.params.handler];
        if (typeof handlerFn === 'function') {
          const result = await handlerFn(stateStore);
          handled = result && result.handled;
          
          if (handled) {
            return {
              success: true,
              handled: true
            };
          }
        }
      }
      
      // If no custom handler or not handled, implement common expiration strategies
      if (!handled && stateStore) {
        const now = Date.now();
        const expiredItems = [];
        const extendedItems = [];
        
        // Get notification agent for tier info
        const notificationAgent = this.dependencies.agentManager?.getAgent('Notification');
        
        // Process notifications with tier-specific logic
        for (const [userId, notifications] of stateStore.entries()) {
          for (const [type, data] of Object.entries(notifications)) {
            // Skip notifications without expiry
            if (data.expires_at === 0) continue;
            
            // Calculate expiration details
            const timeUntilExpiry = data.expires_at - now;
            const isExpired = timeUntilExpiry <= 0;
            const isAboutToExpire = !isExpired && timeUntilExpiry <= 30000; // Within 30 seconds
            
            // Get tier from data or lookup
            const tier = data.tier ?? (notificationAgent ? 
                notificationAgent.getNotificationTier(type) : 
                (type === 'match_queue' || type === 'pre_game' ? 0 : 
                 type === 'role_retention' || type === 'match_result' ? 1 : 2));
            
            // Process based on tier and expiration status
            if (isExpired || isAboutToExpire) {
              // Handle based on notification tier and type
              switch(true) {
                // TIER 0 (CRITICAL) - Special handling for game-critical notifications
                case tier === 0 && (type === 'match_queue' || type === 'pre_game'):
                  // Check if user is online but missed the notification
                  let userStatus = 'unknown';
                  
                  try {
                    if (this.dependencies.discord) {
                      const user = await this.dependencies.discord.getUser(userId);
                      if (user && user.presence) {
                        userStatus = user.presence.status;
                      }
                    }
                  } catch (err) {
                    logger.error(`Error checking user status: ${err.message}`);
                  }
                  
                  // For online users, give extra grace period for critical notifications
                  if ((userStatus === 'online' || userStatus === 'idle') && isAboutToExpire) {
                    // Extend expiration by 30 seconds for active users
                    const extensionTime = 30000; // 30 seconds
                    data.expires_at += extensionTime;
                    
                    // If we have notify service, try to ping them again
                    if (type === 'pre_game' && this.dependencies.discord) {
                      try {
                        const user = await this.dependencies.discord.getUser(userId);
                        if (user) {
                          await user.send(`⚠️ **REMINDER:** Your match is starting! Please respond within ${Math.ceil(extensionTime/1000)} seconds!`);
                        }
                      } catch (err) {
                        logger.error(`Error sending reminder: ${err.message}`);
                      }
                    }
                    
                    // Track that we extended this item
                    extendedItems.push({ userId, type, extensionTime });
                    logger.info(`Extended ${type} expiration for online user ${userId} by ${extensionTime/1000} seconds`);
                    
                    // Don't expire it yet
                    continue;
                  }
                  
                  // For queue checks, verify if user is still in queue before expiring
                  if (type === 'match_queue' && this.dependencies.queueManager) {
                    try {
                      const isQueued = await this.dependencies.queueManager.isUserInQueue(
                        userId, 
                        data.context.queue_id
                      );
                      
                      // If user is no longer in queue, remove the notification
                      if (!isQueued) {
                        logger.info(`Removing match_queue notification for ${userId} - no longer in queue`);
                        expiredItems.push({ userId, type });
                        continue;
                      }
                    } catch (err) {
                      logger.error(`Error checking queue status: ${err.message}`);
                    }
                  }
                  break;
                  
                // TIER 1 (IMPORTANT) - Handle role retention with activity checking
                case tier === 1 && type === 'role_retention':
                  // For role retention, check if user has been active recently
                  if (this.dependencies.playerStateAgent) {
                    try {
                      const lastActive = await this.dependencies.playerStateAgent.getLastActiveTime(userId);
                      
                      // If user was active in the last 48 hours, auto-confirm
                      const activityThreshold = 48 * 60 * 60 * 1000; // 48 hours
                      
                      if (lastActive && (now - lastActive) < activityThreshold) {
                        logger.info(`Auto-confirming role retention for active user ${userId}`);
                        
                        // Emit event for notification agent to handle
                        if (this.dependencies.agentManager) {
                          this.dependencies.agentManager.emit('role:retention_auto_confirmed', { 
                            userId, 
                            roleName: data.context.role_name,
                            reason: 'recent_activity'
                          });
                        }
                        
                        // Mark as handled by removing
                        expiredItems.push({ userId, type });
                        continue;
                      }
                    } catch (err) {
                      logger.error(`Error checking user activity: ${err.message}`);
                    }
                  }
                  break;
                  
                // TIER 2 (INFORMATIONAL) - Just let them expire normally
                case tier === 2:
                  // No special handling for informational notifications
                  break;
                  
                // For any other notification types, check if they're actually expired
                default:
                  if (isExpired) {
                    expiredItems.push({ userId, type });
                  }
                  break;
              }
            }
          }
        }
        
        // Apply our notification extensions if any
        if (extendedItems.length > 0) {
          handled = true;
          for (const { userId, type, extensionTime } of extendedItems) {
            logger.info(`Extended ${type} notification for ${userId} by ${extensionTime/1000}s`);
          }
        }
        
        // Apply any expired item removals
        if (expiredItems.length > 0) {
          // Process each expired item
          for (const { userId, type } of expiredItems) {
            const userNotifications = stateStore.get(userId);
            if (userNotifications) {
              // Remove this notification
              delete userNotifications[type];
              
              // Remove user if no more notifications
              if (Object.keys(userNotifications).length === 0) {
                stateStore.delete(userId);
              } else {
                stateStore.set(userId, userNotifications);
              }
            }
          }
          
          // Mark as handled if we processed anything
          handled = true;
        }
      }
      
      return {
        success: true,
        handled
      };
    } catch (error) {
      logger.error(`Error in check_expirations step: ${error.message}`);
      return { 
        success: true,
        error: error.message,
        handled: false
      };
    }
  }
  
  /**
   * Handles queue keep-alive processing with enhanced logic
   * @param {Object} step Step configuration
   * @returns {Promise<Object>} Step result
   */
  async handleQueueKeepAliveProcessing(step) {
    if (!this.validateDependencies(['agentManager'])) {
      return { success: false, error: 'Missing agentManager dependency' };
    }
    
    try {
      const { userId, context } = step.params;
      let processed = false;
      
      // If a custom handler is specified, use it first
      if (step.params.handler) {
        const handlerFn = this.dependencies[step.params.handler];
        if (typeof handlerFn === 'function') {
          const result = await handlerFn(userId, context);
          if (result && result.processed) {
            return {
              success: true,
              processed: true,
              success: result.success !== undefined ? result.success : true
            };
          }
        }
      }
      
      // Implement enhanced keep-alive logic with tiered approach
      
      // 1. Check user's current status
      let userStatus = 'online';
      if (this.dependencies.discord) {
        try {
          const user = await this.dependencies.discord.getUser(userId);
          if (user && user.presence) {
            userStatus = user.presence.status;
          }
        } catch (err) {
          logger.error(`Error getting user status: ${err.message}`);
        }
      }
      
      // 2. Check if user has queued recently and their activity pattern
      let frequentUser = false;
      let recentlyActive = false;
      let queueAbandonRate = 0;
      
      if (this.dependencies.database) {
        try {
          // Get recent queue history (last 7 days)
          const recentActivity = await this.dependencies.database.getUserQueueHistory(
            userId, 
            Date.now() - (7 * 24 * 60 * 60 * 1000) // Last 7 days
          );
          
          frequentUser = recentActivity && recentActivity.count >= 10;
          
          // Check if user has been active in the last hour
          if (this.dependencies.playerStateAgent && 
              typeof this.dependencies.playerStateAgent.getLastActiveTime === 'function') {
            const lastActive = await this.dependencies.playerStateAgent.getLastActiveTime(userId);
            recentlyActive = lastActive && (Date.now() - lastActive < 3600000); // Active in last hour
          }
          
          // Check if user has a history of abandoning queues
          if (recentActivity && recentActivity.queued && recentActivity.abandoned) {
            queueAbandonRate = recentActivity.abandoned / recentActivity.queued;
          }
        } catch (err) {
          logger.error(`Error checking user queue history: ${err.message}`);
        }
      }
      
      // 3. Determine if we should modify the keep-alive behavior based on user profile
      const matchName = context.match_name;
      const queueId = context.queue_id;
      
      // Create a comprehensive user profile for keep-alive decision
      const userProfile = {
        status: userStatus,
        frequentUser,
        recentlyActive,
        queueAbandonRate
      };
      
      // Smart handling based on user profile
      switch (true) {
        // Case 1: Active, frequent user with good history - auto-confirm
        case (userStatus === 'online' && frequentUser && queueAbandonRate < 0.1):
          logger.info(`Auto-confirming queue keep-alive for reliable frequent user ${userId}`);
          
          // Emit auto-confirm event
          if (this.dependencies.agentManager) {
            this.dependencies.agentManager.emit('queue:keep_alive_auto_confirmed', { 
              userId, 
              queueId, 
              matchName,
              reason: 'reliable_frequent_user',
              userProfile
            });
          }
          
          processed = true;
          break;
          
        // Case 2: Recently active users - extend timeout 
        case (recentlyActive && userStatus !== 'offline'):
          logger.info(`Extending keep-alive timeout for recently active user ${userId}`);
          
          // Custom handling for users who were just active
          if (this.dependencies.agentManager) {
            // Return context with extended timeout
            const notificationAgent = this.dependencies.agentManager.getAgent('Notification');
            if (notificationAgent) {
              const userNotifications = notificationAgent.stateStore.get(userId) || {};
              
              // If there's an existing match_queue notification, extend it
              if (userNotifications['match_queue'] && 
                  userNotifications['match_queue'].expires_at > 0) {
                // Extend by 50%
                const currentExpiry = userNotifications['match_queue'].expires_at;
                const newExpiry = Math.max(
                  currentExpiry,
                  Date.now() + ((currentExpiry - Date.now()) * 1.5)
                );
                
                userNotifications['match_queue'].expires_at = newExpiry;
                notificationAgent.stateStore.set(userId, userNotifications);
                
                logger.info(`Extended match_queue expiration for ${userId} to ${new Date(newExpiry).toISOString()}`);
                processed = true;
              }
            }
          }
          break;
          
        // Case 3: Offline users with high abandon rate - no special processing
        case (userStatus === 'offline' && queueAbandonRate > 0.5):
          logger.info(`Standard processing for offline user ${userId} with high abandon rate`);
          break;
          
        // Case 4: DND users - check if match is about to start
        case (userStatus === 'dnd'):
          // Check if match is about to start
          try {
            if (this.dependencies.queueManager && 
                typeof this.dependencies.queueManager.getQueueStatus === 'function') {
              const queueStatus = await this.dependencies.queueManager.getQueueStatus(queueId);
              
              // If queue is almost full (>80%), try to notify DND user
              if (queueStatus && queueStatus.percentage >= 80) {
                logger.info(`Special DND handling for user ${userId} - match almost ready`);
                
                // Send a special DND alert via agentManager
                if (this.dependencies.agentManager) {
                  this.dependencies.agentManager.emit('queue:dnd_alert', { 
                    userId, 
                    queueId, 
                    matchName,
                    queueStatus
                  });
                }
                
                processed = true;
              }
            }
          } catch (err) {
            logger.error(`Error checking queue status: ${err.message}`);
          }
          break;
      }
      
      return {
        success: true,
        processed
      };
    } catch (error) {
      logger.error(`Error in queue_keep_alive_processing step: ${error.message}`);
      return { 
        success: true,
        error: error.message,
        processed: false
      };
    }
  }
}

module.exports = SuperLoader;
