// The live writes of MyGroupsService (#252): an own mail group named after
// the run ("dartschool test <run tag>"), made with create, renamed, its
// description changed and emptied with update, and deleted again with
// delete, against the live "Mijn groepen" of the account of
// credentials.yml. Each write is checked in the list of own groups after
// it; no other own group is changed.
//
// **Opt-in twice**: local and on demand only, as messages_live_test.dart
// (see there and dart_test.yaml), and only with
// DARTSCHOOL_LIVE_MY_GROUPS_WRITE=1 in the environment, since it writes in
// the account's own groups, which the compose form of Messages offers:
//
//   DARTSCHOOL_LIVE_MY_GROUPS_WRITE=1 \
//     dart test -P live test/live/my_groups_write_live_test.dart
//
// Without a credentials.yml in the package root, or without that variable,
// it skips.
//
// The library sends a save with `X-Requested-With`, as every form POST of
// the client; the live research of the issue sent it without. This run is
// what checks that Smartschool answers it with the same `302`.
//
// At the end, also when a test failed, it deletes every own group named
// after the run that the list still has, and checks that the other own
// groups are as they were at the start (IDs, names and descriptions).
// LiveWireGuard (support/live_wire_guard.dart) refuses on the wire any
// write of an own group that the run did not make, a name without the
// run's tag, a second create, and a delete or edit of the run's group once
// the last list no longer has it. As every live run, it takes the lock of
// the session first, logs in at most once, and prints no credential, no
// cookie and no name of another group.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';
import 'support/live_wire_guard.dart';

/// The variable that lets this file write in the own groups (#252).
const _optInVariable = 'DARTSCHOOL_LIVE_MY_GROUPS_WRITE';

/// [groups] as (ID, name, description), to compare.
List<(int, String, String)> _rows(Iterable<MyGroup> groups) => [
  for (final group in groups) (group.id, group.name, group.description),
];

void main() {
  final credentials = liveCredentialsFile();
  final optedIn = Platform.environment[_optInVariable]?.trim() == '1';

  group(
    'live, the own mail group of the run (#252):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : !optedIn
        ? 'creates, renames and deletes an own mail group of the account; '
              'set $_optInVariable=1 to run it'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      LiveRun? started;
      late LiveRun run;
      late MyGroupsService groups;

      /// The own groups at the start: the run changes none of them.
      late List<MyGroup> before;

      /// The name of the run's group.
      late String name;

      /// The run's group, once made.
      MyGroup? made;

      bool isRuns(MyGroup group) => group.name.startsWith(name);

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        groups = MyGroupsService(run.client);
        name = '$liveMyGroupPrefix ${run.tag}';
        before = await groups.list();
        if (before.any(isRuns)) {
          throw StateError('An own group is named after this run already.');
        }
        print('${before.length} own groups at the start');
      });

      tearDownAll(() async {
        try {
          final failures = <String>[];
          if (started != null) {
            // Every group named after the run that the list still has.
            for (final group in (await groups.list()).where(isRuns)) {
              try {
                await groups.delete(group);
              } on Object catch (e) {
                failures.add('$group: $e');
              }
            }
            final after = await groups.list();
            expect(after.where(isRuns), isEmpty, reason: 'left behind');
            expect(
              _rows(after),
              _rows(before),
              reason: 'the other own groups must be as they were',
            );
          }
          if (failures.isNotEmpty) {
            fail('Could not delete the run\'s group: ${failures.join('; ')}');
          }
        } finally {
          await started?.close();
        }
      });

      test('create: a blank name is refused before anything is sent', () async {
        final sent = run.guard.requestsSent;

        await expectLater(groups.create(name: '  '), throwsArgumentError);

        expect(run.guard.requestsSent, sent);
      });

      test('create: the group, as the list shows it after the save', () async {
        final group = made = await groups.create(
          name: name,
          description: 'dartschool test & "beschrijving" é',
        );

        expect(group.name, name);
        expect(group.description, 'dartschool test & "beschrijving" é');
        expect(run.guard.myGroupCreates, 1);
        final listed = (await groups.list()).where((g) => g.id == group.id);
        expect(_rows(listed), _rows([group]));
        print('made $group');
      });

      test('create: the name of the run\'s group again is refused once the '
          'list was read; nothing is saved', () async {
        if (made == null) {
          markTestSkipped('the group was not made');
          return;
        }

        await expectLater(groups.create(name: name), throwsArgumentError);

        expect(run.guard.myGroupCreates, 1);
      });

      test('update: a new name keeps the description; a new description '
          'keeps the name; an empty one empties it', () async {
        var group = made;
        if (group == null) {
          markTestSkipped('the group was not made');
          return;
        }

        group = made = await groups.update(group, name: '$name hernoemd');
        expect(group.name, '$name hernoemd');
        expect(group.description, 'dartschool test & "beschrijving" é');

        group = made = await groups.update(
          group,
          description: 'gewijzigd <b>vet</b>',
        );
        expect(group.name, '$name hernoemd');
        expect(group.description, 'gewijzigd vet', reason: 'tags stripped');

        group = made = await groups.update(group, description: '');
        expect(group.description, '');
        final listed = (await groups.list()).where((g) => g.id == group!.id);
        expect(_rows(listed), _rows([group]));
      });

      test('findRecipient: the compose search finds the renamed group by its '
          'name, with its ID', () async {
        final group = made;
        if (group == null) {
          markTestSkipped('the group was not made');
          return;
        }

        final found = await groups.findRecipient(group);

        expect(found, isNotNull);
        expect(found!.groupId, group.id);
      });

      test('delete: the list no longer has the group; a second delete is a '
          'SmartschoolMyGroupNotFoundError, before anything is sent', () async {
        final group = made;
        if (group == null) {
          markTestSkipped('the group was not made');
          return;
        }

        await groups.delete(group);

        expect(
          (await groups.list()).map((g) => g.id),
          isNot(contains(group.id)),
        );
        await expectLater(
          groups.delete(group),
          throwsA(
            isA<SmartschoolMyGroupNotFoundError>().having(
              (e) => e.groupId,
              'groupId',
              group.id,
            ),
          ),
        );
        made = null;
      });
    },
  );
}
