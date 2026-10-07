/// Версия программы. Берётся из тега релиза при сборке на GitHub
/// (`--dart-define=APP_VERSION=1.0.8` из тега `v1.0.8`), при локальной сборке — значение по умолчанию.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.8');

/// GitHub-репозиторий приложения в формате `owner/repo` — отсюда берутся обновления SkipIt
/// (последний релиз и установщик SkipIt-Setup-*.exe в нём).
const appRepo = 'getskipit/skipit';
