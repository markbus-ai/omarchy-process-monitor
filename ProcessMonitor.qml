import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ProcUtils.js" as U

// Process Monitor — bar widget + panel.
// This file owns state, data fetching and wiring.
// Presentation lives in ProcHeader / ProcRow / KillDialog.
Panel {
  id: root
  moduleName: "markbusking.process-monitor"
  ipcTarget: "markbusking.process-monitor"
  manageIpc: false

  // ── State ──
  property real usagePercent: 0
  property real totalMemGb: 0
  property real usedMemGb: 0
  property int totalProcesses: 0
  property var processes: []
  property string filterText: ""
  property string currentUser: ""
  property int refreshInterval: 5000
  property int topCount: 15

  // Tree state
  property var expandedPids: ({})
  property var childCache: ({})
  property var fetching: ({})
  property var fetchQueue: []
  property int fetchPid: -1

  // Selection + kill dialog
  property int selectedIndex: -1
  property int hlPid: -1
  property int selectedPid: -1
  property string selectedName: ""
  property string selectedUser: ""
  property int selectedCount: 0
  property var selectedKroots: []
  property bool showKillConfirm: false

  // ── Filtering ──
  function filtered() {
    if (filterText === "") return processes
    var l = filterText.toLowerCase()
    var r = []
    for (var i = 0; i < processes.length; i++) {
      var p = processes[i]
      if (p.name.toLowerCase().indexOf(l) >= 0 || String(p.pid).indexOf(l) >= 0 || (p.cmdline && p.cmdline.toLowerCase().indexOf(l) >= 0))
        r.push(p)
    }
    return r
  }

  // ── Tree ──
  function isExpanded(pid) { return !!root.expandedPids[pid] }

  function hasKids(proc) {
    if (!proc) return false
    if ((proc.descendants || 0) > 0) return true
    if ((proc.child_count || 0) > 0) return true
    var kc = root.childCache[proc.pid]
    return !!(kc && kc.length > 0)
  }

  function kidsOf(proc) {
    if (!proc) return []
    if (proc.top_children && proc.top_children.length > 0) return proc.top_children
    var kc = root.childCache[proc.pid]
    return kc ? kc : []
  }

  function toggleExpand(proc) {
    if (!proc) return
    var m = Object.assign({}, root.expandedPids)
    if (m[proc.pid]) {
      delete m[proc.pid]
    } else {
      m[proc.pid] = true
      if (!(proc.top_children && proc.top_children.length > 0) && !root.childCache[proc.pid])
        root.fetchKids(proc.pid)
    }
    root.expandedPids = m
  }

  function fetchKids(pid) {
    if (root.childCache[pid] || root.fetching[pid]) return
    root.fetching[pid] = true
    root.fetchQueue.push(pid)
    root.pumpFetch()
  }

  function pumpFetch() {
    if (fetchProc.running || root.fetchQueue.length === 0) return
    var pid = root.fetchQueue.shift()
    root.fetchPid = pid
    fetchProc.command = ["/usr/bin/python3", root.scriptPath(), "children", String(pid)]
    root.markProc("fetch")
    fetchProc.running = true
  }

  // Watchdog: our subprocesses always finish in milliseconds (bounded
  // output); anything running >12s is hung — terminate so we never wedge.
  property var procStarted: ({})
  function markProc(name) {
    var m = Object.assign({}, root.procStarted)
    m[name] = Date.now()
    root.procStarted = m
  }

  // ── Kill ──
  function doKill(pid, name, user, count, kroots) {
    if (pid <= 1) return // never touch init
    root.selectedPid = pid
    root.selectedName = name
    root.selectedUser = user || ""
    root.selectedCount = count || 0
    root.selectedKroots = (kroots && kroots.length) ? kroots : [pid]
    root.showKillConfirm = true
  }

  function needsRoot() {
    return root.selectedUser !== "" && root.currentUser !== "" && root.selectedUser !== root.currentUser
  }

  // Two-step kill: snapshot tree identities first, then signal.
  // Unprivileged path revalidates comm+starttime per pid (PID-reuse safe).
  // Privileged path execs the system kill binary only, on the fresh list.
  property string pendingSig: ""
  function execKill(mode) {
    if (root.selectedPid <= 0) return
    root.pendingSig = mode === "kill" ? "9" : "15"
    var roots = (root.selectedKroots && root.selectedKroots.length) ? root.selectedKroots : [root.selectedPid]
    treeProc.command = ["/usr/bin/python3", root.scriptPath(), "tree-pids", roots.join(",")]
    root.markProc("tree")
    if (!treeProc.running) treeProc.running = true
  }

  function launchKill(list) {
    var sig = root.pendingSig || "15"
    var scr = root.scriptPath()
    if (root.needsRoot()) {
      var pids = []
      for (var i = 0; i < list.length; i++) pids.push(String(list[i].pid))
      killProc.command = ["/usr/bin/pkexec", "/usr/bin/kill", "-" + sig].concat(pids)
    } else {
      killProc.command = ["/usr/bin/python3", scr, "killchecked", sig, Qt.btoa(JSON.stringify(list))]
    }
    root.markProc("kill")
    killProc.running = true
  }

  // ── IPC ──
  IpcHandler {
    target: "markbusking.process-monitor"
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
  }

  // Wheel flings on the flickable are capped by maximumFlickVelocity;
  // raising the cap makes wheel scrolling noticeably faster.
  function boostScroll() {
    var f = sv.contentItem
    if (f && f.maximumFlickVelocity !== undefined) f.maximumFlickVelocity = 6500
  }

  // ── Data ──
  function refresh() {
    if (dataProc.running) return
    root.markProc("data")
    dataProc.running = true
  }

  // Absolute path of the bundled helper script, resolved relative to this
  // file so the plugin works for any user (never hardcode $HOME).
  function scriptPath() {
    return String(Qt.resolvedUrl("get-processes.py")).replace(/^file:\/\//, "")
  }
  Timer { interval: root.refreshInterval; running: true; repeat: true; onTriggered: root.refresh() }
  Component.onCompleted: refresh()

  Process {
    id: dataProc
    command: ["/usr/bin/python3", root.scriptPath(), String(Math.max(5, Math.min(50, root.topCount)))]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          root.usagePercent = d.usage_percent || 0
          root.totalMemGb = (d.total_mem_kb || 0) / 1048576
          root.usedMemGb = (d.used_mem_kb || 0) / 1048576
          root.totalProcesses = d.total_processes || 0
          root.processes = d.processes || []
          if (d.current_user) root.currentUser = d.current_user
        } catch (e) {}
      }
    }
  }

  Process {
    id: killProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: { if (!running) { root.showKillConfirm = false; root.refresh() } }
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var pid = root.fetchPid
        try {
          var arr = JSON.parse(String(text || "[]"))
          var cc = Object.assign({}, root.childCache)
          cc[pid] = Array.isArray(arr) ? arr : []
          root.childCache = cc
        } catch (e) {
          var cc2 = Object.assign({}, root.childCache)
          cc2[pid] = []
          root.childCache = cc2
        }
        delete root.fetching[pid]
        root.fetchPid = -1
        root.pumpFetch()
      }
    }
  }

  Process {
    id: treeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(String(text || "[]"))
          if (!Array.isArray(arr) || arr.length === 0) {
            root.showKillConfirm = false
            root.refresh()
            return
          }
          root.launchKill(arr)
        } catch (e) {
          root.showKillConfirm = false
          root.refresh()
        }
      }
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: {
      var now = Date.now()
      if (dataProc.running && now - (root.procStarted.data || 0) > 12000) dataProc.running = false
      if (fetchProc.running && now - (root.procStarted.fetch || 0) > 12000) { fetchProc.running = false; root.pumpFetch() }
      if (treeProc.running && now - (root.procStarted.tree || 0) > 12000) { treeProc.running = false; root.showKillConfirm = false }
      if (killProc.running && now - (root.procStarted.kill || 0) > 12000) { killProc.running = false; root.showKillConfirm = false; root.refresh() }
    }
  }

  // ── Bar button (icon + % with breathing room; fixed width so the bar never jitters) ──
  readonly property int barPx: root.bar && root.bar.barSize ? root.bar.barSize : 30
  implicitWidth: (root.bar && root.bar.vertical) ? 36 : 72
  implicitHeight: barPx

  Item {
    id: button
    anchors.fill: parent

    Rectangle {
      anchors.fill: parent
      radius: 8
      color: btnHover.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent"
    }

    Text {
      id: bIcon
      anchors.left: parent.left; anchors.leftMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      text: "󰍛"
      color: U.usageColor(root.usagePercent)
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: 14
    }
    Text {
      id: bPct
      visible: !(root.bar && root.bar.vertical)
      anchors.left: bIcon.right; anchors.leftMargin: 6
      anchors.verticalCenter: parent.verticalCenter
      text: Math.round(root.usagePercent) + "%"
      color: U.usageColor(root.usagePercent)
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: 12
      font.bold: true
    }

    MouseArea {
      id: btnHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggle()
      onEntered: {
        if (root.bar) root.bar.showTooltip(button, root.usedMemGb.toFixed(1) + " / " + root.totalMemGb.toFixed(1) + " GB · " + root.totalProcesses + " processes")
      }
      onExited: { if (root.bar) root.bar.hideTooltip(button) }
    }
  }

  // ── Panel ──
  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(Style.space(380), Style.space(560))
    Component.onCompleted: root.boostScroll()

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          var f = root.filtered()
          var i = root.selectedIndex + dy
          if (i < 0) i = 0
          if (i >= f.length) i = f.length - 1
          if (f.length > 0) {
            root.selectedIndex = i
            root.hlPid = f[i].pid
          }
        }
      }
      onActivateRequested: {
        var f = root.filtered()
        if (root.selectedIndex >= 0 && root.selectedIndex < f.length) {
          var p = f[root.selectedIndex]
          root.hlPid = p.pid
          root.doKill(p.pid, U.shortName(p), p.username, p.descendants || 0, undefined)
        }
      }
      onCloseRequested: root.close()
      onTabRequested: function(d) { root.switchPanel(d) }
      onTextKey: function(t) {
        if (t === "Escape") {
          if (root.showKillConfirm) root.showKillConfirm = false
          else if (root.filterText !== "") { root.filterText = "" }
          else root.close()
        } else if (t === " ") {
          var f = root.filtered()
          if (root.selectedIndex >= 0 && root.selectedIndex < f.length) root.toggleExpand(f[root.selectedIndex])
        } else if (t === "\x7f" || t === "\b") {
          if (root.filterText.length > 0) root.filterText = root.filterText.slice(0, -1)
        } else if (t.length === 1) {
          root.filterText += t
        }
      }
    }

    ScrollView {
      id: sv
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: ScrollBar.AsNeeded

      Column {
        id: mainCol
        width: sv.width
        spacing: 0

        ProcHeader {
          width: mainCol.width
          usagePct: root.usagePercent
          usedGb: root.usedMemGb
          totalGb: root.totalMemGb
          procCount: root.totalProcesses
          intervalSec: root.refreshInterval / 1000
          bar: root.bar
          onFilterChanged: function(t) { root.filterText = t }
        }

        Repeater {
          model: root.filtered()
          delegate: Column {
            required property var modelData
            required property int index
            readonly property var proc: modelData
            readonly property bool isOpen: root.isExpanded(proc.pid)
            width: mainCol.width
            spacing: 0

            // ── L0 header (44px) ──
            Rectangle {
              width: parent.width; height: 44
              color: (root.selectedIndex === index || root.hlPid === proc.pid) ? "#2a2a45" : rowHover.containsMouse ? "#22222f" : "transparent"

              MouseArea {
                id: rowHover
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(m) {
                  root.selectedIndex = index
                  root.hlPid = proc.pid
                  if (m.button === Qt.RightButton) {
                    root.doKill(proc.pid, U.shortName(proc), proc.username || "", proc.descendants || 0, proc.kroots)
                  } else {
                    root.toggleExpand(proc)
                  }
                }
                onDoubleClicked: { root.selectedIndex = index; root.hlPid = proc.pid; root.doKill(proc.pid, U.shortName(proc), proc.username || "", proc.descendants || 0, proc.kroots) }
              }

              Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: 3; height: 24; radius: 1
                color: U.usageColor(U.sharePct(proc.rss_kb, root.totalMemGb))
              }
              Rectangle {
                id: iconBox
                anchors.left: parent.left; anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 26; height: 26; radius: 6
                color: "#252540"
                Text {
                  anchors.centerIn: parent
                  text: U.procIcon(proc.name)
                  color: U.usageColor(U.sharePct(proc.rss_kb, root.totalMemGb))
                  font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 13
                }
              }
              Rectangle {
                id: killBox
                visible: proc.pid > 1
                anchors.right: parent.right; anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 64; height: 22; radius: 5
                color: kHover.containsMouse ? "#3d1520" : "#252540"
                border.color: kHover.containsMouse ? "#cc3344" : "#444466"
                border.width: 1
                Text {
                  anchors.centerIn: parent
                  text: "✕ Kill"
                  color: kHover.containsMouse ? "#ff5566" : "#aaaaaa"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 10; font.bold: true
                }
                MouseArea {
                  id: kHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.doKill(proc.pid, U.shortName(proc), proc.username || "", proc.descendants || 0, proc.kroots)
                }
              }
              Text {
                anchors.right: killBox.left; anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: -8
                width: 90
                text: U.fmt(proc.rss_kb || 0)
                color: U.usageColor(U.sharePct(proc.rss_kb, root.totalMemGb))
                font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 12; font.bold: true
                horizontalAlignment: Text.AlignRight
              }
              Text {
                anchors.right: killBox.left; anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: 9
                width: 90
                text: (proc.descendants || 0) > 0 ? ((isOpen ? "▼" : "▶") + proc.descendants + "·" + U.fmt(proc.own_rss_kb || 0)) : U.fmt(proc.own_rss_kb || 0)
                color: "#888888"
                font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 8
                horizontalAlignment: Text.AlignRight
              }
              Text {
                anchors.left: iconBox.right; anchors.leftMargin: 6
                anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: -8
                width: 140
                text: U.shortName(proc)
                color: "#e0e0e0"
                font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 11; font.bold: true
                elide: Text.ElideRight
              }
              Text {
                anchors.left: iconBox.right; anchors.leftMargin: 6
                anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: 9
                width: 140
                text: (proc.username || "?") + " · " + proc.pid
                color: "#888888"
                font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 9
                elide: Text.ElideRight
              }

            }

            // ── L1 children ──
            Repeater {
              model: isOpen ? root.kidsOf(proc) : []
              delegate: Column {
                required property var modelData
                required property int index
                readonly property var kid: modelData
                readonly property bool kidOpen: !!root.expandedPids[modelData.pid]
                width: mainCol.width
                spacing: 0

                Rectangle {
                  width: parent.width; height: 34
                  color: root.hlPid === kid.pid ? "#23233a" : "#1e1e33"

                  MouseArea {
                    x: 0; y: 0; width: parent.width; height: 34
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: function(m) {
                      root.hlPid = kid.pid
                      if (m.button === Qt.RightButton) {
                        root.doKill(kid.pid, U.shortName(kid), kid.username || "", kid.descendants || 0, undefined)
                      } else {
                        root.toggleExpand(kid)
                      }
                    }
                    onDoubleClicked: { root.hlPid = kid.pid; root.doKill(kid.pid, U.shortName(kid), kid.username || "", kid.descendants || 0, undefined) }
                  }

                  Rectangle { x: 22; y: 3; width: 1; height: 28; color: "#444466" }
                  Text {
                    x: 42; y: 2; width: 150
                    text: "└ " + U.shortName(kid)
                    color: "#cccccc"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 10; font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    x: 42; y: 18; width: 150
                    text: "pid " + kid.pid + " · own " + U.fmt(kid.own_rss_kb) + (root.hasKids(kid) ? (kidOpen ? " · ▼" : " · ▶") : "")
                    color: "#777777"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 8
                    elide: Text.ElideRight
                  }
                  Text {
                    anchors.right: kidKill.left; anchors.rightMargin: 6
                    y: 2; width: 84
                    text: U.fmt(kid.rss_kb)
                    color: U.usageColor(U.sharePct(kid.rss_kb, root.totalMemGb))
                    font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 10; font.bold: true
                    horizontalAlignment: Text.AlignRight
                  }
                  Rectangle {
                    id: kidKill
                    visible: kid.pid > 1
                    anchors.right: parent.right; anchors.rightMargin: 8
                    anchors.top: parent.top; anchors.topMargin: 7
                    width: 40; height: 20; radius: 4
                    color: kidHov.containsMouse ? "#3d1520" : "#252540"
                    border.color: kidHov.containsMouse ? "#cc3344" : "#444466"
                    border.width: 1
                    Text {
                      anchors.centerIn: parent; text: "✕"
                      color: kidHov.containsMouse ? "#ff5566" : "#aaaaaa"
                      font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 9; font.bold: true
                    }
                    MouseArea {
                      id: kidHov
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.doKill(kid.pid, U.shortName(kid), kid.username || "", kid.descendants || 0, undefined)
                    }
                  }
                }

                // ── L2 grandchildren (leaf rows) ──
                Repeater {
                  model: kidOpen ? root.kidsOf(kid) : []
                  delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: mainCol.width; height: 32
                    color: root.hlPid === modelData.pid ? "#26263c" : "#181826"

                    MouseArea {
                      x: 0; y: 0; width: parent.width; height: 32
                      hoverEnabled: true
                      acceptedButtons: Qt.LeftButton | Qt.RightButton
                      onClicked: function(m) {
                        root.hlPid = modelData.pid
                        if (m.button === Qt.RightButton) root.doKill(modelData.pid, U.shortName(modelData), modelData.username || "", modelData.descendants || 0, undefined)
                      }
                      onDoubleClicked: { root.hlPid = modelData.pid; root.doKill(modelData.pid, U.shortName(modelData), modelData.username || "", modelData.descendants || 0, undefined) }
                    }

                    Rectangle { x: 38; y: 2; width: 1; height: 28; color: "#3a3a55" }
                    Text {
                      x: 50; y: 1; width: 140
                      text: "└ " + U.shortName(modelData)
                      color: "#bbbbbb"
                      font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 9; font.bold: true
                      elide: Text.ElideRight
                    }
                    Text {
                      x: 50; y: 16; width: 140
                      text: "pid " + modelData.pid + ((modelData.child_count || 0) > 0 ? " · +" + modelData.child_count + " more" : "")
                      color: "#666666"
                      font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 8
                      elide: Text.ElideRight
                    }
                    Text {
                      anchors.right: gKill.left; anchors.rightMargin: 6
                      y: 1; width: 76
                      text: U.fmt(modelData.rss_kb)
                      color: U.usageColor(U.sharePct(modelData.rss_kb, root.totalMemGb))
                      font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 9; font.bold: true
                      horizontalAlignment: Text.AlignRight
                    }
                    Rectangle {
                      id: gKill
                      visible: modelData.pid > 1
                      anchors.right: parent.right; anchors.rightMargin: 8
                      anchors.top: parent.top; anchors.topMargin: 6
                      width: 34; height: 18; radius: 4
                      color: gHov.containsMouse ? "#3d1520" : "#252540"
                      border.color: gHov.containsMouse ? "#cc3344" : "#444466"
                      border.width: 1
                      Text {
                        anchors.centerIn: parent; text: "✕"
                        color: gHov.containsMouse ? "#ff5566" : "#aaaaaa"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"; font.pixelSize: 8; font.bold: true
                      }
                      MouseArea {
                        id: gHov
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.doKill(modelData.pid, U.shortName(modelData), modelData.username || "", modelData.descendants || 0, undefined)
                      }
                    }
                  }
                }
              }
            }
          }
        }

        Item {
          width: mainCol.width; height: 40; visible: root.filtered().length === 0
          Text {
            anchors.centerIn: parent
            text: root.filterText !== "" ? "No match" : "Loading..."
            color: "#888888"
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: 11
          }
        }
        Rectangle { width: mainCol.width - 28; anchors.horizontalCenter: parent.horizontalCenter; height: 1; color: "#333355" }
        Item {
          width: mainCol.width; height: 24
          Text {
            anchors.centerIn: parent
            text: "click: expand · right-click: kill · space: expand · esc: close"
            color: "#555577"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: 9
          }
        }
      }
    }

    KillDialog {
      visible: root.showKillConfirm
      pid: root.selectedPid
      procName: root.selectedName
      procUser: root.selectedUser
      procCount: root.selectedCount
      needsRoot: root.needsRoot()
      bar: root.bar
      onUseTerm: root.execKill("term")
      onUseKill: root.execKill("kill")
      onCancelled: root.showKillConfirm = false
    }
  }
}
