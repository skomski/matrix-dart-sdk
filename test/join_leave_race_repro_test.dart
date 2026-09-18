// SPDX-FileCopyrightText: 2019-Present Famedly GmbH
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Reproduction tests for: "client leaves a room ~150ms after joining it, while
// the join request is still in flight".
//
// Observed in production on 2026-09-15: a client issued
//   POST /rooms/!x/join   at t+0ms    -> 200 (0.471s)
//   POST /rooms/!x/leave  at t+150ms  -> 200
// i.e. the leave was on the wire 321ms *before* the join response came back.
// The room was then un-joinable history-wise: the remote server refused
// /backfill with 403 because the requesting server was no longer a member.
//
// These tests pin down which half of that is the SDK's doing:
//   1. a successful join must never leave                      (control)
//   2. an UNRECOGNISED errcode must NOT leave                  (regression)
//   2a. a literal M_UNKNOWN still leaves (synapse#1533)        (workaround)
//   3. an error body without an errcode must NOT leave         (boundary)
//
// The production shape itself -- a leave issued while the join is still in
// flight -- is app-layer behaviour, not SDK behaviour, and is deliberately not
// asserted here: it could only be tested against wall-clock timing.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:test/test.dart';

import 'fake_database.dart';

/// Records which join/leave requests reach the server, and lets each test
/// decide what the join endpoint answers.
class JoinLeaveApi extends FakeMatrixApi {
  final List<({String method, String path})> issued = [];

  int joinStatus = 200;
  String joinBody = '{"room_id": "!696r7674:example.com"}';

  bool get sentJoin => issued.any((e) => e.path.endsWith('/join'));
  bool get sentLeave => issued.any((e) => e.path.endsWith('/leave'));

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    final isJoin = path.endsWith('/join') && path.contains('/rooms/');
    final isLeave = path.endsWith('/leave') && path.contains('/rooms/');

    if (isJoin || isLeave) {
      issued.add((method: request.method, path: path));
    }

    if (isJoin) {
      return http.Response(
        joinBody,
        joinStatus,
        headers: {'content-type': 'application/json'},
      );
    }
    if (isLeave) {
      return http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return super.mockIntercept(request);
  }
}

Future<Client> clientWith(JoinLeaveApi api) async {
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
  group('join/leave race repro', () {
    late JoinLeaveApi api;
    late Client client;
    late Room invitedRoom;

    setUp(() async {
      api = JoinLeaveApi();
      client = await clientWith(api);
      invitedRoom = client.rooms.singleWhere(
        (r) => r.membership == Membership.invite,
      );
      api.joinBody = jsonEncode({'room_id': invitedRoom.id});
      api.issued.clear();
    });

    tearDown(() async {
      await client.dispose(closeDatabase: true);
    });

    test('1. control: a successful join never leaves', () async {
      api.joinStatus = 200;

      await invitedRoom.join();

      expect(api.sentJoin, isTrue, reason: 'join should have been sent');
      expect(
        api.sentLeave,
        isFalse,
        reason: 'a 200 join must never trigger an implicit leave',
      );
    });

    test(
      '2. an UNRECOGNISED errcode must not leave the room',
      () async {
        // M_CONSENT_NOT_GIVEN is absent from MatrixError, so
        // `exception.error` collapses it to M_UNKNOWN. Before the fix this
        // silently left the room instead of surfacing "accept the terms".
        // Reachable on this exact endpoint: handlers/room_member.py calls
        // EventCreationHandler.create_event, which runs
        // assert_accepted_privacy_policy unless the event is exempt, and
        // _is_exempt_from_privacy_policy exempts a JOIN only for the server
        // notices room. Verified on Synapse 1.159.0.
        api.joinStatus = 403;
        api.joinBody = jsonEncode({
          'errcode': 'M_CONSENT_NOT_GIVEN',
          'error': 'Please accept the privacy policy',
        });

        await expectLater(invitedRoom.join(), throwsA(isA<MatrixException>()));

        expect(
          api.sentLeave,
          isFalse,
          reason: 'an errcode the SDK does not know about must not be treated '
              'as "room not found"',
        );
      },
    );

    test(
      '2a. the synapse#1533 workaround still fires for a literal M_UNKNOWN',
      () async {
        // This is what Synapse actually returns when the room is orphaned:
        // verified on Synapse 1.159.0 --
        // federation_client.py: SynapseError(502, 'Failed to make_join via
        // any server') with the default errcode Codes.UNKNOWN = 'M_UNKNOWN'.
        api.joinStatus = 502;
        api.joinBody = jsonEncode({
          'errcode': 'M_UNKNOWN',
          'error': 'Failed to make_join via any server',
        });

        await expectLater(invitedRoom.join(), throwsA(isA<MatrixException>()));

        expect(
          api.sentLeave,
          isTrue,
          reason: 'the orphaned-room workaround must be preserved',
        );
      },
    );

    test('2c. contrast: a RECOGNISED errcode does not leave', () async {
      // Same status, same shape -- only the errcode is one the enum knows.
      api.joinStatus = 400;
      api.joinBody = jsonEncode({
        'errcode': 'M_FORBIDDEN',
        'error': 'You are not invited to this room',
      });

      await expectLater(invitedRoom.join(), throwsA(isA<MatrixException>()));

      expect(
        api.sentLeave,
        isFalse,
        reason: 'it is specifically the UNRECOGNISED errcode that triggers the '
            'leave, not the error itself',
      );
    });

    test('2b. the mapping itself: unknown errcode -> M_UNKNOWN', () {
      final e = MatrixException.fromJson({
        'errcode': 'M_CONSENT_NOT_GIVEN',
        'error': 'nope',
      });
      expect(e.errcode, 'M_CONSENT_NOT_GIVEN');
      expect(
        e.error,
        MatrixError.M_UNKNOWN,
        reason: 'firstWhere(orElse: M_UNKNOWN) erases the distinction between '
            '"unknown error" and "room not found"',
      );
    });

    test('3. boundary: an error body without an errcode must NOT leave',
        () async {
      // e.g. an ingress/gateway error page, or any non-Matrix error body.
      api.joinStatus = 502;
      api.joinBody = '<html><body>502 Bad Gateway</body></html>';

      await expectLater(invitedRoom.join(), throwsA(isA<Exception>()));

      expect(
        api.sentLeave,
        isFalse,
        reason: 'unexpectedResponse only throws MatrixException when the body '
            'carries errcode/session/flows; otherwise it is a plain Exception '
            'that `on MatrixException` does not catch',
      );
    });
  });
}
