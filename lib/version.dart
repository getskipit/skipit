/// Версия программы. Берётся из тега релиза при сборке на GitHub
/// (`--dart-define=APP_VERSION=1.1.1` из тега `v1.1.1`), при локальной сборке — значение по умолчанию.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.1.1');

/// GitHub-репозиторий приложения в формате `owner/repo` — отсюда берутся обновления SkipIt
/// (последний релиз и установщик SkipIt-Setup-*.exe в нём).
const appRepo = 'getskipit/skipit';
