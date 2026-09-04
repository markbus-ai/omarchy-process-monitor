import QtQuick
import qs.Commons

// Kill confirmation dialog. Props in, signals out.
Rectangle {
  id: dlg
  anchors.fill: parent
  z: 100
  color: Qt.rgba(0, 0, 0, 0.7)

  required property int pid
  required property string procName
  required property string procUser
  required property int procCount
  required property bool needsRoot
  required property var bar

  signal useTerm()
  signal useKill()
  signal cancelled()

  function barFont() { return dlg.bar ? dlg.bar.fontFamily : Style.font.family }

  MouseArea { anchors.fill: parent; onClicked: dlg.cancelled() }

  Rectangle {
    anchors.centerIn: parent; width: 280; height: dlg.needsRoot ? 196 : 178; radius: 12
    color: "#1a1a2e"; border.color: "#cc3344"; border.width: 1

    Text {
      x: 0; y: 14; width: 280
      text: "⚠  Kill " + dlg.procName + "?"
      color: "#e0e0e0"
      font.family: dlg.barFont(); font.pixelSize: 13; font.bold: true
      horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
    }
    Text {
      x: 0; y: 36; width: 280
      text: "PID " + dlg.pid + (dlg.procUser !== "" ? " · " + dlg.procUser : "") + (dlg.procCount > 0 ? " · " + (dlg.procCount + 1) + " procs" : "")
      textFormat: Text.PlainText
      color: "#888888"
      font.family: dlg.barFont(); font.pixelSize: 10
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }
    Text {
      x: 0; y: 50; width: 280
      visible: dlg.needsRoot
      text: "needs root — will ask via polkit"
      color: "#e6b800"
      font.family: dlg.barFont(); font.pixelSize: 9
      horizontalAlignment: Text.AlignHCenter
    }

    Rectangle {
      x: 20; y: dlg.needsRoot ? 78 : 62; width: 115; height: 38; radius: 7
      color: tHov.containsMouse ? "#332d1a" : "#252540"
      border.color: "#665522"; border.width: 1
      Text { anchors.centerIn: parent; text: "SIGTERM\nGraceful"; color: "#e0e0e0"; font.family: dlg.barFont(); font.pixelSize: 10; font.bold: true; horizontalAlignment: Text.AlignHCenter }
      MouseArea { id: tHov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dlg.useTerm() }
    }
    Rectangle {
      x: 145; y: dlg.needsRoot ? 78 : 62; width: 115; height: 38; radius: 7
      color: kHov.containsMouse ? "#3d1520" : "#252540"
      border.color: "#cc3344"; border.width: 1
      Text { anchors.centerIn: parent; text: "SIGKILL\nForce"; color: "#e0e0e0"; font.family: dlg.barFont(); font.pixelSize: 10; font.bold: true; horizontalAlignment: Text.AlignHCenter }
      MouseArea { id: kHov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dlg.useKill() }
    }
    Rectangle {
      x: 110; y: dlg.needsRoot ? 128 : 112; width: 60; height: 24; radius: 5
      color: cHov.containsMouse ? "#252540" : "transparent"
      Text { anchors.centerIn: parent; text: "Cancel"; color: "#888888"; font.family: dlg.barFont(); font.pixelSize: 10 }
      MouseArea { id: cHov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dlg.cancelled() }
    }
  }
}
