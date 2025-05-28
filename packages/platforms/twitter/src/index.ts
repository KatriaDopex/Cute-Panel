import { EventEmitter } from 'events';
import { TwitterApi, TweetV2 } from 'twitter-api-v2';
import { Platform, PlatformConfig, MessageData } from '@cutepanel/core';

// Define interfaces to match the Platform abstract class requirements
export interface TwitterApiTokens {
  appKey: string;
  appSecret: string;
  accessToken: string;
  accessSecret: string;
}

export interface TwitterConfig extends PlatformConfig {
  parameters: TwitterApiTokens & {
    commandPrefix: string;
    autoReply?: boolean;
    mentionsOnly?: boolean;
  };
}

export class TwitterConnector extends Platform {
  private client: TwitterApi;
  private commandPrefix: string;
  private autoReply: boolean;
  private mentionsOnly: boolean;
  private userId?: string;
  private streamRules: Map<string, string> = new Map();

  constructor(config: TwitterConfig) {
    super(config);
    this.commandPrefix = config.parameters.commandPrefix;
    this.autoReply = config.parameters.autoReply || false;
    this.mentionsOnly = config.parameters.mentionsOnly || false;
    
    // Create the Twitter API client using the parameters
    this.client = new TwitterApi({
      appKey: config.parameters.appKey,
      appSecret: config.parameters.appSecret,
      accessToken: config.parameters.accessToken,
      accessSecret: config.parameters.accessSecret
    });
  }

  async connect(): Promise<void> {
    try {
      // Verify credentials and get user ID
      const me = await this.client.v2.me();
      this.userId = me.data.id;

      // Set up stream rules
      await this.setupStreamRules();

      // Start streaming
      await this.startStreaming();

      this.setConnected(true);
      console.log(`Twitter connector ${this.name} connected successfully`);
    } catch (error) {
      console.error('Failed to connect to Twitter:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async disconnect(): Promise<void> {
    try {
      // Clean up stream rules
      await this.cleanupStreamRules();
      this.setConnected(false);
      console.log(`Twitter connector ${this.name} disconnected`);
    } catch (error) {
      console.error('Failed to disconnect from Twitter:', error);
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

  async sendMessage(message: string, recipientId: string): Promise<void> {
    try {
      // Handle both tweet replies and direct messages
      if (recipientId.startsWith('tweet:')) {
        // Reply to a tweet
        const tweetId = recipientId.replace('tweet:', '');
        await this.client.v2.reply(message, tweetId);
      } else {
        // Send a direct message
        await this.client.v1.sendDm({
          recipient_id: recipientId,
          text: message
        });
      }
    } catch (error) {
      console.error('Failed to send Twitter message:', error);
      this.emit('error', error);
      throw error;
    }
  }

  private async setupStreamRules() {
    // Clean up existing rules
    await this.cleanupStreamRules();

    // Add new rules
    const rules = [];

    // Rule for mentions
    if (this.mentionsOnly) {
      rules.push({ value: `@${this.userId}` });
    }

    // Rule for commands
    if (this.commandPrefix) {
      rules.push({ value: `${this.commandPrefix}` });
    }

    if (rules.length > 0) {
      const result = await this.client.v2.updateStreamRules({
        add: rules
      });

      // Store rule IDs
      result.data?.forEach(rule => {
        this.streamRules.set(rule.id, rule.value);
      });
    }
  }

  private async cleanupStreamRules() {
    const rules = await this.client.v2.streamRules();
    if (rules.data?.length) {
      await this.client.v2.updateStreamRules({
        delete: { ids: rules.data.map(rule => rule.id) }
      });
    }
    this.streamRules.clear();
  }

  private async startStreaming() {
    const stream = await this.client.v2.searchStream({
      'tweet.fields': ['referenced_tweets', 'author_id', 'created_at'],
      'user.fields': ['username'],
      expansions: ['author_id', 'referenced_tweets.id']
    });

    stream.on('data', async (tweet: TweetV2) => {
      // Ignore our own tweets
      if (tweet.author_id === this.userId) return;

      // Process the tweet
      await this.processTweet(tweet);
    });

    stream.on('error', error => {
      console.error('Twitter stream error:', error);
      this.emit('error', error);
    });
  }

  private async processTweet(tweet: TweetV2) {
    try {
      const tweetText = tweet.text;
      const author = tweet.author_id;
      const tweetId = tweet.id;
      const createdAt = tweet.created_at ? new Date(tweet.created_at) : new Date();
      
      // Check if it's a command
      if (tweetText.startsWith(this.commandPrefix)) {
        const commandContent = tweetText.slice(this.commandPrefix.length).trim();
        const commandParts = commandContent.split(/\s+/);
        const command = commandParts[0];
        const args = commandParts.slice(1);
        
        this.emit('command', {
          command,
          args,
          content: commandContent,
          sender: author,
          tweetId: tweetId,
          timestamp: createdAt
        });
        
        return;
      }
      
      // Process as regular message
      const messageData: MessageData = {
        content: tweetText,
        sender: author ? author : 'unknown',
        channelId: `tweet:${tweetId}`, // Use tweet ID as channel ID for replies
        timestamp: createdAt
      };
      
      this.emit('message', messageData);
      
      // Auto-reply if enabled
      if (this.autoReply) {
        await this.client.v2.reply('Thank you for your tweet! I am an automated agent.', tweetId);
      }
    } catch (error) {
      console.error('Error processing tweet:', error);
      this.emit('error', error);
    }
  }
} 