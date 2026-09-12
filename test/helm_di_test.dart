import 'package:helm_di/helm_di.dart';
import 'package:test/test.dart';

/// These small types make the lifetime and cycle tests read as an application
/// graph instead of a collection of primitives.
final class const _Config(final String name);
final class const _Client(final _Config config);
final class const _Session(final int id);
final class const _CycleA(final _CycleB bb);
final class const _CycleB(final _CycleA a);

void main() {
  group('registration and lookup', () {
    test('factory creates a distinct caller-owned object every time', () {
      final di = HelmDi()..registerFactory<_Session>((_) => _Session(1));

      expect(identical(di.get<_Session>(), di.get<_Session>()), isFalse);
    });

    test('lazy singleton creates exactly once and is disposed once', () async {
      final di = HelmDi();
      var creations = 0;
      var disposals = 0;
      di.registerLazySingleton<String>(
        (_) => 'value-${++creations}',
        dispose: syncDisposer((_) => disposals++),
      );

      expect(di.get<String>(), 'value-1');
      expect(di.get<String>(), 'value-1');
      expect(creations, 1);
      await di.dispose();
      expect(disposals, 1);
    });

    test('named keys allow multiple implementations of one type', () {
      const primary = ServiceKey<String>('primary');
      const replica = ServiceKey<String>('replica');
      final di = HelmDi()
        ..registerSingleton<String>('one', key: primary)
        ..registerSingleton<String>('two', key: replica);

      expect(di.get<String>(key: primary), 'one');
      expect(di.get<String>(key: replica), 'two');
      expect(di.isRegistered<String>(key: primary), isTrue);
      expect(di.isRegistered<String>(), isFalse);
    });

    test('missing and duplicate registrations fail explicitly', () {
      final di = HelmDi()..registerSingleton<int>(1);

      expect(
        () => di.registerSingleton<int>(2),
        throwsA(isA<DuplicateRegistrationException>()),
      );
      expect(
        () => di.get<String>(),
        throwsA(isA<DependencyNotFoundException>()),
      );
    });
  });

  group('scope ownership', () {
    test('child scopes can override a parent registration', () async {
      final root = HelmDi()..registerSingleton<_Config>(const _Config('root'));
      final child = await root.createScope(
        (scope) async =>
            scope.registerSingleton<_Config>(const _Config('child')),
      );

      expect(child.get<_Config>().name, 'child');
      expect(root.get<_Config>().name, 'root');
      await child.dispose();
      await root.dispose();
    });

    test('parent singleton stays owned by parent after child lookup', () async {
      var disposals = 0;
      final root = HelmDi()
        ..registerLazySingleton<_Session>(
          (_) => _Session(1),
          dispose: syncDisposer((_) => disposals++),
        );
      final child = await root.createScope((_) async {});

      child.get<_Session>();
      await child.dispose();
      expect(disposals, 0);
      await root.dispose();
      expect(disposals, 1);
    });

    test(
      'scoped values are isolated and disposed by each resolving scope',
      () async {
        var nextId = 0;
        final disposed = <int>[];
        final root = HelmDi()
          ..registerScoped<_Session>(
            (_) => _Session(++nextId),
            dispose: syncDisposer((session) => disposed.add(session.id)),
          );
        final first = await root.createScope((_) async {});
        final second = await root.createScope((_) async {});

        expect(first.get<_Session>().id, 1);
        expect(first.get<_Session>().id, 1);
        expect(second.get<_Session>().id, 2);
        await first.dispose();
        expect(disposed, [1]);
        await second.dispose();
        expect(disposed, [1, 2]);
        await root.dispose();
      },
    );

    test('singleton factories resolve from their owner scope', () async {
      final root = HelmDi()
        ..registerSingleton<_Config>(const _Config('root'))
        ..registerLazySingleton<_Client>((di) => _Client(di.get<_Config>()));
      final child = await root.createScope(
        (scope) async =>
            scope.registerSingleton<_Config>(const _Config('child')),
      );

      expect(child.get<_Client>().config.name, 'root');
    });

    test(
      'scoped factories resolve through the requesting child scope',
      () async {
        final root = HelmDi()
          ..registerSingleton<_Config>(const _Config('root'))
          ..registerScoped<_Client>((di) => _Client(di.get<_Config>()));
        final child = await root.createScope(
          (scope) async =>
              scope.registerSingleton<_Config>(const _Config('child')),
        );

        expect(child.get<_Client>().config.name, 'child');
      },
    );

    test('factory resolution also sees a child override', () async {
      final root = HelmDi()
        ..registerSingleton<_Config>(const _Config('root'))
        ..registerFactory<_Client>((di) => _Client(di.get<_Config>()));
      final child = await root.createScope(
        (scope) async =>
            scope.registerSingleton<_Config>(const _Config('child')),
      );

      expect(child.get<_Client>().config.name, 'child');
    });
  });

  group('container safety and disposal', () {
    test('sealed scopes reject late registrations', () {
      final di = HelmDi()..seal();
      expect(
        () => di.registerSingleton<int>(1),
        throwsA(isA<ContainerSealedException>()),
      );
    });

    test('createScope seals its configured child', () async {
      final child = await HelmDi().createScope((_) async {});
      expect(
        () => child.registerSingleton<int>(1),
        throwsA(isA<ContainerSealedException>()),
      );
    });

    test('a scope cannot mutate its graph after its first lookup', () {
      final di = HelmDi()..registerSingleton<int>(1);

      expect(di.get<int>(), 1);
      expect(
        () => di.registerSingleton<String>('late'),
        throwsA(isA<ContainerResolutionStartedException>()),
      );
    });

    test(
      'failed scope configuration disposes created child resources',
      () async {
        var disposals = 0;
        final root = HelmDi();

        await expectLater(
          root.createScope((scope) async {
            scope.registerSingleton<_Session>(
              _Session(1),
              dispose: syncDisposer((_) => disposals++),
            );
            throw StateError('configuration failed');
          }),
          throwsA(isA<StateError>()),
        );
        expect(disposals, 1);
        await root.dispose();
      },
    );

    test(
      'parent disposal closes active child scopes before own resources',
      () async {
        final calls = <String>[];
        final root = HelmDi()
          ..registerSingleton<String>('root', dispose: syncDisposer(calls.add));
        final child = await root.createScope((scope) async {
          scope.registerSingleton<String>(
            'child',
            key: const ServiceKey<String>('child'),
            dispose: syncDisposer(calls.add),
          );
        });

        await root.dispose();
        expect(calls, ['child', 'root']);
        expect(
          () => child.get<String>(),
          throwsA(isA<ContainerDisposedException>()),
        );
      },
    );

    test('a child cannot resolve from a parent that is disposing', () async {
      final root = HelmDi()..registerSingleton<int>(1);
      final child = await root.createScope((_) async {});

      await root.dispose();
      expect(
        () => child.get<int>(),
        throwsA(isA<ContainerDisposedException>()),
      );
      await child.dispose();
    });

    test('circular factories report the full cycle', () {
      final di = HelmDi()
        ..registerLazySingleton<_CycleA>((di) => _CycleA(di.get<_CycleB>()))
        ..registerLazySingleton<_CycleB>((di) => _CycleB(di.get<_CycleA>()));

      expect(
        () => di.get<_CycleA>(),
        throwsA(isA<CircularDependencyException>()),
      );
    });

    test(
      'disposal is reverse-order, asynchronous, and continues after errors',
      () async {
        final calls = <String>[];
        final di = HelmDi()
          ..registerSingleton<String>(
            'first',
            dispose: syncDisposer((value) => calls.add(value)),
          )
          ..registerSingleton<int>(
            2,
            dispose: (value) async {
              calls.add('$value');
              throw StateError('expected test failure');
            },
          )
          ..registerSingleton<bool>(
            true,
            dispose: syncDisposer((value) => calls.add('$value')),
          );

        await expectLater(di.dispose(), throwsA(isA<StateError>()));
        expect(calls, ['true', '2', 'first']);
      },
    );

    test('disposal is idempotent and blocks later use', () async {
      final di = HelmDi()..registerSingleton<int>(1);
      final first = di.dispose();
      final second = di.dispose();

      expect(identical(first, second), isTrue);
      await first;
      expect(() => di.get<int>(), throwsA(isA<ContainerDisposedException>()));
    });
  });
}
