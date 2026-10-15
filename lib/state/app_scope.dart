import 'package:flutter/widgets.dart';

import 'app_state.dart';

/// Состояние программы для окна. Виджеты, взявшие его через [of], перестраиваются, когда срабатывает
/// [notifier] — по умолчанию само состояние. Спрятанный раздел окна получает «спящий» источник (см. Shell)
/// и не перестраивается от каждого изменения, пока его снова не откроют.
class AppScope extends InheritedNotifier<Listenable> {
  const AppScope({super.key, required this.state, Listenable? notifier, required super.child})
      : super(notifier: notifier ?? state);
  final AppState state;

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.state;
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.state;
}
