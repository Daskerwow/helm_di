/// Base exception for invalid DI-container use.
sealed class const HelmDiException(
  /// A concise diagnostic intended for logs and developer error screens.
  final String message,
) implements Exception {
  @override
  String toString() => 'HelmDiException: $message';
}

/// Thrown when no matching registration is visible from the current scope.
final class const DependencyNotFoundException(String service)
    extends HelmDiException {
  this : super('No dependency is registered for $service.');
}

/// Thrown instead of silently replacing a local registration.
final class const DuplicateRegistrationException(String service)
    extends HelmDiException {
  this
    : super('A dependency is already registered for $service in this scope.');
}

/// Thrown when application bootstrap tries to mutate a sealed scope.
final class const ContainerSealedException() extends HelmDiException {
  this : super('This HelmDi scope is sealed and cannot accept registrations.');
}

/// Thrown when code tries to mutate a scope after its object graph was used.
final class const ContainerResolutionStartedException()
    extends HelmDiException {
  this
    : super(
        'This HelmDi scope has already resolved a dependency and cannot '
        'accept registrations.',
      );
}

/// Thrown for every lookup or mutation after disposal has begun.
final class const ContainerDisposedException() extends HelmDiException {
  this : super('This HelmDi scope is disposing or has already been disposed.');
}

/// Thrown before recursive factories can overflow the stack.
final class CircularDependencyException(List<String> path)
    extends HelmDiException {
  this : super('Circular dependency detected: ${path.join(' -> ')}.');
}
