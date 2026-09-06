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

  // Everything visual comes from the shell theme: Color.* for the palette,
  // Style.*For for interactive states, Style.cornerRadius and Style.spacing.*
  // for shape and rhythm. No literal colours in this file.
  readonly property string fontFamily: Style.font.family
  readonly property color fg: Color.foreground
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent
  readonly property color onTint: Color.background      // text on an accent-filled surface
  readonly property color rowHover: Style.hoverFillFor(fg, Color.accent)
  readonly property color rowSelected: Style.selectedFillFor(fg, Color.accent)
  readonly property color sidebarBg: Style.normalFillFor(fg, Color.accent)
  readonly property color hairline: Util.alpha(fg, 0.08)
  readonly property color tileFill: Util.alpha(fg, 0.07)

  // ---- selection: a smart list or a real list
  property string kind: "list"        // "today" | "scheduled" | "all" | "list"
  property string listName: host ? host.list : ""
  property int cursor: 0
  property bool showDone: false
  property bool sidebarFocus: false

  // Per-list colours the way Reminders.app has them, but derived from the
  // theme: the accent's hue rotated by the golden angle per list, so every
  // theme switch recolours the lists with it. A grey accent gets a modest
  // saturation floor so lists stay distinguishable.
  function listMeta(name) {
    if (!host) return null
    for (var i = 0; i < host.lists.length; i++) if (host.lists[i].name === name) return host.lists[i]
    return null
  }
  function listColor(name) {
    var m = listMeta(name)
    if (m && m.color) return m.color   // the list's own colour, as set on the Mac/iPhone (user data, not theme)
    var names = host ? host.listNames() : []
    var i = Math.max(0, names.indexOf(name))
    var a = Color.accent
    var sat = a.hslSaturation < 0.25 ? 0.45 : a.hslSaturation
    var light = Math.min(0.68, Math.max(0.42, a.hslLightness))
    return Qt.hsla((a.hslHue + i * 0.618034) % 1.0, sat, light, 1)
  }
  readonly property color accent: kind === "today" ? Color.accent : kind === "scheduled" ? urgent : kind === "all" ? muted : listColor(listName)
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

  // ---- sidebar rows: [{type:"list", list}, {type:"group", name, open, collapsed}, {type:"list", list, indent:true}]
  property var collapsed: ({})
  readonly property var sidebarRows: {
    if (!host) return []
    var rows = [], grouped = {}
    var groups = host.groups || []
    for (var g = 0; g < groups.length; g++) for (var j = 0; j < groups[g].lists.length; j++) grouped[groups[g].lists[j]] = true
    for (var i = 0; i < host.lists.length; i++) if (!grouped[host.lists[i].name]) rows.push({ type: "list", list: host.lists[i], indent: false })
    for (g = 0; g < groups.length; g++) {
      var open = 0, members = []
      for (j = 0; j < groups[g].lists.length; j++) { var m = listMeta(groups[g].lists[j]); if (m) { members.push(m); open += m.open } }
      var isCollapsed = collapsed[groups[g].name] === true
      rows.push({ type: "group", name: groups[g].name, open: open, collapsed: isCollapsed })
      if (!isCollapsed) for (j = 0; j < members.length; j++) rows.push({ type: "list", list: members[j], indent: true })
    }
    return rows
  }
  function toggleGroup(name) { var c = JSON.parse(JSON.stringify(collapsed)); c[name] = !(c[name] === true); collapsed = c }
  function emblemGlyph(m) {
    var e = m && m.emblem ? String(m.emblem) : ""
    if (e === "" || e === "default") return "󰉹"
    if (e.length <= 2 || /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(e)) return e   // an emoji emblem
    if (e.indexOf("shopping") === 0) return "󰄐"
    if (e.indexOf("nature") === 0) return "󰌪"
    if (e.indexOf("weather") === 0) return "󰖐"
    return "󰉹"
  }

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
  function deleteCursor() { if (rows.length > 0 && host && host.canDelete) { host.remove(rows[cursor]); cursor = Math.max(0, Math.min(cursor, rows.length - 2)) } }
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
        Layout.preferredWidth: Style.space(236)
        Layout.fillHeight: true
        color: win.sidebarBg
        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.spacing.popupPadding
          spacing: Style.spacing.rowGap

          // smart list tiles, 2 per row like Reminders.app
          GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Style.spacing.controlGap
            rowSpacing: Style.spacing.controlGap
            Repeater {
              model: [
                { k: "today", label: "Today", icon: "󰃭", n: win.todayCount },
                { k: "scheduled", label: "Scheduled", icon: "󰸘", n: win.scheduledCount },
                { k: "all", label: "All", icon: "󰉹", n: win.allCount }
              ]
              delegate: Rectangle {
                required property var modelData
                readonly property bool active: win.kind === modelData.k
                readonly property color tint: modelData.k === "today" ? Color.accent : modelData.k === "scheduled" ? win.urgent : win.muted
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(64)
                radius: Style.cornerRadius
                color: active ? tint : (tileMouse.containsMouse ? win.rowHover : win.tileFill)
                Rectangle {
                  x: Style.spacing.controlPaddingX; y: Style.spacing.controlPaddingX
                  width: Style.space(26); height: width; radius: width / 2
                  color: parent.active ? Util.alpha(win.onTint, 0.25) : parent.tint
                  Text { anchors.centerIn: parent; text: modelData.icon; color: win.onTint; font.pixelSize: Style.font.subtitle }
                }
                Text {
                  anchors.right: parent.right; anchors.top: parent.top
                  anchors.rightMargin: Style.spacing.controlPaddingX; anchors.topMargin: Style.spacing.controlPaddingY
                  text: modelData.n
                  color: parent.active ? win.onTint : win.fg
                  font.family: win.fontFamily; font.pixelSize: Style.font.heading; font.bold: true
                }
                Text {
                  anchors.left: parent.left; anchors.bottom: parent.bottom
                  anchors.leftMargin: Style.spacing.controlPaddingX; anchors.bottomMargin: Style.spacing.controlPaddingY
                  text: modelData.label
                  color: parent.active ? win.onTint : win.muted
                  font.family: win.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
                }
                MouseArea { id: tileMouse; anchors.fill: parent; hoverEnabled: true; onClicked: win.select(modelData.k) }
              }
            }
          }

          Text {
            text: "My Lists"
            color: win.muted
            font.family: win.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
            Layout.topMargin: Style.spacing.labelGap
          }
          ListView {
            id: listList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Style.spacing.xxs
            model: win.sidebarRows
            delegate: Rectangle {
              required property var modelData
              readonly property bool isGroup: modelData.type === "group"
              readonly property var lst: isGroup ? null : modelData.list
              readonly property bool active: !isGroup && win.kind === "list" && win.listName === lst.name
              width: listList.width
              height: Style.spacing.popupRowHeight
              radius: Style.cornerRadius
              color: active ? win.rowSelected : (rowMouse.containsMouse ? win.rowHover : "transparent")
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.controlPaddingX + (modelData.indent ? Style.space(14) : 0)
                anchors.rightMargin: Style.spacing.controlPaddingX
                spacing: Style.spacing.controlGap
                // group: chevron · list: coloured emblem circle
                Text {
                  visible: isGroup
                  text: isGroup && modelData.collapsed ? "󰅂" : "󰅀"
                  color: win.muted
                  font.pixelSize: Style.font.body
                  Layout.preferredWidth: Style.space(20)
                  horizontalAlignment: Text.AlignHCenter
                }
                Rectangle {
                  visible: !isGroup
                  width: Style.space(20); height: width; radius: width / 2
                  color: isGroup ? "transparent" : win.listColor(lst.name)
                  Text { anchors.centerIn: parent; text: isGroup ? "" : win.emblemGlyph(lst); color: win.onTint; font.pixelSize: Style.font.caption }
                }
                Text {
                  Layout.fillWidth: true
                  text: isGroup ? modelData.name : lst.name
                  color: win.fg
                  font.family: win.fontFamily; font.pixelSize: Style.font.body
                  font.bold: isGroup
                  elide: Text.ElideRight
                }
                Text {
                  visible: !isGroup && lst.shared === true
                  text: "󰀎"
                  color: win.muted
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: isGroup ? (modelData.collapsed && modelData.open > 0 ? modelData.open : "") : (lst.open > 0 ? lst.open : "")
                  color: win.muted
                  font.family: win.fontFamily; font.pixelSize: Style.font.body
                }
              }
              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: isGroup ? win.toggleGroup(modelData.name) : win.select("list", lst.name)
              }
            }
          }
          Text {
            text: win.host ? (win.host.online ? (win.host.loading ? "refreshing…" : "") : "gateway offline") : ""
            color: win.host && win.host.online ? win.muted : win.urgent
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
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.spacing.labelGap

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
            spacing: Style.spacing.labelGap
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
              color: win.urgent
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
              height: rowCol.implicitHeight + Style.spacing.rowPaddingX
              opacity: pending ? 0.5 : 1
              Rectangle { anchors.fill: parent; radius: Style.cornerRadius; color: selected ? win.rowSelected : (mm.containsMouse ? win.rowHover : "transparent") }
              Rectangle {   // separator like Reminders' hairlines
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.leftMargin: Style.space(34); height: Style.spacing.hairline
                color: win.hairline
              }
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.rowPaddingX / 2; anchors.rightMargin: Style.spacing.rowPaddingX / 2
                spacing: Style.spacing.controlGap
                Rectangle {   // the tick circle
                  id: circle
                  Layout.alignment: Qt.AlignTop
                  Layout.topMargin: Style.spacing.lg
                  width: Style.space(18); height: width; radius: width / 2
                  color: done ? win.accent : "transparent"
                  border.width: Math.max(1, Style.space(1.5))
                  border.color: done || circleMouse.containsMouse ? win.accent : win.muted
                  Rectangle { anchors.centerIn: parent; width: parent.width - Style.space(6); height: width; radius: width / 2; color: win.accent; visible: !done && circleMouse.containsMouse }
                  Text { anchors.centerIn: parent; text: "✓"; color: win.onTint; visible: done; font.pixelSize: Style.font.caption; font.bold: true }
                  MouseArea { id: circleMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.tick(modelData) }
                }
                ColumnLayout {
                  id: rowCol
                  Layout.fillWidth: true
                  spacing: Style.spacing.xxs
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
                    color: !done && win.isOverdue(modelData) ? win.urgent : win.muted
                    font.family: win.fontFamily; font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }
                Text {   // delete, revealed on hover like Reminders' ⓘ; hidden when the gateway forbids delete
                  text: "✕"
                  visible: mm.containsMouse && !done && win.host && win.host.canDelete
                  color: win.muted
                  font.pixelSize: Style.font.body
                  Layout.alignment: Qt.AlignVCenter
                  MouseArea { anchors.fill: parent; anchors.margins: -Style.spacing.md; cursorShape: Qt.PointingHandCursor; onClicked: win.host.remove(modelData) }
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
            spacing: Style.spacing.controlGap
            Rectangle {
              width: Style.space(18); height: width; radius: width / 2
              color: newField.activeFocus ? win.accent : "transparent"
              border.width: Math.max(1, Style.space(1.5)); border.color: newField.activeFocus ? win.accent : win.muted
              Text { anchors.centerIn: parent; text: "+"; color: newField.activeFocus ? win.onTint : win.muted; font.pixelSize: Style.font.body; font.bold: true }
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
            text: (win.host && !win.host.canDelete) ? "space tick · n new · tab next list · h completed · esc close"
                                                    : "space tick · del delete · n new · tab next list · h completed · esc close"
            color: win.muted
            font.family: win.fontFamily; font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
