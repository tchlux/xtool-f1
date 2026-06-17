# Photo Editor Known Failure Modes

## Display And Gesture Geometry Must Stay Coupled

The editor computes one `imageRect` and uses it for both the visible image and the gesture-to-pixel mapping. Any change that makes the rendered image use different sizing, content mode, intrinsic size, clipping, or aspect behavior will make taps erase the wrong pixels or appear to do nothing.

Do not replace the editor image with `UIImageView`, `NSImageView`, `UIViewRepresentable`, or `NSViewRepresentable` unless a same-code-path validation proves the rendered image frame exactly matches `PhotoEditSurface.imageRect`.

The failed change was replacing SwiftUI `Image(uiImage:)` with a `UIImageView` wrapper to force image refresh. That fixed the wrong layer: the platform view had different layout behavior from the SwiftUI image, so the image appeared zoomed and no longer aligned with `PhotoEditGestureLayer`.

Preferred fix pattern:
- Keep the visible image as SwiftUI `Image(...).resizable().interpolation(.none)`.
- Force refresh with SwiftUI identity/state at the same view level that owns the image.
- Keep `PhotoEditGestureLayer` and the visible image driven by the same `PhotoBitmap`, `imageRect`, zoom, and pan state.

## Smoke Tests Must Validate The Production Code Path

A smoke test that assigns images to a standalone `UIImageView` does not validate the editor. It can pass while the real editor is broken because the real bug can be in SwiftUI layout, ZStack ordering, geometry, or gesture overlay alignment.

Non-rendering smoke tests are useful only for state transitions:
- first color tap updates draft pixels immediately;
- undo/redo history loads update draft pixels immediately;
- revisions advance when draft image data changes.

They do not prove visual alignment. For layout-sensitive editor changes, either avoid changing the display/gesture structure or add a validation that exercises `PhotoEditSurface` geometry itself.

## SwiftUI State Ordering

Do not set SwiftUI state and then immediately read that same state in the next line to drive image edits. The first color erase bug came from setting `colorPoint` and then reading `colorPoint` inside `previewColorSelection()`. Pass the tapped point directly into the edit operation instead.

Bad pattern:

```swift
colorPoint = point
previewColorSelection() // reads stale colorPoint
```

Good pattern:

```swift
draft.previewColor(at: point, fuzziness: fuzziness)
```

## Publish After The Bitmap Is Actually Replaced

`@Published` sends change notifications in `willSet`. For the editor bitmap, that can rebuild SwiftUI while the model still exposes the previous bitmap, which presents as the visible image being one edit behind the true committed state.

Do not make the live editor bitmap an `@Published` property. Mutate the bitmap and revision first, then call `objectWillChange.send()`.

Bad pattern:

```swift
@Published var bitmap: PhotoBitmap?
bitmap = edited
```

Good pattern:

```swift
bitmap = edited
revision += 1
objectWillChange.send()
```

## Commit From The Edited Bitmap, Not From State

After an edit, encode PNG data from the local `edited` bitmap that was just produced by `PhotoEditor`, not by reading `draft.pngData()` after mutating view state. State reads after writes can be stale or coalesced.

Good flow:
- compute `edited`;
- replace the live bitmap with `edited`;
- render from that live bitmap;
- encode commit PNG from `edited`.

Undo/redo should decode returned history data and load it into the same live bitmap immediately.

## Persisted State Is Not Live Editor State

Once `PhotoEditScreen` has loaded, persisted asset paths, source paths, asset ids, and project history are boundaries. They must not drive the open editor display on every parent/project update. A commit can update persisted project state, but the open editor should keep rendering from its current bitmap until explicit undo/redo data is loaded back into that bitmap.

Do not add `onChange(of: sourcePath)` or similar reload hooks unless the editor is intentionally switching to a different photo.

## Preview Tools Need A Base Bitmap

Magic erase, color erase, and levels previews should derive from a saved preview base and write the preview into the same live bitmap. Fuzziness, level count, and boundary changes should reapply from that base rather than stacking previews on previews.

Apply commits the current preview bitmap. Cancel restores the base bitmap. For levels, also restore the previous level count and boundaries when cancelling.

## Visual Test Traps

Tests that render a detached bitmap can prove the model changed, but they do not prove the editor's visible surface uses the new bitmap. Prefer validation that enters `PhotoEditScreen`, triggers the real editor action, records the live editor bitmap, then renders `PhotoEditSurface` from that bitmap.

On iOS, `ImageRenderer` can render `UIViewRepresentable` gesture layers as a placeholder, and UIKit layer snapshots of SwiftUI content can return black. Keep the production gesture layer in the real editor, but omit it only from offscreen validation renders of `PhotoEditSurface`; the visible image and gesture geometry must still be coupled in production.
