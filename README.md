# flutter_custom_cursor

![](https://img.shields.io/pub/v/flutter_custom_cursor?color=green)
![](https://img.shields.io/pub/publisher/flutter_custom_cursor)

This plugin allows to create/set a custom mouse cursor directly from a memory buffer.



Big thanks to imiskolee to create the [base of this plugin](https://github.com/imiskolee/flutter_custom_cursor).

## Platforms

- [x] macOS
- [x] Windows
- [x] Linux

Note: Currently, the api required by this plugin on Windows is included in flutter `master` branch. It means that u need to use this plugin with flutter master branch on Windows platform. See [flutter engine PR#36143](https://github.com/flutter/engine/pull/36143) for details.

Update: the latest Flutter `3.7.0` does not contain PR above, which merges to `flutter-3.7.0-candidate.2`, while Flutter stable `3.7.0` is using `flutter-3.7.0-candidate.1`. This limitation will be lifted maybe in the next Flutter stable release.

# Get prepared

## Register a Flutter image with an explicit scale

```dart
await CursorManager.instance.registerCursorImage(
  name: cursorName,
  image: image, // dart:ui Image; the caller retains ownership.
  hotSpot: const Offset(3, 5), // Coordinates in the source image's pixels.
  scale: 0.75, // Logical pixels per source pixel.
  devicePixelRatio: View.of(context).devicePixelRatio,
);
```

The plugin scales the full artwork and hotspot together. macOS uses logical
points independently of PNG density metadata. Windows uses physical pixels and
the Flutter engine's cursor channel. GTK requires integer logical dimensions
and hotspots; its raster density is rounded up to an integer. Tall Linux images
are padded on the right with transparency to avoid hardware cursor clipping.

Use a new name whenever the image, scale or DPR changes, and await deletion
before reusing a name. `FlutterCustomMemoryImageCursor` waits for image creation
and does not activate a session that has already been disposed. Applications
choose their own minimum cursor size; a size that rounds to zero is an error.
The existing buffer API below keeps its original units and formats.

## Register your custom cursor before

```dart
// register this cursor
cursorName = await CursorManager.instance.registerCursor(CursorData()
  ..name = "test"
  ..buffer =
      Platform.isWindows ? memoryCursorDataRawBGRA : memoryCursorDataRawPNG
  ..height = img.height
  ..width = img.width
  ..hotX = 0
  ..hotY = 0);
```

Note that a String `cacheName` will be returned by the function `registerCursor`, which can be used to set this cursor to system or delete this cursor.

`CursorData.buffer` is a `Uint8List` which contains the cursor data. Be aware that on Windows, `buffer` is formatted by `rawBGRA`, other OS(s) are `rawPNG`.

see the example project for details.

## Set the custom cursor

We have implemented the `FlutterCustomMemoryImageCursor` class, which is a subclass of `MouseCursor`. This class will automatically set the memory cursor for you. Keep it simple.

```dart
MouseRegion(
  cursor: FlutterCustomMemoryImageCursor(key: cursorName),
  child: Row(
    children: [
      Text("Memory image here", style: style),
    ],
  ),
),
```

## Delete the cursor 

You can delete a cursor with the `cursorName`.

```dart
await CursorManager.instance.deleteCursor("cursorName");
```
