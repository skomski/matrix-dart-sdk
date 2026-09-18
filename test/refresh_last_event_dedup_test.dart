// SPDX-FileCopyrightText: 2019-Present Famedly GmbH
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Room.refreshLastEvent() documents: "Multiple requests will be combined to the
// same request." It did not: the in-flight future was stored and then cleared
// on the very next *synchronous* statement, before it had completed, so the
// `??=` could never observe it and every caller started its own
// GET /rooms/{id}/messages.
//
// This matters because the SDK itself fires it unawaited from the sync loop
// (client.dart, `runInRoot(room.refreshLastEvent)`) on every JoinedRoomUpdate
// with a limited timeline, so duplicate refreshes are the normal case, not an
// exotic one.

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:test/test.dart';

import 'fake_database.dart';

class CountingApi extends FakeMatrixApi {
  int messagesRequests = 0;
  Duration delay = const Duration(milliseconds: 200);

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    if (request.url.path.endsWith('/messages')) {
      messagesRequests++;
      await Future.delayed(delay);
      return http.Response(
        '{"start": "s1", "end": "s0", "chunk": [], "state": []}',
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return super.mockIntercept(request);
  }
}

Future<Client> clientWith(CountingApi api) async {
  final client = Client(
    'testclient',
    httpClient: api,
    database: await getDatabase(),
  );
  FakeMatrixApi.client = client;
  await client.checkHomeserver(
    Uri.parse('https://fakeServer.notExisting'),
    checkWellKnown: false,
  );
  await client.init(
    newToken: 'abcd',
    newRefreshToken: 'refresh_abcd',
    newUserID: '@test:fakeServer.notExisting',
    newHomeserver: client.homeserver,
    newDeviceName: 'Text Matrix Client',
    newDeviceID: 'GHTYAJCE',
  );
  await Future.delayed(Duration(milliseconds: 50));
  await client.abortSync();
  return client;
}

void main() {
  group('Room.refreshLastEvent de-duplication', () {
    late CountingApi api;
    late Client client;
    late Room joinedRoom;

    setUp(() async {
      api = CountingApi();
      client = await clientWith(api);
      joinedRoom = client.rooms.firstWhere(
        (r) => r.membership == Membership.join,
      );
      api.messagesRequests = 0;
    });

    tearDown(() async {
      await client.dispose(closeDatabase: true);
    });

    test('concurrent callers share a single request', () async {
      // Three overlapping refreshes, exactly as the sync loop produces them.
      final futures = [
        joinedRoom.refreshLastEvent(),
        joinedRoom.refreshLastEvent(),
        joinedRoom.refreshLastEvent(),
      ];
      await Future.wait(futures);

      expect(
        api.messagesRequests,
        1,
        reason: 'the documented contract is that concurrent refreshes are '
            'combined into one request',
      );
    });

    test('a later refresh still issues a new request', () async {
      await joinedRoom.refreshLastEvent();
      final first = api.messagesRequests;
      await joinedRoom.refreshLastEvent();

      expect(
        api.messagesRequests,
        first + 1,
        reason: 'de-duplication must only apply while a refresh is in flight, '
            'otherwise the room would never refresh again',
      );
    });

    test('the timeout argument is forwarded to the request', () async {
      api.delay = const Duration(seconds: 2);

      await expectLater(
        joinedRoom.refreshLastEvent(timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
        reason: 'refreshLastEvent(timeout:) was accepted but never passed on',
      );
    });
  });
}
