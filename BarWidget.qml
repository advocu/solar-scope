// Tiny monochrome orbit icon (sun dot + one 1px ring + planet dot). Static: paints once,
// repaints only on colour/size change. Emits pressed(button); Panel.qml toggles on it.
import QtQuick

Item {
    id: root
    property color foreground: "#cacccc"
    property int size: 14
    signal pressed(int button)
    implicitWidth: size; implicitHeight: size
    onForegroundChanged: icon.requestPaint()
    Canvas {
        id: icon; anchors.fill: parent
        onPaint: {
            var c = getContext("2d"), r = Math.min(width, height)/2 - 1, cx = width/2, cy = height/2
            c.reset(); c.strokeStyle = root.foreground; c.fillStyle = root.foreground; c.lineWidth = 1
            c.globalAlpha = 0.6; c.beginPath(); c.arc(cx, cy, r, 0, 2*Math.PI); c.stroke()
            c.globalAlpha = 1
            c.beginPath(); c.arc(cx, cy, 1.5, 0, 2*Math.PI); c.fill()
            c.beginPath(); c.arc(cx + r*0.707, cy - r*0.707, 1.5, 0, 2*Math.PI); c.fill()
        }
    }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: function(m) { root.pressed(m.button) } }
}
