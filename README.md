# helm_di

`helm_di` is a small, framework-independent dependency container for the
application-composition boundary. It has no dependency on Flutter, Helm, or a
code generator.

The container is deliberately not a replacement for constructor injection.
Register the object graph once in bootstrap; resolve entry-point objects such
as a router, then pass direct dependencies into features, commands, and
services through their constructors.

```dart
final di = HelmDi()
  ..registerLazySingleton<Dio>(
    (_) => Dio(),
    dispose: syncDisposer((dio) => dio.close()),
  )
  ..registerSingleton<ApiConfig>(const ApiConfig.production())
  ..registerFactory<NewsApi>((di) => NewsApi(di.get<Dio>()))
  ..seal();

final router = AppRouter(newsApi: di.get<NewsApi>());
// At application shutdown:
await di.dispose();
```

## Application singleton

`HelmDi()` always creates an independent container. For an application with
exactly one composition root, opt into an isolate-local singleton explicitly:

```dart
final di = HelmDi.app();
// Register the graph once, then call di.seal().
```

`HelmDi.app()` must be configured during bootstrap and disposed at application
shutdown like any other container. `resetApplicationForTest()` clears it only
for test isolation; application code should not replace a live graph.

## Lifetimes

- `registerSingleton`: one instance owned by the scope that registered it.
- `registerScoped`: one instance per resolving scope; useful for a route,
  request, or test.
- `registerFactory`: a new caller-owned instance for every lookup.

Use `await createScope((scope) async { ... })` for temporary overrides. It
seals the child after configuration and disposes the child if configuration
fails. `await scope.dispose()` releases only objects owned by that child;
closing a parent first closes every still-active child, preventing leaks and
use-after-dispose of app-wide services.

## Safety guarantees

The implementation rejects duplicate registrations, mutation after `seal`,
use after disposal, and circular synchronous factories. Disposal is awaited,
runs in reverse object-creation order, continues after a disposer failure, and
then rethrows the first failure. Named `ServiceKey<T>` values support multiple
implementations of the same abstraction without stringly typed lookups.
