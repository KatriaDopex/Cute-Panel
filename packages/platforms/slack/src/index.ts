import { App, LogLevel } from '@slack/bolt';
import { WebClient } from '@slack/web-api';
import { Platform, PlatformConfig, MessageData } from '@cutepanel/core';

export interface SlackConfig extends PlatformConfig {
  parameters: {
    token: string;
    signingSecret: string;
    appToken: string;
    commandPrefix: string;
    port?: number;
  };
}

export class SlackConnector extends Platform {
  private app: App;
  private client: WebClient;
  private commandPrefix: string;

  constructor(config: SlackConfig) {
    super(config);
    this.commandPrefix = config.parameters.commandPrefix;
    
    this.app = new App({
      token: config.parameters.token,
      signingSecret: config.parameters.signingSecret,
      socketMode: true,
      appToken: config.parameters.appToken,
      port: config.parameters.port || 3000,
      logLevel: LogLevel.DEBUG
    });

    this.client = new WebClient(config.parameters.token);
    this.setupEventHandlers();
  }

  private setupEventHandlers() {
    // Handle messages
    this.app.message(async ({ message, say }) => {
      if (message.subtype === 'bot_message') return;

      const content = 'text' in message && typeof message.text === 'string' ? message.text : '';
      
      // Check if it's a command
      if (content.startsWith(this.commandPrefix)) {
        const commandContent = content.slice(this.commandPrefix.length).trim();
        const commandParts = commandContent.split(/\s+/);
        const command = commandParts[0];
        const args = commandParts.slice(1);
        
        this.emit('command', {
          command,
          args,
          content: commandContent,
          sender: 'user' in message ? message.user : 'unknown',
          channelId: message.channel,
          messageId: message.ts,
          timestamp: new Date(Number(message.ts) * 1000)
        });
        
        return;
      }

      // Emit message event
      const messageData: MessageData = {
        content,
        sender: 'user' in message ? message.user : 'unknown',
        channelId: message.channel,
        timestamp: new Date(Number(message.ts) * 1000)
      };
      
      this.emit('message', messageData);
    });

    // Handle app mentions
    this.app.event('app_mention', async ({ event }) => {
      this.emit('mention', {
        content: event.text,
        sender: event.user,
        channelId: event.channel,
        timestamp: new Date(Number(event.ts) * 1000)
      });
    });

    // Handle reactions
    this.app.event('reaction_added', async ({ event }) => {
      this.emit('reactionAdded', {
        reaction: event.reaction,
        sender: event.user,
        messageId: event.item.ts,
        channelId: event.item.channel,
        timestamp: new Date()
      });
    });
  }

  async connect(): Promise<void> {
    try {
      await this.app.start();
      this.setConnected(true);
      console.log(`Slack connector ${this.name} connected successfully`);
    } catch (error) {
      console.error('Failed to connect to Slack:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async disconnect(): Promise<void> {
    try {
      await this.app.stop();
      this.setConnected(false);
      console.log(`Slack connector ${this.name} disconnected`);
    } catch (error) {
      console.error('Failed to disconnect from Slack:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async start(): Promise<void> {
    if (!this.isActive()) {
      await this.connect();
    }
  }

  async stop(): Promise<void> {
    if (this.isActive()) {
      await this.disconnect();
    }
  }

  async sendMessage(content: string, channelId: string, threadTs?: string): Promise<void> {
    try {
      const params: any = {
        channel: channelId,
        text: content
      };

      if (threadTs) {
        params.thread_ts = threadTs;
      }

      await this.client.chat.postMessage(params);
    } catch (error) {
      console.error('Failed to send Slack message:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async updateMessage(content: string, channelId: string, messageId: string): Promise<void> {
    try {
      await this.client.chat.update({
        channel: channelId,
        ts: messageId,
        text: content
      });
    } catch (error) {
      console.error('Failed to update Slack message:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async deleteMessage(channelId: string, messageId: string): Promise<void> {
    try {
      await this.client.chat.delete({
        channel: channelId,
        ts: messageId
      });
    } catch (error) {
      console.error('Failed to delete Slack message:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async addReaction(reaction: string, channelId: string, messageId: string): Promise<void> {
    try {
      await this.client.reactions.add({
        channel: channelId,
        timestamp: messageId,
        name: reaction
      });
    } catch (error) {
      console.error('Failed to add Slack reaction:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async removeReaction(reaction: string, channelId: string, messageId: string): Promise<void> {
    try {
      await this.client.reactions.remove({
        channel: channelId,
        timestamp: messageId,
        name: reaction
      });
    } catch (error) {
      console.error('Failed to remove Slack reaction:', error);
      this.emit('error', error);
      throw error;
    }
  }
} 