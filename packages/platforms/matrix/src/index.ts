import { EventEmitter } from 'events';
import * as sdk from 'matrix-js-sdk';
import { MatrixClient, MatrixEvent, Room, RoomMember, RoomEvent, RoomMemberEvent, IRoomTimelineData } from 'matrix-js-sdk';

// Define interfaces to match the Platform abstract class requirements
export interface PlatformConfig {
  name: string;
  type: string;
  parameters?: Record<string, any>;
}

export interface MessageData {
  content: string;
  sender: string;
  channelId?: string;
  timestamp: Date;
}

export interface MatrixConfig extends PlatformConfig {
  parameters: {
    homeserverUrl: string;
    accessToken: string;
    userId: string;
    commandPrefix: string;
    autoJoin?: boolean;
  };
}

export interface MatrixMessage {
  content: string;
  authorId: string;
  roomId: string;
  messageId: string;
  raw: MatrixEvent;
}

export interface MatrixReaction {
  eventId: string;
  key: string;
  userId: string;
}

export class MatrixConnector extends EventEmitter {
  protected name: string;
  protected type: string;
  protected parameters: Record<string, any>;
  protected isConnected: boolean;
  
  private client: MatrixClient;
  private commandPrefix: string;
  private autoJoin: boolean;
  private userId: string;

  constructor(config: MatrixConfig) {
    super();
    this.name = config.name;
    this.type = config.type;
    this.parameters = config.parameters || {};
    this.isConnected = false;
    
    this.commandPrefix = config.parameters.commandPrefix;
    this.autoJoin = config.parameters.autoJoin || false;
    this.userId = config.parameters.userId;
    
    this.client = sdk.createClient({
      baseUrl: config.parameters.homeserverUrl,
      accessToken: config.parameters.accessToken,
      userId: config.parameters.userId
    });
  }

  async connect(): Promise<void> {
    try {
      await this.client.startClient();
      this.setupEventHandlers();
      this.setConnected(true);
      console.log(`Matrix connector ${this.name} connected successfully`);
    } catch (error) {
      console.error('Failed to connect to Matrix:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async disconnect(): Promise<void> {
    try {
      await this.client.stopClient();
      this.setConnected(false);
      console.log(`Matrix connector ${this.name} disconnected`);
    } catch (error) {
      console.error('Failed to disconnect from Matrix:', error);
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

  private setupEventHandlers(): void {
    this.client.on(RoomEvent.Timeline, (event: MatrixEvent, room: Room | undefined, toStartOfTimeline: boolean | undefined, removed: boolean, data: IRoomTimelineData) => {
      if (!room || event.getType() !== 'm.room.message') return;
      if (event.getSender() === this.userId) return;

      const content = event.getContent();
      const msgContent = content.body;
      const sender = event.getSender()!;
      const roomId = room.roomId;
      const messageId = event.getId()!;
      const timestamp = new Date(event.getTs());

      // Check if it's a command
      if (msgContent.startsWith(this.commandPrefix)) {
        const commandContent = msgContent.slice(this.commandPrefix.length).trim();
        const commandParts = commandContent.split(/\s+/);
        const command = commandParts[0];
        const args = commandParts.slice(1);
        
        this.emit('command', {
          command,
          args,
          content: commandContent,
          sender,
          channelId: roomId,
          messageId,
          timestamp
        });
        
        return;
      }
      
      // Process as regular message
      const messageData: MessageData = {
        content: msgContent,
        sender,
        channelId: roomId,
        timestamp
      };
      
      this.emit('message', messageData);
    });

    if (this.autoJoin) {
      this.client.on(RoomMemberEvent.Membership, (event: MatrixEvent, member: RoomMember) => {
        if (member.membership === 'invite' && member.userId === this.userId) {
          this.joinRoom(member.roomId);
        }
      });
    }

    // Add reaction handler
    this.client.on(RoomEvent.Timeline, (event: MatrixEvent, room: Room | undefined, toStartOfTimeline: boolean | undefined, removed: boolean, data: any) => {
      if (!room || event.getType() !== 'm.reaction') return;

      const content = event.getContent();
      const relation = content['m.relates_to'];
      
      if (relation && relation.rel_type === 'm.annotation') {
        this.emit('reaction', {
          eventId: relation.event_id,
          key: relation.key,
          userId: event.getSender()!,
          roomId: room.roomId,
          timestamp: new Date(event.getTs())
        });
      }
    });
  }

  async sendMessage(content: string, roomId: string): Promise<void> {
    try {
      await this.client.sendTextMessage(roomId, content);
    } catch (error) {
      console.error('Failed to send Matrix message:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async editMessage(roomId: string, messageId: string, newContent: string): Promise<void> {
    try {
      await this.client.sendMessage(roomId, {
        'msgtype': sdk.MsgType.Text,
        'body': `* ${newContent}`,
        'm.new_content': {
          'msgtype': sdk.MsgType.Text,
          'body': newContent
        },
        'm.relates_to': {
          'rel_type': sdk.RelationType.Replace,
          'event_id': messageId
        }
      });
    } catch (error) {
      console.error('Failed to edit Matrix message:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async deleteMessage(roomId: string, messageId: string): Promise<void> {
    try {
      await this.client.redactEvent(roomId, messageId);
    } catch (error) {
      console.error('Failed to delete Matrix message:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async joinRoom(roomId: string): Promise<void> {
    try {
      await this.client.joinRoom(roomId);
    } catch (error) {
      console.error('Failed to join Matrix room:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async leaveRoom(roomId: string): Promise<void> {
    try {
      await this.client.leave(roomId);
    } catch (error) {
      console.error('Failed to leave Matrix room:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async addReaction(roomId: string, eventId: string, key: string): Promise<void> {
    try {
      await this.client.sendEvent(roomId, sdk.EventType.Reaction, {
        'm.relates_to': {
          'rel_type': sdk.RelationType.Annotation,
          'event_id': eventId,
          'key': key
        }
      });
    } catch (error) {
      console.error('Failed to add Matrix reaction:', error);
      this.emit('error', error);
      throw error;
    }
  }

  async removeReaction(roomId: string, eventId: string, key: string): Promise<void> {
    try {
      // Find the reaction event
      const room = this.client.getRoom(roomId);
      if (!room) throw new Error(`Room not found: ${roomId}`);
      
      const timeline = room.getUnfilteredTimelineSet().getLiveTimeline().getEvents();
      const reactionEvent = timeline.find(e => 
        e.getType() === 'm.reaction' && 
        e.getContent()?.['m.relates_to']?.event_id === eventId &&
        e.getContent()?.['m.relates_to']?.key === key
      );
      
      if (reactionEvent) {
        await this.client.redactEvent(roomId, reactionEvent.getId()!);
      }
    } catch (error) {
      console.error('Failed to remove Matrix reaction:', error);
      this.emit('error', error);
      throw error;
    }
  }
  
  getName(): string {
    return this.name;
  }

  getType(): string {
    return this.type;
  }

  isActive(): boolean {
    return this.isConnected;
  }

  protected setConnected(connected: boolean): void {
    this.isConnected = connected;
    if (connected) {
      this.emit('connected');
    } else {
      this.emit('disconnected');
    }
  }
} 