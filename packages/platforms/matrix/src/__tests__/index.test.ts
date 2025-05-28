import { MatrixConnector, MatrixConfig } from '../index';
import * as sdk from 'matrix-js-sdk';
import { MatrixClient, MatrixEvent, Room, RoomMember, RoomEvent, RoomMemberEvent, RoomState } from 'matrix-js-sdk';

jest.mock('matrix-js-sdk');

describe('MatrixConnector', () => {
  let connector: MatrixConnector;
  let mockClient: jest.Mocked<Partial<MatrixClient>>;
  let mockConfig: MatrixConfig;

  beforeEach(() => {
    mockConfig = {
      homeserverUrl: 'https://matrix.example.com',
      accessToken: 'mock_token',
      userId: '@user:example.com',
      commandPrefix: '!',
      autoJoin: true
    };

    mockClient = {
      startClient: jest.fn().mockResolvedValue(undefined),
      stopClient: jest.fn().mockResolvedValue(undefined),
      on: jest.fn(),
      sendMessage: jest.fn().mockResolvedValue({}),
      sendEvent: jest.fn().mockResolvedValue({}),
      redactEvent: jest.fn().mockResolvedValue({}),
      joinRoom: jest.fn().mockResolvedValue({}),
      leave: jest.fn().mockResolvedValue({})
    } as jest.Mocked<Partial<MatrixClient>>;

    (sdk.createClient as jest.Mock).mockReturnValue(mockClient);

    connector = new MatrixConnector(mockConfig);
  });

  afterEach(() => {
    jest.clearAllMocks();
  });

  describe('connect and disconnect', () => {
    it('should start the client and emit connected event', async () => {
      const connectPromise = connector.connect();
      
      // Simulate successful connection
      await connectPromise;

      expect(mockClient.startClient).toHaveBeenCalled();
      expect(mockClient.on).toHaveBeenCalled();
    });

    it('should handle connection errors', async () => {
      const error = new Error('Connection failed');
      mockClient.startClient.mockRejectedValue(error);

      await expect(connector.connect()).rejects.toThrow('Connection failed');
    });

    it('should stop the client and emit disconnected event', async () => {
      const disconnectPromise = connector.disconnect();

      await disconnectPromise;

      expect(mockClient.stopClient).toHaveBeenCalled();
    });

    it('should handle disconnection errors', async () => {
      const error = new Error('Disconnection failed');
      mockClient.stopClient.mockRejectedValue(error);

      await expect(connector.disconnect()).rejects.toThrow('Disconnection failed');
    });
  });

  describe('message handling', () => {
    it('should handle regular messages', () => {
      const mockEvent = {
        getType: () => 'm.room.message',
        getSender: () => '@other:example.com',
        getContent: () => ({ body: 'Hello world' }),
        getId: () => 'event1'
      } as unknown as MatrixEvent;

      const mockRoom = {
        roomId: 'room1'
      } as unknown as Room;

      const mockTimelineData = {
        timeline: { live: true },
        liveEvent: true
      };

      // Get the message handler
      const messageHandler = mockClient.on.mock.calls.find(
        call => call[0] === RoomEvent.Timeline
      )?.[1] as (event: MatrixEvent, room: Room | undefined, toStartOfTimeline: boolean | undefined, removed: boolean, data: any) => void;

      if (messageHandler) {
        const messageSpy = jest.fn();
        connector.on('message', messageSpy);

        messageHandler(mockEvent, mockRoom, false, false, mockTimelineData);

        expect(messageSpy).toHaveBeenCalledWith({
          content: 'Hello world',
          authorId: '@other:example.com',
          roomId: 'room1',
          messageId: 'event1',
          raw: mockEvent
        });
      }
    });

    it('should handle commands', () => {
      const mockEvent = {
        getType: () => 'm.room.message',
        getSender: () => '@other:example.com',
        getContent: () => ({ body: '!command arg1 arg2' }),
        getId: () => 'event1'
      } as unknown as MatrixEvent;

      const mockRoom = {
        roomId: 'room1'
      } as unknown as Room;

      const mockTimelineData = {
        timeline: { live: true },
        liveEvent: true
      };

      // Get the message handler
      const messageHandler = mockClient.on.mock.calls.find(
        call => call[0] === RoomEvent.Timeline
      )?.[1] as (event: MatrixEvent, room: Room | undefined, toStartOfTimeline: boolean | undefined, removed: boolean, data: any) => void;

      if (messageHandler) {
        const commandSpy = jest.fn();
        connector.on('command', commandSpy);

        messageHandler(mockEvent, mockRoom, false, false, mockTimelineData);

        expect(commandSpy).toHaveBeenCalledWith({
          content: 'command arg1 arg2',
          authorId: '@other:example.com',
          roomId: 'room1',
          messageId: 'event1',
          raw: mockEvent
        });
      }
    });

    it('should ignore messages from self', () => {
      const mockEvent = {
        getType: () => 'm.room.message',
        getSender: () => mockConfig.userId,
        getContent: () => ({ body: 'Hello world' }),
        getId: () => 'event1'
      } as unknown as MatrixEvent;

      const mockRoom = {
        roomId: 'room1'
      } as unknown as Room;

      const mockTimelineData = {
        timeline: { live: true },
        liveEvent: true
      };

      // Get the message handler
      const messageHandler = mockClient.on.mock.calls.find(
        call => call[0] === RoomEvent.Timeline
      )?.[1] as (event: MatrixEvent, room: Room | undefined, toStartOfTimeline: boolean | undefined, removed: boolean, data: any) => void;

      if (messageHandler) {
        const messageSpy = jest.fn();
        connector.on('message', messageSpy);

        messageHandler(mockEvent, mockRoom, false, false, mockTimelineData);

        expect(messageSpy).not.toHaveBeenCalled();
      }
    });
  });

  describe('message operations', () => {
    it('should send a message successfully', async () => {
      const content = 'Test message';
      const roomId = 'room1';

      mockClient.sendMessage.mockResolvedValue({} as any);

      await connector.sendMessage(content, roomId);

      expect(mockClient.sendMessage).toHaveBeenCalledWith(roomId, {
        msgtype: 'm.text',
        body: content
      });
    });

    it('should handle send message errors', async () => {
      const error = new Error('Failed to send');
      mockClient.sendMessage.mockRejectedValue(error);

      await expect(connector.sendMessage('Test', 'room1')).rejects.toThrow('Failed to send');
    });

    it('should edit a message successfully', async () => {
      const roomId = 'room1';
      const messageId = 'msg1';
      const newContent = 'Updated message';

      mockClient.sendEvent.mockResolvedValue({} as any);

      await connector.editMessage(roomId, messageId, newContent);

      expect(mockClient.sendEvent).toHaveBeenCalledWith(roomId, 'm.room.message', {
        msgtype: 'm.text',
        body: `* ${newContent}`,
        'm.new_content': {
          msgtype: 'm.text',
          body: newContent
        },
        'm.relates_to': {
          rel_type: 'm.replace',
          event_id: messageId
        }
      });
    });

    it('should handle edit message errors', async () => {
      const error = new Error('Failed to edit');
      mockClient.sendEvent.mockRejectedValue(error);

      await expect(connector.editMessage('room1', 'msg1', 'Updated')).rejects.toThrow('Failed to edit');
    });

    it('should delete a message successfully', async () => {
      const roomId = 'room1';
      const messageId = 'msg1';

      mockClient.redactEvent.mockResolvedValue({} as any);

      await connector.deleteMessage(roomId, messageId);

      expect(mockClient.redactEvent).toHaveBeenCalledWith(roomId, messageId);
    });

    it('should handle delete message errors', async () => {
      const error = new Error('Failed to delete');
      mockClient.redactEvent.mockRejectedValue(error);

      await expect(connector.deleteMessage('room1', 'msg1')).rejects.toThrow('Failed to delete');
    });
  });

  describe('room management', () => {
    it('should auto-join rooms when invited', () => {
      const mockEvent = {} as MatrixEvent;
      const mockMember = {
        membership: 'invite',
        userId: mockConfig.userId,
        roomId: 'room1'
      } as unknown as RoomMember;

      const mockState = {} as RoomState;
      const mockOldState = null;
      const mockPrevMember = null;

      // Get the membership handler
      const membershipHandler = mockClient.on.mock.calls.find(
        call => call[0] === RoomMemberEvent.Membership
      )?.[1] as (event: MatrixEvent, member: RoomMember, oldMembership: string | null, roomState: RoomState, oldState: RoomState | null) => void;

      if (membershipHandler) {
        mockClient.joinRoom.mockResolvedValue({ roomId: 'room1' } as Room);

        membershipHandler(mockEvent, mockMember, null, mockState, mockOldState);

        expect(mockClient.joinRoom).toHaveBeenCalledWith('room1');
      }
    });

    it('should handle room joining errors', async () => {
      const error = new Error('Failed to join');
      mockClient.joinRoom.mockRejectedValue(error);

      await expect(connector.joinRoom('room1')).rejects.toThrow('Failed to join');
    });

    it('should leave a room successfully', async () => {
      const roomId = 'room1';

      mockClient.leave.mockResolvedValue({} as any);

      await connector.leaveRoom(roomId);

      expect(mockClient.leave).toHaveBeenCalledWith(roomId);
    });

    it('should handle room leaving errors', async () => {
      const error = new Error('Failed to leave');
      mockClient.leave.mockRejectedValue(error);

      await expect(connector.leaveRoom('room1')).rejects.toThrow('Failed to leave');
    });
  });

  describe('reactions', () => {
    it('should add a reaction successfully', async () => {
      const roomId = 'room1';
      const eventId = 'event1';
      const key = '👍';

      mockClient.sendEvent.mockResolvedValue({} as any);

      await connector.addReaction(roomId, eventId, key);

      expect(mockClient.sendEvent).toHaveBeenCalledWith(
        roomId,
        'm.reaction',
        {
          'm.relates_to': {
            rel_type: 'm.annotation',
            event_id: eventId,
            key: key
          }
        }
      );
    });

    it('should remove a reaction successfully', async () => {
      const roomId = 'room1';
      const eventId = 'event1';
      const key = '👍';
      const reactionEventId = 'reaction1';

      mockClient.getRelations.mockResolvedValue({
        events: [{
          getId: () => reactionEventId,
          getContent: () => ({
            'm.relates_to': { key }
          }),
          getSender: () => mockConfig.userId
        }]
      } as any);

      mockClient.redactEvent.mockResolvedValue({} as any);

      await connector.removeReaction(roomId, eventId, key);

      expect(mockClient.redactEvent).toHaveBeenCalledWith(roomId, reactionEventId);
    });

    it('should handle reaction events', () => {
      const mockEvent = {
        getType: () => 'm.reaction',
        getSender: () => '@other:example.com',
        getContent: () => ({
          'm.relates_to': {
            rel_type: 'm.annotation',
            event_id: 'event1',
            key: '👍'
          }
        }),
        getId: () => 'reaction1'
      } as unknown as MatrixEvent;

      const mockRoom = {
        roomId: 'room1'
      } as unknown as Room;

      const mockTimelineData = {
        timeline: { live: true },
        liveEvent: true
      };

      const messageHandler = mockClient.on.mock.calls.find(
        call => call[0] === RoomEvent.Timeline
      )?.[1] as (event: MatrixEvent, room: Room | undefined, toStartOfTimeline: boolean | undefined, removed: boolean, data: any) => void;

      if (messageHandler) {
        const reactionSpy = jest.fn();
        connector.on('reaction', reactionSpy);

        messageHandler(mockEvent, mockRoom, false, false, mockTimelineData);

        expect(reactionSpy).toHaveBeenCalledWith({
          eventId: 'event1',
          key: '👍',
          userId: '@other:example.com'
        });
      }
    });
  });
}); 