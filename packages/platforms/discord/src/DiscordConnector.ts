import { Client, GatewayIntentBits, Events, Message } from 'discord.js';
import { Platform, PlatformConfig, MessageData } from '../../../core/src';

export interface DiscordConfig extends PlatformConfig {
  parameters: {
    token: string;
    commandPrefix: string;
    intents?: GatewayIntentBits[];
  };
}

export class DiscordConnector extends Platform {
  private client: Client;
  private commandPrefix: string;

  constructor(config: DiscordConfig) {
    super(config);
    
    // Set default intents if not provided
    const intents = config.parameters.intents || [
      GatewayIntentBits.Guilds,
      GatewayIntentBits.GuildMessages,
      GatewayIntentBits.MessageContent
    ];
    
    this.client = new Client({ intents });
    this.commandPrefix = config.parameters.commandPrefix;
    
    // Set up message handling
    this.setupMessageHandler();
  }

  async connect(): Promise<void> {
    try {
      await this.client.login(this.parameters.token);
      this.setConnected(true);
      console.log(`Discord connector ${this.name} connected successfully`);
    } catch (error) {
      console.error('Failed to connect to Discord:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async disconnect(): Promise<void> {
    try {
      await this.client.destroy();
      this.setConnected(false);
      console.log(`Discord connector ${this.name} disconnected`);
    } catch (error) {
      console.error('Failed to disconnect from Discord:', error);
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

  async sendMessage(message: string, channelId: string): Promise<void> {
    try {
      const channel = await this.client.channels.fetch(channelId);
      if (channel?.isSendable()) {
        await channel.send(message);
      } else {
        throw new Error('Channel is not text-based');
      }
    } catch (error) {
      console.error('Failed to send Discord message:', error);
      this.emit('error', error);
      throw error;
    }
  }

  private setupMessageHandler(): void {
    this.client.on(Events.MessageCreate, (message: Message) => {
      // Ignore bot messages to prevent feedback loops
      if (message.author.bot) return;

      const content = message.content;
      
      // Process as command if it starts with the command prefix
      if (content.startsWith(this.commandPrefix)) {
        const commandContent = content.slice(this.commandPrefix.length).trim();
        const commandParts = commandContent.split(/\s+/);
        const command = commandParts[0];
        const args = commandParts.slice(1);
        
        this.emit('command', {
          command,
          args,
          content: commandContent,
          sender: message.author.id,
          senderName: message.author.username,
          channelId: message.channelId,
          timestamp: message.createdAt
        });
        
        return;
      }

      // Process as regular message
      const messageData: MessageData = {
        content: message.content,
        sender: message.author.id,
        channelId: message.channelId,
        timestamp: message.createdAt
      };

      this.emit('message', messageData);
    });

    // Set up connection status events
    this.client.on(Events.ClientReady, () => {
      console.log(`Logged in as ${this.client.user?.tag}!`);
      this.emit('ready', this.client.user?.tag);
    });

    this.client.on(Events.Error, (error) => {
      console.error('Discord client error:', error);
      this.emit('error', error);
    });
  }
} 