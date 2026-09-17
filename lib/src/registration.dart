part of 'helm_di.dart';

/// A private, type-erased key used by maps while preserving the public generic
/// API. The optional name represents [ServiceKey].
final class const _ServiceId(final Type type, [final String? name]) {
  @override
  bool operator ==(Object other) =>
      other is _ServiceId && other.type == type && other.name == name;

  @override
  int get hashCode => Object.hash(type, name);

  @override
  String toString() => name == null ? '$type' : '$type($name)';
}

/// Type-erased registration metadata for the heterogeneous internal map.
///
/// The public [HelmDi] API performs generic adaptation at registration time;
/// this storage layer uses `Object?`, never `dynamic`. Instance caches live in
/// scopes instead of here, which keeps scoped lifetime ownership explicit.
final class const _Registration({
  required final Object? Function(HelmDi di) factory,
  required final ServiceLifetime lifetime,
  final Future<void> Function(Object? value)? dispose,
});

/// An object already created by a singleton or scoped registration.
final class const _OwnedInstance(
  final Object? value,
  final Future<void> Function() dispose,
);
