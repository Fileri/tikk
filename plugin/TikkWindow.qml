import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// tikk window — the "actual app", laid out like Reminders.app on the Mac:
// a sidebar with the smart lists (Today, Scheduled, All) and "My Lists" with
// counts, and a main pane with the list title in its colour, round tick
// circles, notes and due dates under each title, a completed section you can
// show or hide, and a "New Reminder" row at the bottom.
//
// Hosted inside the Omarchy shell (like blip's window) so it shares the bar
// widget's poller and write queue. `hostWidget` is injected by BarWidget.
//
// Keys: Up/Down or j/k move · Space or Enter tick · Delete delete ·
//       n or + new reminder · Tab next list · Esc leave field, then close.
FloatingWindow {
  id: win
  property var hostWidget: null
  readonly property var host: hostWidget
  title: "tikk"
  color: Color.background
  implicitWidth: 960
  implicitHeight: 640
  minimumSize: Qt.size(640, 420)
  visible: false

  readonly property string fontFamily: Style.font.family
  readonly property color fg: Color.foreground
  readonly property color muted: Color.muted
  readonly property color rowHover: Qt.rgba(fg.r, fg.g, fg.b, 0.06)
  readonly property color rowSelected: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  readonly property color sidebarBg: Qt.rgba(fg.r, fg.g, fg.b, 0.035)

  // ---- selection: a smart list or a real list
  property string kind: "list"        // "today" | "scheduled" | "all" | "list"
  property string listName: host ? host.list : ""
  property int cursor: 0
  property bool showDone: false
  property bool sidebarFocus: false

  readonly property var palette: ["#0A84FF", "#FF453A", "#FF9F0A", "#FFD60A", "#30D158", "#BF5AF2", "#64D2FF", "#FF6482", "#AC8E68"]
  function listColor(name) {
    var h = 0
    for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) & 0x7fffffff
    return palette[h % palette.length]
  }
  readonly property color accent: kind === "today" ? "#0A84FF" : kind === "scheduled" ? "#FF453A" : kind === "all" ? "#8E8E93" : listColor(listName)
  readonly property string heading: kind === "today" ? "Today" : kind === "scheduled" ? "Scheduled" : kind === "all" ? "All" : listName

  // ---- dates
  function startOfToday() { var d = new Date(); d.setHours(0, 0, 0, 0); return d }
  function dueDate(r) { return r.due ? new Date(r.due) : null }
  function isToday(r) {
    var d = dueDate(r); if (!d) return false
    var t0 = startOfToday(); var t1 = new Date(t0.getTime() + 86400000)
    return d < t1   // due today or overdue, as Reminders' Today does
  }
  function isOverdue(r) {
    var d = dueDate(r); if (!d) return false
    return r.allday ? d < startOfToday() : d < new Date()
  }
  function dueLabel(r) {
    var d = dueDate(r); if (!d) return ""
    var t0 = startOfToday(); var days = Math.floor((d - t0) / 86400000)
    var day = days === 0 ? "Today" : days === 1 ? "Tomorrow" : days === -1 ? "Yesterday"
      : Qt.formatDate(d, days > 1 && days < 7 ? "dddd" : "d MMM yyyy")
    return r.allday ? day : day + ", " + Qt.formatTime(d, "HH:mm")
  }

  // ---- derived rows
  readonly property var openRows: {
    if (!host) return []
    var all = host.all
    var rows = kind === "list" ? all.filter(function(r) { return r.list === listName })
      : kind === "today" ? all.filter(isToday)
      : kind === "scheduled" ? all.filter(function(r) { return !!r.due }) : all.slice()
    if (kind !== "list") rows.sort(function(a, b) { return (a.due || "9") < (b.due || "9") ? -1 : 1 })
    return rows
  }
  readonly property var doneRows: (host && kind === "list" && showDone && host.doneList === listName) ? host.done : []
  readonly property var rows: openRows.concat(doneRows)
  readonly property int todayCount: host ? host.all.filter(isToday).length : 0
  readonly property int scheduledCount: host ? host.all.filter(function(r) { return !!r.due }).length : 0
  readonly property int allCount: host ? host.all.length : 0
  readonly property string targetList: kind === "list" ? listName : (host ? host.list : "")

  function select(k, name) {
    kind = k; if (name !== undefined) listName = name
    cursor = 0; showDone = false; sidebarFocus = false
  }
  function toggleDone() {
    showDone = !showDone
    if (showDone && host) host.loadDone(listName)
  }
  function moveCursor(dy) {
    if (rows.length === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + dy))
    mainList.positionViewAtIndex(cursor, ListView.Contain)
  }
  function tick(r) { if (!host || String(r.id).indexOf("pending-") === 0) return; if (r.completed) host.uncomplete(r); else host.complete(r) }
  function tickCursor() { if (rows.length > 0) { tick(rows[cursor]); cursor = Math.max(0, Math.min(cursor, rows.length - 2)) } }
  function deleteCursor() { if (rows.length > 0 && host) { host.remove(rows[cursor]); cursor = Math.max(0, Math.min(cursor, rows.length - 2)) } }
  function submitNew() {
    var t = newField.text; newField.text = ""
    if (t.trim() !== "" && host) host.add(t, targetList)
  }
  function nextList(direction) {
    if (!host) return
    var names = host.listNames(); if (names.length === 0) return
    var i = kind === "list" ? names.indexOf(listName) : -1
    select("list", names[(i + direction + names.length) % names.length])
  }
  onVisibleChanged: if (visible) { if (listName === "" && host) listName = host.list; Qt.callLater(function() { keyScope.forceActiveFocus() }) }

  FocusScope {
    id: keyScope
    anchors.fill: parent
    focus: true
    Keys.onPressed: function(e) {
      if (newField.activeFocus) return
      if (e.key === Qt.Key_Escape) { win.visible = false; e.accepted = true }
      else if (e.key === Qt.Key_Down || e.key === Qt.Key_J) { win.moveCursor(1); e.accepted = true }
      else if (e.key === Qt.Key_Up || e.key === Qt.Key_K) { win.moveCursor(-1); e.accepted = true }
      else if (e.key === Qt.Key_Space || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { win.tickCursor(); e.accepted = true }
      else if (e.key === Qt.Key_Delete || e.key === Qt.Key_Backspace) { win.deleteCursor(); e.accepted = true }
      else if (e.key === Qt.Key_N || e.key === Qt.Key_Plus) { newField.forceActiveFocus(); e.accepted = true }
      else if (e.key === Qt.Key_Tab) { win.nextList(1); e.accepted = true }
      else if (e.key === Qt.Key_Backtab) { win.nextList(-1); e.accepted = true }
      else if (e.key === Qt.Key_R) { if (win.host) win.host.refresh(); e.accepted = true }
      else if (e.key === Qt.Key_H) { if (win.kind === "list") win.toggleDone(); e.accepted = true }
    }

    RowLayout {
      anchors.fill: parent
      spacing: 0

      // ================================================================ sidebar
      Rectangle {
        Layout.preferredWidth: 236
        Layout.fillHeight: true
        color: win.sidebarBg
        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.space(12)
          spacing: Style.space(10)

          // smart list tiles, 2 per row like Reminders.app
          GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(8)
            Repeater {
              model: [
                { k: "today", label: "Today", icon: "󰃭", color: "#0A84FF", n: win.todayCount },
                { k: "scheduled", label: "Scheduled", icon: "󰸘", color: "#FF453A", n: win.scheduledCount },
                { k: "all", label: "All", icon: "󰉹", color: "#8E8E93", n: win.allCount }
              ]
              delegate: Rectangle {
                required property var modelData
                readonly property bool active: win.kind === modelData.k
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(64)
                radius: Style.space(10)
                color: active ? modelData.color : Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.07)
                Rectangle {
                  x: Style.space(10); y: Style.space(10)
                  width: Style.space(26); height: width; radius: width / 2
                  color: parent.active ? Qt.rgba(1, 1, 1, 0.3) : modelData.color
                  Text { anchors.centerIn: parent; text: modelData.icon; color: "white"; font.pixelSize: Style.font.subtitle }
                }
                Text {
                  anchors.right: parent.right; anchors.top: parent.top
                  anchors.rightMargin: Style.space(10); anchors.topMargin: Style.space(6)
                  text: modelData.n
                  color: parent.active ? "white" : win.fg
                  font.family: win.fontFamily; font.pixelSize: Style.font.heading; font.bold: true
                }
                Text {
                  anchors.left: parent.left; anchors.bottom: parent.bottom
                  anchors.leftMargin: Style.space(10); anchors.bottomMargin: Style.space(8)
                  text: modelData.label
                  color: parent.active ? "white" : win.muted
                  font.family: win.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
                }
                MouseArea { anchors.fill: parent; onClicked: win.select(modelData.k) }
              }
            }
          }

          Text {
            text: "My Lists"
            color: win.muted
            font.family: win.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
            Layout.topMargin: Style.space(6)
          }
          ListView {
            id: listList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Style.space(2)
            model: win.host ? win.host.lists : []
            delegate: Rectangle {
              required property var modelData
              readonly property bool active: win.kind === "list" && win.listName === modelData.name
              width: listList.width
              height: Style.space(30)
              radius: Style.space(6)
              color: active ? win.rowSelected : (rowMouse.containsMouse ? win.rowHover : "transparent")
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)
                Rectangle {
                  width: Style.space(20); height: width; radius: width / 2
                  color: win.listColor(modelData.name)
                  Text { anchors.centerIn: parent; text: "󰉹"; color: "white"; font.pixelSize: Style.font.caption }
                }
                Text {
                  Layout.fillWidth: true
                  text: modelData.name
                  color: win.fg
                  font.family: win.fontFamily; font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  text: modelData.open > 0 ? modelData.open : ""
                  color: win.muted
                  font.family: win.fontFamily; font.pixelSize: Style.font.body
                }
              }
              MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; onClicked: win.select("list", modelData.name) }
            }
          }
          Text {
            text: win.host ? (win.host.online ? (win.host.loading ? "refreshing…" : "") : "gateway offline") : ""
            color: win.host && win.host.online ? win.muted : Color.urgent
            font.family: win.fontFamily; font.pixelSize: Style.font.caption
          }
        }
      }

      // ================================================================ main pane
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.space(22)
          spacing: Style.space(6)

          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: win.heading
              color: win.accent
              font.family: win.fontFamily; font.pixelSize: Style.font.displayLarge; font.bold: true
              elide: Text.ElideRight
            }
            Text {
              text: win.openRows.length
              color: win.accent
              font.family: win.fontFamily; font.pixelSize: Style.font.displayLarge; font.bold: true
              opacity: 0.8
            }
          }
          RowLayout {
            visible: win.kind === "list"
            spacing: Style.space(6)
            Text {
              text: win.showDone ? (win.doneRows.length + " Completed") : "Completed"
              color: win.muted
              font.family: win.fontFamily; font.pixelSize: Style.font.bodySmall
            }
            Text { text: "·"; color: win.muted; font.pixelSize: Style.font.bodySmall }
            Text {
              text: win.showDone ? "Hide" : "Show"
              color: win.accent
              font.family: win.fontFamily; font.pixelSize: Style.font.bodySmall
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: win.toggleDone() }
            }
            Text {
              visible: win.host && win.host.lastError !== ""
              text: "  " + (win.host ? win.host.lastError : "")
              color: Color.urgent
              font.family: win.fontFamily; font.pixelSize: Style.font.bodySmall
            }
          }

          ListView {
            id: mainList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: win.rows
            spacing: 0
            delegate: Item {
              required property var modelData
              required property int index
              readonly property bool selected: index === win.cursor && !win.sidebarFocus
              readonly property bool pending: String(modelData.id).indexOf("pending-") === 0
              readonly property bool done: modelData.completed === true
              readonly property string sub: [modelData.body || "", win.dueLabel(modelData)].filter(function(x) { return x !== "" }).join("  ·  ")
              width: mainList.width
              height: rowCol.implicitHeight + Style.space(14)
              opacity: pending ? 0.5 : 1
              Rectangle { anchors.fill: parent; radius: Style.space(6); color: selected ? win.rowSelected : (mm.containsMouse ? win.rowHover : "transparent") }
              Rectangle {   // separator like Reminders' hairlines
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.leftMargin: Style.space(34); height: 1
                color: Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.08)
              }
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(6); anchors.rightMargin: Style.space(6)
                spacing: Style.space(10)
                Rectangle {   // the tick circle
                  id: circle
                  Layout.alignment: Qt.AlignTop
                  Layout.topMargin: Style.space(9)
                  width: Style.space(18); height: width; radius: width / 2
                  color: done ? win.accent : "transparent"
                  border.width: Style.space(1.5)
                  border.color: done || circleMouse.containsMouse ? win.accent : win.muted
                  Rectangle { anchors.centerIn: parent; width: parent.width - Style.space(6); height: width; radius: width / 2; color: win.accent; visible: !done && circleMouse.containsMouse }
                  Text { anchors.centerIn: parent; text: "✓"; color: "white"; visible: done; font.pixelSize: Style.font.caption; font.bold: true }
                  MouseArea { id: circleMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.tick(modelData) }
                }
                ColumnLayout {
                  id: rowCol
                  Layout.fillWidth: true
                  spacing: Style.space(2)
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.StyledText
                    text: (modelData.priority === 1 ? "<font color='" + win.accent + "'>!!! </font>" : modelData.priority === 5 ? "<font color='" + win.accent + "'>!! </font>" : modelData.priority === 9 ? "<font color='" + win.accent + "'>! </font>" : "")
                          + String(modelData.name).replace(/&/g, "&amp;").replace(/</g, "&lt;")
                    color: done ? win.muted : win.fg
                    font.family: win.fontFamily; font.pixelSize: Style.font.subtitle
                    font.strikeout: done
                    wrapMode: Text.Wrap
                  }
                  Text {
                    visible: sub !== "" || win.kind !== "list"
                    Layout.fillWidth: true
                    text: win.kind !== "list" ? [modelData.list, sub].filter(function(x) { return x !== "" }).join("  ·  ") : sub
                    color: !done && win.isOverdue(modelData) ? "#FF453A" : win.muted
                    font.family: win.fontFamily; font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }
                Text {   // delete, revealed on hover like Reminders' ⓘ
                  text: "✕"
                  visible: mm.containsMouse && !done
                  color: win.muted
                  font.pixelSize: Style.font.body
                  Layout.alignment: Qt.AlignVCenter
                  MouseArea { anchors.fill: parent; anchors.margins: -Style.space(6); cursorShape: Qt.PointingHandCursor; onClicked: win.host.remove(modelData) }
                }
              }
              MouseArea {
                id: mm
                anchors.fill: parent
                hoverEnabled: true
                z: -1
                onClicked: { win.cursor = index; win.sidebarFocus = false; keyScope.forceActiveFocus() }
              }
            }
            Text {
              anchors.centerIn: parent
              visible: win.rows.length === 0 && win.host && win.host.online && !win.host.loading
              text: "No Reminders"
              color: win.muted
              font.family: win.fontFamily; font.pixelSize: Style.font.heading
            }
          }

          // ---- new reminder row
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)
            Rectangle {
              width: Style.space(18); height: width; radius: width / 2
              color: newField.activeFocus ? win.accent : "transparent"
              border.width: Style.space(1.5); border.color: newField.activeFocus ? win.accent : win.muted
              Text { anchors.centerIn: parent; text: "+"; color: newField.activeFocus ? "white" : win.muted; font.pixelSize: Style.font.body; font.bold: true }
              MouseArea { anchors.fill: parent; onClicked: newField.forceActiveFocus() }
            }
            TextField {
              id: newField
              Layout.fillWidth: true
              placeholderText: win.targetList !== "" ? "New Reminder in " + win.targetList : "New Reminder"
              foreground: win.fg
              accent: win.accent
              font.family: win.fontFamily
              font.pixelSize: Style.font.subtitle
              onAccepted: win.submitNew()
              Keys.onEscapePressed: { text = ""; keyScope.forceActiveFocus() }
            }
          }
          Text {
            text: "space tick · del delete · n new · tab next list · h completed · esc close"
            color: win.muted
            font.family: win.fontFamily; font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
