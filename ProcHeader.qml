import QtQuick
import QtQuick.Controls
import qs.Commons
import "ProcUtils.js" as U

// Panel header: memory summary, progress bar, process count, filter box.
// Props in, filterChanged signal out. No data fetching here.
Column {
  id: header
  spacing: 0

  required property real usagePct
  required property real usedGb
  required property real totalGb
  required property int procCount
  required property int intervalSec
  required property var bar

  signal filterChanged(string text)

  function barFont() { return header.bar ? header.bar.fontFamily : Style.font.family }

  // ── Summary row ──
  Rectangle {
    width: parent.width; height: 64; color: "transparent"

    Rectangle {
      id: headerIcon
      anchors.left: parent.left; anchors.leftMargin: 14
      anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: -4
      width: 38; height: 38; radius: 9
      color: U.usageColorDim(header.usagePct)
      Text {
        anchors.centerIn: parent; text: "󰍛"
        color: U.usageColor(header.usagePct)
        font.family: header.barFont(); font.pixelSize: 18
      }
    }
    Rectangle {
      id: headerPill
      anchors.right: parent.right; anchors.rightMargin: 14
      anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: -4
      width: 62; height: 28; radius: 7
      color: U.usageColorDim(header.usagePct)
      Text {
        anchors.centerIn: parent
        text: Math.round(header.usagePct) + "%"
        color: U.usageColor(header.usagePct)
        font.family: header.barFont(); font.pixelSize: 12; font.bold: true
      }
    }
    Text {
      anchors.left: headerIcon.right; anchors.leftMargin: 8
      anchors.right: headerPill.left; anchors.rightMargin: 8
      y: 12; height: 20
      text: "Memory"
      color: "#e0e0e0"
      font.family: header.barFont(); font.pixelSize: 14; font.bold: true
      elide: Text.ElideRight
    }
    Text {
      anchors.left: headerIcon.right; anchors.leftMargin: 8
      anchors.right: headerPill.left; anchors.rightMargin: 8
      y: 32; height: 16
      text: header.usedGb.toFixed(1) + " / " + header.totalGb.toFixed(1) + " GB  ·  " + header.procCount + " procs · Live " + header.intervalSec + "s"
      color: "#888888"
      font.family: header.barFont(); font.pixelSize: 10
      elide: Text.ElideRight
    }
    Rectangle {
      anchors.left: parent.left; anchors.right: parent.right
      anchors.leftMargin: 14; anchors.rightMargin: 14
      anchors.bottom: parent.bottom; anchors.bottomMargin: 4
      height: 4; radius: 2; color: "#333355"
      Rectangle {
        width: Math.max(4, parent.width * (header.usagePct / 100))
        height: 4; radius: 2; color: U.usageColor(header.usagePct)
        Behavior on width { NumberAnimation { duration: 400 } }
      }
    }
  }

  Rectangle { width: parent.width; height: 1; color: "#333355" }

  // ── Filter ──
  Rectangle {
    width: parent.width; height: 38; color: "transparent"
    TextField {
      id: searchBox
      anchors.left: parent.left; anchors.right: parent.right
      anchors.leftMargin: 14; anchors.rightMargin: 14
      anchors.verticalCenter: parent.verticalCenter; height: 26
      placeholderText: "  Filter by name, pid..."
      placeholderTextColor: "#666666"
      color: "#e0e0e0"
      font.family: header.barFont(); font.pixelSize: 11
      background: Rectangle { radius: 7; color: "#252540"; border.color: "#333355"; border.width: 1 }
      onTextChanged: header.filterChanged(text)
    }
  }

  Rectangle { width: parent.width; height: 1; color: "#333355" }
}
