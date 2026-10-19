import 'package:flutter/material.dart';

/// Набор цветов одной темы. Оранжевые фирменные цвета общие и лежат прямо в [C].
class Palette {
  const Palette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.border,
    required this.text,
    required this.muted,
    required this.cyan,
    required this.green,
    required this.red,
    required this.hover,
    required this.tileTop,
    required this.tileBottom,
    required this.tileActiveTop,
    required this.tileActiveBottom,
    required this.markMuted,
    required this.shadow,
  });

  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color border;
  final Color text;
  final Color muted;
  final Color cyan;
  final Color green;
  final Color red;

  /// Подложка элемента под курсором.
  final Color hover;

  /// Плитка кнопки подключения (выключено / включено).
  final Color tileTop;
  final Color tileBottom;
  final Color tileActiveTop;
  final Color tileActiveBottom;

  /// Цвет знака ▶▶, когда VPN выключен.
  final Color markMuted;
  final Color shadow;

  static const dark = Palette(
    brightness: Brightness.dark,
    bg: Color(0xFF09090A),
    surface: Color(0xFF131315),
    surface2: Color(0xFF1B1B1E),
    border: Color(0xFF29292E),
    text: Color(0xFFF7F7F8),
    muted: Color(0xFF8E8E96),
    cyan: Color(0xFF3FD3E6),
    green: Color(0xFF4ADE80),
    red: Color(0xFFFF4D4D),
    hover: Color(0x0FFFFFFF),
    tileTop: Color(0xFF1E1E22),
    tileBottom: Color(0xFF131316),
    tileActiveTop: Color(0xFF2A1810),
    tileActiveBottom: Color(0xFF160E0A),
    markMuted: Color(0xFF55555D),
    shadow: Color(0x80000000),
  );

  static const light = Palette(
    brightness: Brightness.light,
    bg: Color(0xFFF3F3F5),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF0F0F3),
    border: Color(0xFFE1E1E6),
    text: Color(0xFF16161A),
    muted: Color(0xFF6E6E78),
    cyan: Color(0xFF0E9BB0),
    green: Color(0xFF16A34A),
    red: Color(0xFFE0383B),
    hover: Color(0x0A000000),
    tileTop: Color(0xFFFFFFFF),
    tileBottom: Color(0xFFF1F1F4),
    tileActiveTop: Color(0xFFFFF3EB),
    tileActiveBottom: Color(0xFFFFE6D6),
    markMuted: Color(0xFFB8B8C0),
    shadow: Color(0x1F000000),
  );
}

/// Цвета интерфейса. Фирменные оранжевые — константы, остальное зависит от темы ([use]).
class C {
  static Palette _p = Palette.dark;
  static Palette get palette => _p;
  static void use(Palette p) => _p = p;
  static bool get isDark => _p.brightness == Brightness.dark;

  static const orange = Color(0xFFFF5F1A);
  static const orangeLight = Color(0xFFFF9A3D);

  static Color get bg => _p.bg;
  static Color get surface => _p.surface;
  static Color get surface2 => _p.surface2;
  static Color get border => _p.border;
  static Color get text => _p.text;
  static Color get muted => _p.muted;
  static Color get cyan => _p.cyan;
  static Color get green => _p.green;
  static Color get red => _p.red;
  static Color get hover => _p.hover;

  static const gradient = LinearGradient(
    colors: [orangeLight, orange],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static Color delay(int? ms) {
    if (ms == null) return muted;
    if (ms < 0) return red;
    if (ms < 300) return green;
    if (ms < 800) return isDark ? orangeLight : orange;
    return red;
  }
}

ThemeData buildTheme() {
  final dark = C.isDark;
  final base = ThemeData(
    brightness: C.palette.brightness,
    useMaterial3: true,
    fontFamily: 'Segoe UI',
    colorScheme: (dark ? const ColorScheme.dark() : const ColorScheme.light()).copyWith(
      primary: C.orange,
      onPrimary: Colors.white,
      secondary: C.cyan,
      surface: C.surface,
      onSurface: C.text,
      error: C.red,
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: C.bg,
    hoverColor: C.orange.withValues(alpha: 0.08),
    // Квадратная подсветка фокуса после клика мышью не нужна.
    focusColor: Colors.transparent,
    splashColor: C.orange.withValues(alpha: 0.12),
    highlightColor: C.orange.withValues(alpha: 0.06),
    dividerColor: C.border,
    dividerTheme: DividerThemeData(color: C.border, thickness: 1, space: 1),
    textTheme: base.textTheme.apply(bodyColor: C.text, displayColor: C.text),
    iconTheme: IconThemeData(color: C.text),
    cardTheme: CardThemeData(color: C.surface, elevation: 0, margin: EdgeInsets.zero),
    dialogTheme: DialogThemeData(
      backgroundColor: C.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: C.border)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.surface2,
      contentTextStyle: TextStyle(color: C.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: C.border)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.surface2,
      // При наведении фон поля не меняется (раньше заливался мутным) — подсвечивается только рамка.
      hoverColor: Colors.transparent,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      // Одна рамка на все состояния. Именно `border`: только его Flutter «разворачивает» по состояниям —
      // заданная через enabledBorder такая рамка рисовалась с почти квадратными углами.
      border: WidgetStateInputBorder.resolveWith((states) => OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: states.contains(WidgetState.error)
                  ? C.red
                  : states.contains(WidgetState.focused)
                      ? C.orange
                      : states.contains(WidgetState.hovered)
                          ? C.orange.withValues(alpha: 0.55)
                          : C.border,
            ),
          )),
      labelStyle: TextStyle(color: C.muted),
      hintStyle: TextStyle(color: C.muted),
    ),
    // Кнопки Flutter на Windows по умолчанию показывают стрелку (палец — только в браузере); у нас, как и у
    // своих переключателей и списков (Hover), над любой кнопкой — палец.
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
            foregroundColor: dark ? C.orangeLight : C.orange, enabledMouseCursor: SystemMouseCursors.click)),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.text,
        side: BorderSide(color: C.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledMouseCursor: SystemMouseCursors.click,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(enabledMouseCursor: SystemMouseCursors.click)),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(8), border: Border.all(color: C.border)),
      textStyle: TextStyle(color: C.text, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(thumbColor: WidgetStateProperty.all(C.border)),
  );
}
