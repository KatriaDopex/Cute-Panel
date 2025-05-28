import { Telegraf, Context } from 'telegraf';
import { Update, Message } from 'telegraf/types';
import { Platform, PlatformConfig, MessageData } from '@cutepanel/core';

export interface TelegramConfig extends PlatformConfig {
  parameters: {
    token: string;
    commandPrefix: string;
  };
}

export class TelegramConnector extends Platform {
  private bot: Telegraf;
  private commandPrefix: string;

  constructor(config: TelegramConfig) {
    super(config);
    this.commandPrefix = config.parameters.commandPrefix;
    
    console.log('Initializing Telegram bot with token:', config.parameters.token.slice(0, 10) + '...');
    this.bot = new Telegraf(config.parameters.token);
    
    // Set up error handling
    this.bot.catch((err: any) => {
      console.error('Telegram Error:', err);
      if (err.response) {
        console.error('Error response:', {
          code: err.response.error_code,
          description: err.response.description
        });
      }
      this.emit('error', err);
    });
    
    this.setupMessageHandlers();
  }

  async connect(): Promise<void> {
    try {
      // Initialize bot webhook or polling
      await this.bot.launch();
      this.setConnected(true);
      console.log(`Telegram connector ${this.name} connected successfully`);
    } catch (error) {
      console.error('Failed to connect to Telegram:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async disconnect(): Promise<void> {
    try {
      // Stop the bot
      await this.bot.stop();
      this.setConnected(false);
      console.log(`Telegram connector ${this.name} disconnected`);
    } catch (error) {
      console.error('Failed to disconnect from Telegram:', error);
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

  async sendMessage(message: string, chatId: string): Promise<void> {
    try {
      await this.bot.telegram.sendMessage(chatId, message);
    } catch (error) {
      console.error('Failed to send Telegram message:', error);
      this.emit('error', error);
      throw error;
    }
  }

  private setupMessageHandlers(): void {
    // Handle text messages
    this.bot.on('text', async (ctx: Context) => {
      const msg = ctx.message as Message.TextMessage;
      console.log('Received Telegram message:', {
        text: msg.text,
        from: msg.from?.username,
        chatId: msg.chat.id
      });
      
      // Handle commands
      if (msg.text.startsWith(this.commandPrefix)) {
        const commandContent = msg.text.slice(this.commandPrefix.length).trim();
        const commandParts = commandContent.split(/\s+/);
        const command = commandParts[0];
        const args = commandParts.slice(1);
        
        this.emit('command', {
          command,
          args,
          content: commandContent,
          sender: msg.from?.id.toString() || 'unknown',
          senderName: msg.from?.username || 'unknown',
          chatId: msg.chat.id.toString(),
          timestamp: new Date(msg.date * 1000)
        });
        
        return;
      }

      // Handle regular messages
      const messageData: MessageData = {
        content: msg.text,
        sender: msg.from?.id.toString() || 'unknown',
        chatId: msg.chat.id.toString(),
        timestamp: new Date(msg.date * 1000)
      };

      this.emit('message', messageData);
    });
  }
} 