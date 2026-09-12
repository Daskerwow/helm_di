import 'helm_di.dart';

/// Creates a dependency synchronously, with access to the resolving scope.
///
/// Factories are synchronous by design. Asynchronous startup belongs in an
/// explicit application bootstrap step, where failures and readiness can be
/// handled deliberately instead of being hidden inside service resolution.
typedef DependencyFactory<T> = T Function(HelmDi di);

/// Asynchronously releases a dependency owned by a scope.
///
/// A uniform `Future<void>` contract makes application shutdown deterministic:
/// [HelmDi.dispose] never has to distinguish synchronous from asynchronous
/// teardown. Use [syncDisposer] to adapt an API such as `Dio.close`.
typedef DependencyDisposer<T> = Future<void> Function(T instance);

/// Adapts a synchronous cleanup callback to the strict [DependencyDisposer]
/// contract without exposing `FutureOr` in the public API.
DependencyDisposer<T> syncDisposer<T>(void Function(T instance) disposer) =>
    (instance) async => disposer(instance);

/// The lifetime of an object created by a DI registration.
enum ServiceLifetime {
  /// Exactly one instance belongs to the scope that registered it.
  singleton,

  /// One instance belongs to every scope that resolves the registration.
  scoped,

  /// A fresh instance is returned on every lookup; callers own its lifetime.
  factory,
}

/// A typed name for registering more than one implementation of [T].
///
/// The name is part of equality, so independently created equal keys refer to
/// the same registration. Omit [key] from `register*`/`get` for the usual
/// one-service-per-type form.
final class const ServiceKey<T>(
  /// Human-readable, stable identifier of this implementation.
  final String name,
) {
  @override
  bool operator ==(Object other) =>
      other is ServiceKey<T> && other.name == name;

  @override
  int get hashCode => Object.hash(T, name);

  @override
  String toString() => '$T($name)';
}
