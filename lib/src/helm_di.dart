import 'dart:async';

import 'contracts.dart';
import 'errors.dart';

part 'registration.dart';

/// A pure-Dart container for an application's composition root.
///
/// The class has two deliberate boundaries: registrations happen during
/// bootstrap and are frozen by [seal]; lookups are allowed only from active
/// scopes. This prevents a late runtime mutation from silently changing which
/// implementation production code receives.
final class HelmDi {
  /// Creates an independent container.
  ///
  /// Prefer this constructor for tests, isolated application graphs, and
  /// temporary composition roots. It never reads or mutates [HelmDi.app].
  new() : _parent = null;

  new _(this._parent);

  /// Returns the process-wide application container for the current isolate.
  ///
  /// This is opt-in convenience for application entry points that have one
  /// composition root. It deliberately has a named constructor so [HelmDi()]
  /// remains suitable for tests and multiple independent graphs. Configure
  /// this container exactly once, call [seal], then dispose it on shutdown.
  ///
  /// Static state is isolate-local: another Dart isolate receives its own
  /// application container.
  factory app() => _application ??= HelmDi();

  /// A concise, idiomatic alias for [HelmDi.app].
  ///
  /// Prefer [HelmDi.app] in bootstrap code when making application ownership
  /// explicit improves readability. [instance] is useful at integration
  /// entry points that only need the already configured container.
  static HelmDi get instance => HelmDi.app();

  /// Short alias for [HelmDi.app] used by projects that adopt the `DI.I`
  /// access convention.
  static HelmDi get I => HelmDi.app();

  static HelmDi? _application;

  /// Disposes and clears the application container.
  ///
  /// This hook exists exclusively to isolate tests which use [HelmDi.app].
  /// Application code should dispose the container it bootstrapped directly;
  /// replacing a live application graph at runtime makes ownership ambiguous.
  static Future<void> resetApplicationForTest() async {
    final application = _application;
    _application = null;
    if (application != null) await application.dispose();
  }

  static final Object _resolutionZoneKey = Object();

  ///
  final HelmDi? _parent;
  final _registrations = <_ServiceId, _Registration>{};
  final _instances = <_ServiceId, _OwnedInstance>{};
  final _creationOrder = <_ServiceId>[];
  final _children = <HelmDi>[];

  ///
  bool _sealed = false;
  bool _resolutionStarted = false;
  bool _disposing = false;
  Future<void>? _disposeFuture;

  /// Freezes registrations in this scope. Calling it more than once is safe.
  ///
  /// Seal the root after composition, and seal child scopes after installing
  /// request, route, or test overrides.
  void seal() {
    _ensureActive();
    _sealed = true;
  }

  /// Creates a mutable child scope that can read parent registrations.
  ///
  /// The caller owns it and must later `await scope.dispose()`. Prefer
  /// [createScope] when an immediately sealed scope is appropriate.
  HelmDi scope() {
    _ensureActive();
    final child = HelmDi._(this);
    _children.add(child);
    return child;
  }

  /// Creates, configures, and seals a child scope as an async transaction.
  ///
  /// If [configure] or sealing fails, every resource already owned by the
  /// child is disposed before the original failure is rethrown. The callback
  /// intentionally returns `Future<void>` even for synchronous setup (`async
  /// { ... }`): one lifecycle contract prevents partial cleanup from escaping
  /// when setup later gains asynchronous work.
  Future<HelmDi> createScope(
    Future<void> Function(HelmDi scope) configure,
  ) async {
    final child = scope();
    try {
      await configure(child);
      child.seal();
      return child;
    } catch (error, stackTrace) {
      try {
        await child.dispose();
      } catch (_) {
        // The configuration failure is the primary cause. Child disposal
        // still runs to completion and is observable through its resources.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Registers an eagerly-created singleton owned by this scope.
  ///
  /// The instance is already created, so it is stored directly via
  /// [_storeOwnedInstance] and [_getOrCreate] never runs for it; the
  /// registration itself therefore carries no [dispose] of its own,
  /// keeping the single disposer below the only source of truth for how
  /// this instance is torn down.
  void registerSingleton<T>(
    T instance, {
    ServiceKey<T>? key,
    DependencyDisposer<T>? dispose,
  }) {
    final id = _id<T>(key);
    _register<T>(id, lifetime: .singleton, factory: (_) => instance);
    _storeOwnedInstance(id, instance, () async {
      if (dispose != null) await dispose(instance);
    });
  }

  /// Registers a lazy singleton owned by this scope.
  void registerLazySingleton<T>(
    DependencyFactory<T> factory, {
    ServiceKey<T>? key,
    DependencyDisposer<T>? dispose,
  }) => _register<T>(
    _id<T>(key),
    lifetime: .singleton,
    factory: factory,
    dispose: dispose,
  );

  /// Registers one cached object per resolving scope.
  ///
  /// A root registration resolved from two child scopes yields two objects;
  /// each child disposes only its own object. This is useful for route or
  /// request state, while app-wide clients generally use a singleton.
  void registerScoped<T>(
    DependencyFactory<T> factory, {
    ServiceKey<T>? key,
    DependencyDisposer<T>? dispose,
  }) => _register<T>(
    _id<T>(key),
    lifetime: .scoped,
    factory: factory,
    dispose: dispose,
  );

  /// Registers a fresh object factory. Factory products are caller-owned and
  /// never disposed by the container.
  void registerFactory<T>(DependencyFactory<T> factory, {ServiceKey<T>? key}) =>
      _register<T>(_id<T>(key), lifetime: .factory, factory: factory);

  /// Resolves [T] from this scope, then its parents.
  ///
  /// Named registrations use the same [ServiceKey] for registration and
  /// lookup. A cycle is reported with a readable path instead of overflowing
  /// the stack.
  T get<T>({ServiceKey<T>? key}) {
    _ensureActive();
    _resolutionStarted = true;
    final context = Zone.current[_resolutionZoneKey] as _ResolutionContext?;
    if (context != null) return _resolve<T>(_id<T>(key), context);

    final newContext = _ResolutionContext();
    try {
      return runZoned(
        () => _resolve<T>(_id<T>(key), newContext),
        zoneValues: {_resolutionZoneKey: newContext},
      );
    } finally {
      // By the time this outer get() returns, every entered node has been
      // left (see _create's try/finally), so the path is empty here. Any
      // later call to enter() on this context can only come from a
      // callback that escaped synchronous execution.
      newContext._closed = true;
    }
  }

  /// Returns `true` when this scope or an ancestor has a matching service.
  /// This is a query only and never creates a lazy singleton or scoped value.
  bool isRegistered<T>({ServiceKey<T>? key}) {
    _ensureActive();
    return _locate(_id<T>(key)) != null;
  }

  /// Asynchronously disposes all locally owned resources in reverse creation
  /// order. It is idempotent and waits for an in-progress disposal if called
  /// again. Disposing a parent first disposes all still-active child scopes.
  Future<void> dispose() {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposing = true;
    return _disposeFuture = _dispose();
  }

  Future<void> _dispose() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final child in _children.toList(growable: false).reversed) {
      try {
        await child.dispose();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _children.clear();
    for (final id in _creationOrder.reversed) {
      final instance = _instances[id];
      if (instance == null) continue;
      try {
        await instance.dispose();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _instances.clear();
    _creationOrder.clear();
    _registrations.clear();
    _parent?._removeChild(this);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  T _resolve<T>(_ServiceId id, _ResolutionContext context) {
    final located = _locate(id);
    if (located == null) throw DependencyNotFoundException('$id');
    // No need to re-check located.owner here: get<T> already called
    // _ensureActive() on `this`, which recurses through every ancestor up
    // to the root, and owner is always `this` or one of those ancestors.

    final registration = located.registration;
    return switch (registration.lifetime) {
      .factory => _create<T>(this, id, registration, context),
      .singleton => located.owner._getOrCreate<T>(
        id,
        registration,
        located.owner,
        context,
      ),
      .scoped => _getOrCreate<T>(id, registration, this, context),
    };
  }

  T _getOrCreate<T>(
    _ServiceId id,
    _Registration registration,
    HelmDi resolver,
    _ResolutionContext context,
  ) {
    final existing = _instances[id];
    if (existing != null) return existing.value as T;
    final value = _create<T>(resolver, id, registration, context);
    _storeOwnedInstance(id, value, () async {
      final dispose = registration.dispose;
      if (dispose != null) await dispose(value);
    });
    return value;
  }

  T _create<T>(
    HelmDi resolver,
    _ServiceId id,
    _Registration registration,
    _ResolutionContext context,
  ) {
    final node = _ResolutionNode(this, id);
    context.enter(node);
    try {
      return registration.factory(resolver) as T;
    } finally {
      context.leave(node);
    }
  }

  void _register<T>(
    _ServiceId id, {
    required ServiceLifetime lifetime,
    required DependencyFactory<T> factory,
    DependencyDisposer<T>? dispose,
  }) {
    _ensureActive();
    if (_sealed) throw const ContainerSealedException();
    if (_resolutionStarted) throw const ContainerResolutionStartedException();
    if (_registrations.containsKey(id)) {
      throw DuplicateRegistrationException('$id');
    }
    _registrations[id] = _Registration(
      lifetime: lifetime,
      factory: (di) => factory(di),
      dispose: dispose == null ? null : (value) => dispose(value as T),
    );
  }

  void _storeOwnedInstance(
    _ServiceId id,
    Object? value,
    Future<void> Function() dispose,
  ) {
    _instances[id] = _OwnedInstance(value, dispose);
    _creationOrder.add(id);
  }

  _LocatedRegistration? _locate(_ServiceId id) {
    final local = _registrations[id];
    if (local != null) return _LocatedRegistration(this, local);
    return _parent?._locate(id);
  }

  _ServiceId _id<T>(ServiceKey<T>? key) => _ServiceId(T, key?.name);

  void _removeChild(HelmDi child) => _children.remove(child);

  void _ensureActive() {
    if (_disposing) throw const ContainerDisposedException();
    // A child borrows its registration graph from every ancestor. Keeping it
    // usable after an ancestor's teardown would permit use-after-dispose of
    // app-wide clients, so parent disposal invalidates the complete subtree.
    _parent?._ensureActive();
  }
}

/// Registration plus the scope that owns its singleton lifetime.
final class const _LocatedRegistration(
  final HelmDi owner,
  final _Registration registration,
);

/// A resolution path carried through a synchronous [Zone].
final class _ResolutionContext {
  final _path = <_ResolutionNode>[];

  /// Set once the [HelmDi.get] call that created this context has
  /// returned. See [AsynchronousResolutionException].
  bool _closed = false;

  void enter(_ResolutionNode node) {
    if (_closed) throw const AsynchronousResolutionException();
    final cycleStart = _path.indexOf(node);
    if (cycleStart >= 0) {
      final cycle = [
        ..._path.sublist(cycleStart),
        node,
      ].map((item) => item.id.toString()).toList(growable: false);
      throw CircularDependencyException(cycle);
    }
    _path.add(node);
  }

  void leave(_ResolutionNode node) {
    assert(identical(_path.last, node));
    _path.removeLast();
  }
}

/// Uniquely identifies a service while a factory graph is being created.
final class const _ResolutionNode(final HelmDi owner, final _ServiceId id) {
  @override
  bool operator ==(Object other) =>
      other is _ResolutionNode &&
      identical(other.owner, owner) &&
      other.id == id;

  @override
  int get hashCode => Object.hash(identityHashCode(owner), id);
}
