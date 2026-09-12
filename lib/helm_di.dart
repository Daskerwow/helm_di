/// A framework-independent dependency container for application composition.
///
/// `helm_di` deliberately knows nothing about Flutter or Helm. It owns object
/// lifetimes at an application's integration boundary; feature and domain code
/// should still receive its direct dependencies through constructors.
library;

export 'src/contracts.dart';
export 'src/errors.dart';
export 'src/helm_di.dart';
