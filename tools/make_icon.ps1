# Генерирует иконку приложения из одного эскиза:
#   windows\runner\resources\app_icon.ico — иконка exe (панель задач, рабочий стол)
#   assets\icon.png                        — та же картинка для значка внутри программы
#   Цвета как у логотипа: чёрный фон, оранжевые треугольники с выемкой.
#   powershell -ExecutionPolicy Bypass -File tools\make_icon.ps1

param([switch]$InstallerMarkOnly)

Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot

function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $p
}

function New-Triangle([single]$x, [single]$y, [single]$w, [single]$h, [single]$r, $brush) {
    # Скруглённый треугольник: заливка + обводка той же кистью с круглыми стыками.
    $bmp = New-Object Drawing.Bitmap 1, 1
    $pts = [Drawing.PointF[]]@(
        (New-Object Drawing.PointF ($x + $r), ($y + $r)),
        (New-Object Drawing.PointF ($x + $w - $r), ($y + $h / 2)),
        (New-Object Drawing.PointF ($x + $r), ($y + $h - $r)))
    $pen = New-Object Drawing.Pen $brush, ([single]($r * 2))
    $pen.LineJoin = 'Round'
    , @($pts, $pen)
}

function New-Master([int]$S, [switch]$MarkOnly) {
    $bmp = New-Object Drawing.Bitmap $S, $S
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)

    # Чёрный скруглённый квадрат с едва заметной рамкой (чтобы не терялся на тёмной панели задач).
    if (-not $MarkOnly) {
        $m = $S * 0.04
        $bg = New-RoundRect $m $m ($S - 2 * $m) ($S - 2 * $m) ($S * 0.24)
        $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 12, 12, 14))), $bg)
        $g.DrawPath((New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 44, 44, 50)), ([single]($S * 0.012))), $bg)
    }

    # Знак: два треугольника, у второго выемка под кончик первого.
    $W = $S * 0.50; $H = $W * 0.72; $r = $H * 0.12
    $x0 = ($S - $W) / 2 + $S * 0.02; $y0 = ($S - $H) / 2 + $S * 0.01
    $grad = New-Object Drawing.Drawing2D.LinearGradientBrush (New-Object Drawing.PointF $x0, $y0), (New-Object Drawing.PointF ($x0 + $W), ($y0 + $H)),
        ([Drawing.Color]::FromArgb(255, 255, 154, 61)), ([Drawing.Color]::FromArgb(255, 255, 95, 26))

    # Второй треугольник рисуем на отдельном слое и вырезаем круг под кончик первого.
    $layer = New-Object Drawing.Bitmap $S, $S
    $lg = [Drawing.Graphics]::FromImage($layer); $lg.SmoothingMode = 'AntiAlias'
    # Оба треугольника одинаковой ширины: второй начинается ровно там, где кончается первый.
    $t2 = New-Triangle ($x0 + $W * 0.5) $y0 ($W * 0.5) $H $r $grad
    $lg.FillPolygon($grad, $t2[0]); $lg.DrawPolygon($t2[1], $t2[0])
    $lg.CompositingMode = 'SourceCopy'
    $notch = $W * 0.065
    $tipX = $x0 + $W * 0.5
    $lg.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::Transparent)), $tipX - $notch, $y0 + $H / 2 - $notch, $notch * 2, $notch * 2)
    $lg.Dispose()
    $g.DrawImage($layer, 0, 0)

    $t1 = New-Triangle $x0 $y0 ($W * 0.5) $H $r $grad
    $g.FillPolygon($grad, $t1[0]); $g.DrawPolygon($t1[1], $t1[0])
    $g.Dispose()
    $bmp
}

function Resize($master, [int]$s) {
    $b = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($b)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.SmoothingMode = 'AntiAlias'
    $g.DrawImage($master, 0, 0, $s, $s)
    $g.Dispose()
    $b
}

if ($InstallerMarkOnly) {
    # Тот же знак, что у приложения: меняется только подложка и прозрачные поля.
    $master = New-Master 1024 -MarkOnly
    $bounds = [Drawing.Rectangle]::new(275, 337, 515, 371)
    $mark = $master.Clone($bounds, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $mark.Save((Join-Path $root 'installer\brand-mark.png'), [Drawing.Imaging.ImageFormat]::Png)
    $mark.Dispose()
    $master.Dispose()
    Write-Host 'Знак установщика обновлён: installer\brand-mark.png'
    return
}

$master = New-Master 1024

New-Item -ItemType Directory -Force (Join-Path $root 'assets') | Out-Null
(Resize $master 256).Save((Join-Path $root 'assets\icon.png'), [Drawing.Imaging.ImageFormat]::Png)

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = @()
foreach ($s in $sizes) {
    $ms = New-Object IO.MemoryStream
    (Resize $master $s).Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $images += , $ms.ToArray()
}
$out = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter $out
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $b = [byte]($sizes[$i] % 256)
    $bw.Write($b); $bw.Write($b); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$images[$i].Length); $bw.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($d in $images) { $bw.Write($d) }
$bw.Flush()
[IO.File]::WriteAllBytes((Join-Path $root 'windows\runner\resources\app_icon.ico'), $out.ToArray())
Write-Host 'Иконка обновлена: app_icon.ico и assets\icon.png'
