import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// tikk window — the "actual app", laid out like Reminders.app on the Mac:
// a sidebar with the smart lists (Today, Scheduled, All) and "My Lists" in
// their groups, and a main pane with the list title in its colour, round
// tick circles, notes and due dates, a completed section you can show or
// hide, and a "New Reminder" row at the bottom.
//
// Hosted inside the Omarchy shell (like blip's window) so it shares the bar
// widget's poller and write queue. `hostWidget` is injected by BarWidget.
//
// Keyboard model (the platform convention: Tab between regions, arrows within):
//   opens with focus in the sidebar on the current selection
//   Tab / Shift+Tab   focus sidebar → list → new-reminder field → sidebar
//   ↑ ↓  (j k)        move within the focused region
//   ← →  (h l)        list ⇄ sidebar; on a group header: fold / unfold
//   Enter             sidebar: open the list and focus it · list: tick
//   Space             tick (list)
//   1 2 3             Today, Scheduled, All · 4…9 your lists in sidebar order (also Alt+digit)
//   n  new reminder · c  show/hide completed · g/G  top/bottom · r  refresh · Esc  unwind, then close
// Every visual token comes from the shell theme; no literal colours here.
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
  readonly property color urgent: Color.urgent
  readonly property color onTint: Color.background      // text on an accent-filled surface
  readonly property color rowHover: Style.hoverFillFor(fg, Color.accent)
  readonly property color rowSelected: Style.selectedFillFor(fg, Color.accent)
  readonly property color focusBorder: Style.focusBorderFor(fg, Color.accent)
  readonly property int focusWidth: Math.max(1, Style.focusBorderWidth)
  readonly property color sidebarBg: Style.normalFillFor(fg, Color.accent)
  readonly property color hairline: Util.alpha(fg, 0.08)
  readonly property color tileFill: Util.alpha(fg, 0.07)

  // ---- selection: a smart list or a real list
  property string kind: "today"       // "today" | "scheduled" | "all" | "list"
  property string listName: ""
  property int cursor: 0              // row cursor in the main list
  property bool showDone: false
  // ---- focus: which region the arrows drive
  property string region: "list"      // "sidebar" | "list" | "new"
  property int sideCursor: 0          // index into sideItems
  property var collapsed: ({})

  // ---------------------------------------------------------------- helpers
  function listMeta(name) {
    if (!host) return null
    for (var i = 0; i < host.lists.length; i++) if (host.lists[i].name === name) return host.lists[i]
    return null
  }
  // Per-list colours the way Reminders.app has them: the list's own colour from
  // the Mac when it has one (user data), else the theme accent hue-rotated by
  // the golden angle per list so every theme switch recolours them with it.
  function listColor(name) {
    var m = listMeta(name)
    if (m && m.color) return m.color
    var names = host ? host.listNames() : []
    var i = Math.max(0, names.indexOf(name))
    var a = Color.accent
    var sat = a.hslSaturation < 0.25 ? 0.45 : a.hslSaturation
    var light = Math.min(0.68, Math.max(0.42, a.hslLightness))
    return Qt.hsla((a.hslHue + i * 0.618034) % 1.0, sat, light, 1)
  }
  function smartColor(k) { return k === "today" ? Color.accent : k === "scheduled" ? urgent : muted }
  readonly property color accent: kind === "list" ? listColor(listName) : smartColor(kind)
  readonly property string heading: kind === "today" ? "Today" : kind === "scheduled" ? "Scheduled" : kind === "all" ? "All" : listName
  function emblemGlyph(m) {
    var e = m && m.emblem ? String(m.emblem) : ""
    if (e === "" || e === "default") return "󰉹"
    if (e.length <= 2 || /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(e)) return e   // an emoji emblem
    if (e.indexOf("shopping") === 0) return "󰄐"
    if (e.indexOf("nature") === 0) return "󰌪"
    if (e.indexOf("weather") === 0) return "󰖐"
    return "󰉹"
  }

  // ---- dates
  function startOfToday() { var d = new Date(); d.setHours(0, 0, 0, 0); return d }
  function dueDate(r) { return r.due ? new Date(r.due) : null }
  function isToday(r) {
    var d = dueDate(r); if (!d) return false
    return d < new Date(startOfToday().getTime() + 86400000)   // due today or overdue, as Reminders' Today does
  }
  function isOverdue(r) {
    var d = dueDate(r); if (!d) return false
    return r.allday ? d < startOfToday() : d < new Date()
  }
  function dueLabel(r) {
    var d = dueDate(r); if (!d) return ""
    var days = Math.floor((d - startOfToday()) / 86400000)
    var day = days === 0 ? "Today" : days === 1 ? "Tomorrow" : days === -1 ? "Yesterday"
      : Qt.formatDate(d, days > 1 && days < 7 ? "dddd" : "d MMM yyyy")
    return r.allday ? day : day + ", " + Qt.formatTime(d, "HH:mm")
  }

  // ---------------------------------------------------------- derived models
  readonly property var smartItems: [
    { type: "smart", k: "today", label: "Today", icon: "󰃭", n: todayCount },
    { type: "smart", k: "scheduled", label: "Scheduled", icon: "󰸘", n: scheduledCount },
    { type: "smart", k: "all", label: "All", icon: "󰉹", n: allCount }
  ]
  // sidebar rows: ungrouped lists, then each group header followed by its lists
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
  // one keyboard sequence over the whole sidebar: 3 smart tiles, then the rows
  readonly property var sideItems: smartItems.concat(sidebarRows)
  // digits: 1-3 smart, 4… lists in sidebar order (group headers do not count)
  readonly property var digitTargets: smartItems.concat(sidebarRows.filter(function(r) { return r.type === "list" }))
  function digitFor(name) {   // 1-based digit for a list, 0 if it is beyond 9
    for (var i = 3; i < digitTargets.length && i < 9; i++) if (digitTargets[i].list.name === name) return i + 1
    return 0
  }

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

  // ------------------------------------------------------------- actions
  function select(k, name) {
    kind = k; if (name !== undefined) listName = name
    cursor = 0; showDone = false
    syncSideCursor()
  }
  function syncSideCursor() {   // put the sidebar cursor on the current selection
    for (var i = 0; i < sideItems.length; i++) {
      var it = sideItems[i]
      if ((it.type === "smart" && kind === it.k) || (it.type === "list" && kind === "list" && it.list.name === listName)) { sideCursor = i; return }
    }
  }
  function selectSideItem(i) {
    var it = sideItems[i]; if (!it) return
    if (it.type === "smart") select(it.k)
    else if (it.type === "list") select("list", it.list.name)
    sideCursor = i
  }
  function toggleGroup(name) { var c = JSON.parse(JSON.stringify(collapsed)); c[name] = !(c[name] === true); collapsed = c }
  function setGroup(name, fold) { var c = JSON.parse(JSON.stringify(collapsed)); c[name] = fold; collapsed = c }
  function toggleDone() { if (kind !== "list") return; showDone = !showDone; if (showDone && host) host.loadDone(listName) }

  function focusRegion(r) {
    region = r
    if (r === "new") newField.forceActiveFocus()
    else { newField.focus = false; keyScope.forceActiveFocus() }
  }
  // Entering an empty list has nothing to land on; the only thing to do there
  // is add, so go straight to the new-reminder field (Tab still stops on the list).
  function enterList() { focusRegion(rows.length === 0 ? "new" : "list") }
  function cycleRegion(dir) {
    var order = ["sidebar", "list", "new"]
    focusRegion(order[(order.indexOf(region) + dir + 3) % 3])
  }
  function moveSide(dy) {
    if (sideItems.length === 0) return
    sideCursor = Math.max(0, Math.min(sideItems.length - 1, sideCursor + dy))
    var it = sideItems[sideCursor]
    if (it.type !== "group") selectSideItem(sideCursor)   // sidebars select as you move, like Reminders.app
  }
  function moveList(dy) {
    if (rows.length === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + dy))
    mainList.positionViewAtIndex(cursor, ListView.Contain)
  }
  function moveCursor(dy) { region === "sidebar" ? moveSide(dy) : moveList(dy) }
  function jumpEnd(toEnd) {
    if (region === "sidebar") { sideCursor = toEnd ? sideItems.length - 1 : 0; var it = sideItems[sideCursor]; if (it && it.type !== "group") selectSideItem(sideCursor) }
    else { cursor = toEnd ? Math.max(0, rows.length - 1) : 0; mainList.positionViewAtIndex(cursor, ListView.Contain) }
  }
  function goLeft() {
    if (region === "list") { syncSideCursor(); focusRegion("sidebar"); return }
    var it = sideItems[sideCursor]
    if (it && it.type === "group") setGroup(it.name, true)
    else if (it && it.type === "list" && it.list.group) setGroup(it.list.group, true), syncSideCursorToGroup(it.list.group)
  }
  function goRight() {
    if (region === "sidebar") {
      var it = sideItems[sideCursor]
      if (it && it.type === "group") { if (it.collapsed) setGroup(it.name, false); else enterList() }
      else enterList()
    }
  }
  function syncSideCursorToGroup(name) { for (var i = 0; i < sideItems.length; i++) if (sideItems[i].type === "group" && sideItems[i].name === name) { sideCursor = i; return } }
  function activate() {
    if (region === "sidebar") {
      var it = sideItems[sideCursor]
      if (it && it.type === "group") toggleGroup(it.name)
      else { selectSideItem(sideCursor); enterList() }
    } else if (rows.length === 0 && kind === "list") focusRegion("new")
    else tickCursor()
  }
  function tick(r) { if (!host || String(r.id).indexOf("pending-") === 0) return; if (r.completed) host.uncomplete(r); else host.complete(r) }
  function tickCursor() { if (rows.length > 0) { tick(rows[cursor]); cursor = Math.max(0, Math.min(cursor, rows.length - 2)) } }
  function deleteCursor() { if (region === "list" && rows.length > 0 && host && host.canDelete) { host.remove(rows[cursor]); cursor = Math.max(0, Math.min(cursor, rows.length - 2)) } }
  function jumpDigit(n) { var t = digitTargets[n - 1]; if (!t) return; if (t.type === "smart") select(t.k); else select("list", t.list.name); if (region === "new") focusRegion("list") }
  function submitNew() {
    var t = newField.text; newField.text = ""
    if (t.trim() !== "" && host) host.add(t, targetList)
  }
  function unwind() {
    if (region === "new") { newField.text = ""; focusRegion("list"); return }
    win.visible = false
  }
  // Open with focus in the sidebar, on the current selection: arrows browse
  // lists immediately, Enter or → goes in. Same whether the list is empty or not.
  onVisibleChanged: if (visible) { if (listName === "" && host) listName = host.list; syncSideCursor(); Qt.callLater(function() { syncSideCursor(); focusRegion("sidebar") }) }

  // ------------------------------------------------------------ keys
  FocusScope {
    id: keyScope
    anchors.fill: parent
    focus: true
    Keys.onPressed: function(e) {
      if (newField.activeFocus) return
      var alt = e.modifiers & Qt.AltModifier
      if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) { win.jumpDigit(e.key - Qt.Key_0); e.accepted = true; return }
      if (alt) return
      switch (e.key) {
      case Qt.Key_Escape: win.unwind(); break
      case Qt.Key_Tab: win.cycleRegion(1); break
      case Qt.Key_Backtab: win.cycleRegion(-1); break
      case Qt.Key_Down: case Qt.Key_J: win.moveCursor(1); break
      case Qt.Key_Up: case Qt.Key_K: win.moveCursor(-1); break
      case Qt.Key_Left: case Qt.Key_H: win.goLeft(); break
      case Qt.Key_Right: case Qt.Key_L: win.goRight(); break
      case Qt.Key_Return: case Qt.Key_Enter: win.activate(); break
      case Qt.Key_Space: if (win.region === "list") win.tickCursor(); else win.activate(); break
      case Qt.Key_Delete: case Qt.Key_Backspace: win.deleteCursor(); break
      case Qt.Key_N: case Qt.Key_Plus: win.focusRegion("new"); break
      case Qt.Key_C: win.toggleDone(); break
      case Qt.Key_R: if (win.host) win.host.refresh(); break
      case Qt.Key_G: win.jumpEnd(e.modifiers & Qt.ShiftModifier); break
      default: return
      }
      e.accepted = true
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

          // smart list tiles, 2 per row like Reminders.app; 1 2 3 on the keyboard
          GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Style.spacing.controlGap
            rowSpacing: Style.spacing.controlGap
            Repeater {
              model: win.smartItems
              delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool active: win.kind === modelData.k
                readonly property bool focused: win.region === "sidebar" && win.sideCursor === index
                readonly property color tint: win.smartColor(modelData.k)
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(64)
                radius: Style.cornerRadius
                color: active ? tint : (tileMouse.containsMouse ? win.rowHover : win.tileFill)
                border.width: focused ? win.focusWidth : 0
                border.color: focused ? (active ? win.onTint : win.focusBorder) : "transparent"
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
                Text {   // the digit, as a quiet hint
                  anchors.right: parent.right; anchors.bottom: parent.bottom
                  anchors.rightMargin: Style.spacing.controlPaddingX; anchors.bottomMargin: Style.spacing.controlPaddingY
                  text: index + 1
                  color: parent.active ? Util.alpha(win.onTint, 0.7) : win.muted
                  font.family: win.fontFamily; font.pixelSize: Style.font.caption
                }
                MouseArea { id: tileMouse; anchors.fill: parent; hoverEnabled: true; onClicked: { win.selectSideItem(index); win.focusRegion("sidebar") } }
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
              required property int index
              readonly property int sideIndex: index + 3          // after the three smart tiles
              readonly property bool isGroup: modelData.type === "group"
              readonly property var lst: isGroup ? null : modelData.list
              readonly property bool active: !isGroup && win.kind === "list" && win.listName === lst.name
              readonly property bool focused: win.region === "sidebar" && win.sideCursor === sideIndex
              readonly property int digit: isGroup ? 0 : win.digitFor(lst.name)
              width: listList.width
              height: Style.spacing.popupRowHeight
              radius: Style.cornerRadius
              color: active ? win.rowSelected : (rowMouse.containsMouse ? win.rowHover : "transparent")
              border.width: focused ? win.focusWidth : 0
              border.color: focused ? win.focusBorder : "transparent"
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.controlPaddingX + (modelData.indent ? Style.space(14) : 0)
                anchors.rightMargin: Style.spacing.controlPaddingX
                spacing: Style.spacing.controlGap
                Text {   // group: chevron
                  visible: isGroup
                  text: isGroup && modelData.collapsed ? "󰅂" : "󰅀"
                  color: win.muted
                  font.pixelSize: Style.font.body
                  Layout.preferredWidth: Style.space(20)
                  horizontalAlignment: Text.AlignHCenter
                }
                Rectangle {  // list: coloured emblem circle
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
                Text {   // digit hint for the first nine lists
                  visible: !isGroup && digit >= 4 && digit <= 9
                  text: digit
                  color: win.muted
                  opacity: 0.7
                  font.family: win.fontFamily; font.pixelSize: Style.font.caption
                  Layout.preferredWidth: Style.space(10)
                  horizontalAlignment: Text.AlignRight
                }
              }
              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: { win.sideCursor = sideIndex; if (isGroup) win.toggleGroup(modelData.name); else { win.select("list", lst.name); win.focusRegion("sidebar") } }
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
              readonly property bool selected: index === win.cursor
              readonly property bool focused: selected && win.region === "list"
              readonly property bool pending: String(modelData.id).indexOf("pending-") === 0
              readonly property bool done: modelData.completed === true
              readonly property string sub: [modelData.body || "", win.dueLabel(modelData)].filter(function(x) { return x !== "" }).join("  ·  ")
              width: mainList.width
              height: rowCol.implicitHeight + Style.spacing.rowPaddingX
              opacity: pending ? 0.5 : 1
              Rectangle {
                anchors.fill: parent; radius: Style.cornerRadius
                color: selected ? win.rowSelected : (mm.containsMouse ? win.rowHover : "transparent")
                border.width: focused ? win.focusWidth : 0
                border.color: focused ? win.focusBorder : "transparent"
              }
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
                onClicked: { win.cursor = index; win.focusRegion("list") }
              }
            }
            Rectangle {   // empty state: carries the focus ring so Tab into an empty list is visible
              anchors.centerIn: parent
              width: Math.min(parent.width, emptyCol.implicitWidth + Style.spacing.panelPadding * 2)
              height: emptyCol.implicitHeight + Style.spacing.panelPadding * 2
              radius: Style.cornerRadius
              color: win.region === "list" ? win.rowSelected : "transparent"
              border.width: win.region === "list" ? win.focusWidth : 0
              border.color: win.region === "list" ? win.focusBorder : "transparent"
              visible: win.rows.length === 0 && win.host && win.host.online && !win.host.loading
              Column {
                id: emptyCol
                anchors.centerIn: parent
                spacing: Style.spacing.labelGap
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "No Reminders"
                  color: win.muted
                  font.family: win.fontFamily; font.pixelSize: Style.font.heading
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: win.kind === "list" ? "n or Enter: add one" : "nothing due"
                  color: win.muted
                  font.family: win.fontFamily; font.pixelSize: Style.font.bodySmall
                }
              }
              MouseArea { anchors.fill: parent; onClicked: win.kind === "list" ? win.focusRegion("new") : win.focusRegion("list") }
            }
          }

          // ---- new reminder row (Tab reaches it; n jumps to it)
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.controlGap
            Rectangle {
              width: Style.space(18); height: width; radius: width / 2
              color: newField.activeFocus ? win.accent : "transparent"
              border.width: Math.max(1, Style.space(1.5)); border.color: newField.activeFocus ? win.accent : win.muted
              Text { anchors.centerIn: parent; text: "+"; color: newField.activeFocus ? win.onTint : win.muted; font.pixelSize: Style.font.body; font.bold: true }
              MouseArea { anchors.fill: parent; onClicked: win.focusRegion("new") }
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
              onActiveFocusChanged: if (activeFocus) win.region = "new"
              Keys.onEscapePressed: win.unwind()
              Keys.onTabPressed: win.cycleRegion(1)
              Keys.onBacktabPressed: win.cycleRegion(-1)
            }
          }
          Text {
            text: "tab regions · ↑↓ move · ←→ sidebar/list · enter open/tick · 1-9 jump · n new · c completed · esc close"
                  + (win.host && win.host.canDelete ? " · del delete" : "")
            color: win.muted
            font.family: win.fontFamily; font.pixelSize: Style.font.caption
            Layout.fillWidth: true
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
