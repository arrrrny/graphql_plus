import 'package:gql/language.dart';
import 'package:graphql_plus/graphql_plus.dart';
import 'package:test/test.dart';

const mutationDocument =
    r'mutation AddTodo($text: String!) { addTodo(text: $text) { id text } }';
const otherMutationDocument =
    r'mutation RemoveTodo($id: ID!) { removeTodo(id: $id) { id } }';

Request mutationRequest({
  String document = mutationDocument,
  String? operationName,
  Map<String, dynamic> variables = const <String, dynamic>{},
}) =>
    Request(
      operation: Operation(
        document: parseString(document),
        operationName: operationName,
      ),
      variables: variables,
    );

void main() {
  group('OfflineMutationQueue', () {
    test('enqueues mutations in FIFO order with unique ids', () async {
      final queue = OfflineMutationQueue();

      final first = await queue.enqueue(mutationRequest());
      final second = await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'b'}),
      );

      expect(first, isNot(second));
      expect(queue.pending.map((entry) => entry.id).toList(), [first, second]);
      expect(queue.length, 2);
      expect(queue.isEmpty, isFalse);
      expect(queue.head?.id, first);
    });

    test('an empty queue has no head', () {
      final queue = OfflineMutationQueue();

      expect(queue.isEmpty, isTrue);
      expect(queue.length, 0);
      expect(queue.head, isNull);
      expect(queue.pending, isEmpty);
    });

    test('deduplicates an identical payload', () async {
      final queue = OfflineMutationQueue();

      final first = await queue.enqueue(mutationRequest());
      final second = await queue.enqueue(mutationRequest());

      expect(second, first);
      expect(queue.length, 1);
    });

    test('keeps mutations whose variables differ', () async {
      final queue = OfflineMutationQueue();

      final first = await queue.enqueue(mutationRequest());
      final second = await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'other'}),
      );

      expect(second, isNot(first));
      expect(queue.length, 2);
    });

    test('deduplicate false keeps identical payloads apart', () async {
      final queue = OfflineMutationQueue(deduplicate: false);

      final first = await queue.enqueue(mutationRequest());
      final second = await queue.enqueue(mutationRequest());

      expect(second, isNot(first));
      expect(queue.length, 2);
    });

    test('a caller supplied idempotency key is used verbatim', () async {
      final queue = OfflineMutationQueue();

      final id = await queue.enqueue(
        mutationRequest(),
        idempotencyKey: 'server-supplied-key',
      );

      expect(queue.head?.id, id);
      expect(queue.head?.idempotencyKey, 'server-supplied-key');
    });

    test('asRequest rebuilds the payload and carries the idempotency key',
        () async {
      final queue = OfflineMutationQueue();
      await queue.enqueue(mutationRequest(
        variables: <String, dynamic>{'text': 'hello'},
      ));
      final entry = queue.head!;

      final request = entry.asRequest;

      expect(request.variables, <String, dynamic>{'text': 'hello'});
      expect(request.operation.operationName, isNull);
      expect(
        printNode(request.operation.document),
        contains('addTodo'),
      );
      expect(
        request.context.entry<OfflineIdempotencyKey>()?.key,
        entry.idempotencyKey,
      );
    });

    test('serializes to JSON and back without losing the payload', () async {
      final queue = OfflineMutationQueue();
      final id = await queue.enqueue(mutationRequest(
        document: otherMutationDocument,
        operationName: 'RemoveTodo',
        variables: <String, dynamic>{'id': '7'},
      ));
      final entry = queue.head!;

      final restored = QueuedMutation.fromJson(entry.toJson());

      expect(restored.id, id);
      expect(restored.document, entry.document);
      expect(restored.operationName, 'RemoveTodo');
      expect(restored.variables, <String, dynamic>{'id': '7'});
      expect(restored.idempotencyKey, entry.idempotencyKey);
      expect(restored.createdAt, entry.createdAt);
      expect(restored.attempts, 0);
      expect(restored.lastError, isNull);
      expect(restored.asRequest.variables, <String, dynamic>{'id': '7'});
    });

    test('entries survive a store round trip', () async {
      final store = InMemoryMutationQueueStore();
      final queue = OfflineMutationQueue(store: store);
      final first = await queue.enqueue(mutationRequest());
      final second = await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'b'}),
      );

      final reopened = OfflineMutationQueue(store: store);

      expect(
          reopened.pending.map((entry) => entry.id).toList(), [first, second]);
      expect(reopened.head?.variables, isEmpty);
      expect(reopened.pending.last.variables, <String, dynamic>{'text': 'b'});
    });

    test('a delivered entry is gone from a reopened queue', () async {
      final store = InMemoryMutationQueueStore();
      final queue = OfflineMutationQueue(store: store);
      await queue.enqueue(mutationRequest());

      await queue.flush((_) async {});
      final reopened = OfflineMutationQueue(store: store);

      expect(reopened.isEmpty, isTrue);
      expect(store.read(), isEmpty);
    });

    test('the dedup key is restored with the entry', () async {
      final store = InMemoryMutationQueueStore();
      final first = OfflineMutationQueue(store: store);
      final id = await first.enqueue(mutationRequest());
      final key = first.head!.idempotencyKey;

      final second = OfflineMutationQueue(store: store);
      final duplicate = await second.enqueue(mutationRequest());

      expect(duplicate, id);
      expect(second.head?.idempotencyKey, key);
      expect(second.length, 1);
    });

    test('flush drains the queue in order when nothing fails', () async {
      final queue = OfflineMutationQueue();
      final a = await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'a'}),
      );
      final b = await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'b'}),
      );

      final sent = <String>[];
      final delivered = await queue.flush((entry) async {
        sent.add(entry.variables['text'] as String);
      });

      expect(sent, ['a', 'b']);
      expect(delivered, 2);
      expect(queue.isEmpty, isTrue);
      expect(b, isNot(a));
    });

    test('flush stops at the first failure and keeps that entry at the head',
        () async {
      final queue = OfflineMutationQueue();
      final a = await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'a'}),
      );
      final b = await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'b'}),
      );
      final c = await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'c'}),
      );

      final sent = <String>[];
      final delivered = await queue.flush((entry) async {
        sent.add(entry.variables['text'] as String);
        if (entry.variables['text'] == 'b') {
          throw StateError('transport down');
        }
      });

      expect(sent, ['a', 'b']);
      expect(delivered, 1);
      expect(queue.pending.map((entry) => entry.id).toList(), [b, c]);
      expect(queue.head?.id, b);
      expect(a, isNot(b));
      expect(queue.head?.attempts, 1);
      expect(queue.head?.lastError, contains('transport down'));
    });

    test('a second flush retries the failed head', () async {
      final queue = OfflineMutationQueue();
      await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'a'}),
      );
      var fail = true;
      await queue.flush((_) async {
        if (fail) throw StateError('transport down');
      });

      fail = false;
      final delivered = await queue.flush((_) async {});

      expect(delivered, 1);
      expect(queue.isEmpty, isTrue);
    });

    test('flush on an empty queue sends nothing', () async {
      final queue = OfflineMutationQueue();
      var calls = 0;

      final delivered = await queue.flush((_) async => calls++);

      expect(delivered, 0);
      expect(calls, 0);
    });

    test('remove drops one entry and keeps the rest in order', () async {
      final queue = OfflineMutationQueue();
      final a = await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'a'}),
      );
      await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'b'}),
      );

      expect(await queue.remove(a), isTrue);
      expect(queue.length, 1);
      expect(queue.head?.variables, <String, dynamic>{'text': 'b'});
      expect(await queue.remove(a), isFalse);
    });

    test('clear empties the queue and its store', () async {
      final store = InMemoryMutationQueueStore();
      final queue = OfflineMutationQueue(store: store);
      await queue.enqueue(mutationRequest());

      await queue.clear();

      expect(queue.isEmpty, isTrue);
      expect(store.read(), isEmpty);
    });

    test('a full queue refuses a new entry', () async {
      final queue = OfflineMutationQueue(maxEntries: 2);
      await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'a'}),
      );
      await queue.enqueue(
        mutationRequest(variables: <String, dynamic>{'text': 'b'}),
      );

      await expectLater(
        queue.enqueue(
          mutationRequest(variables: <String, dynamic>{'text': 'c'}),
        ),
        throwsA(isA<MutationQueueFullException>()),
      );
      expect(queue.length, 2);
    });

    test(
        'a duplicate of a queued entry is accepted even when the queue is full',
        () async {
      final queue = OfflineMutationQueue(maxEntries: 1);
      final first = await queue.enqueue(mutationRequest());

      final duplicate = await queue.enqueue(mutationRequest());

      expect(duplicate, first);
      expect(queue.length, 1);
    });
  });

  group('offlineIdempotencyKeyFor', () {
    test('is stable across runs and independent of variable order', () {
      final a = offlineIdempotencyKeyFor(
        document: mutationDocument,
        variables: <String, dynamic>{'text': 'x', 'n': 2},
      );
      final b = offlineIdempotencyKeyFor(
        document: mutationDocument,
        variables: <String, dynamic>{'n': 2, 'text': 'x'},
      );
      final c = offlineIdempotencyKeyFor(
        document: mutationDocument,
        variables: <String, dynamic>{'text': 'y', 'n': 2},
      );
      final d = offlineIdempotencyKeyFor(
        document: otherMutationDocument,
        variables: <String, dynamic>{'text': 'x', 'n': 2},
      );

      expect(a, b);
      expect(a, isNot(c));
      expect(a, isNot(d));
    });

    test('separates operations by name inside one document', () {
      final a = offlineIdempotencyKeyFor(
        document: 'mutation A { a } mutation B { b }',
        operationName: 'A',
      );
      final b = offlineIdempotencyKeyFor(
        document: 'mutation A { a } mutation B { b }',
        operationName: 'B',
      );

      expect(a, isNot(b));
    });
  });
}
