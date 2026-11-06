import SwiftUI

/// Sits behind the controls so buttons and sliders retain their own mouse handling.
struct ControlBarDragSurface: View {
    let onDrag: (CGSize?) -> Void
    @GestureState private var isDragging = false

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        onDrag(CGSize(width: value.translation.width,
                                      height: -value.translation.height))
                    }
            )
            .onChange(of: isDragging) { _, dragging in
                if !dragging { onDrag(nil) }
            }
    }
}
