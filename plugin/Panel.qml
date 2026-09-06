import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// tikk panel — one list, tick things off, add new ones.
//   Up/Down (j/k) move · Enter/click = complete · Delete = delete · a or / = add field
//   Left/Right (h/l) = previous/next list · Tab = the neighbouring bar panel (Omarchy's
//   convention, so it is not ours to take) · Esc = leave the add field, then close.
// Reads state from the host widget (the single poller) and asks it to act.
Panel {
  id: root
  moduleName: "fileri.tikk"
  manageIpc: false   // the bar widget owns the IPC target

  property var anchorItem: null
  property var hostWidget: null
  readonly property var host: hostWidget
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // theme state tokens, same helpers the first-party panels use
  readonly property color hoverFill: Style.hoverFillFor(fg, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(fg, Color.accent)

  property int cursor: 0
  readonly property var items: host ? host.items : []
  readonly property int count: items.length
  // Reminders.app order: unsectioned first, then sections in the list's order, manual position inside.
  readonly property var sectionNames: {
    if (!host) return []
    for (var i = 0; i < host.lists.length; i++) if (host.lists[i].name === host.list) return host.lists[i].sections || []
    return []
  }
  readonly property var displayRows: {
    var byPos = function(a, b) {
      var pa = a.position === null || a.position === undefined ? 1e9 : a.position
      var pb = b.position === null || b.position === undefined ? 1e9 : b.position
      return pa !== pb ? pa - pb : String(a.name).localeCompare(String(b.name))
    }
    var out = [], names = sectionNames
    var loose = items.filter(function(r) { return !r.section || names.indexOf(r.section) < 0 }).sort(byPos)
    for (var i = 0; i < loose.length; i++) out.push({ type: "reminder", r: loose[i] })
    for (var s = 0; s < names.length; s++) {
      var members = items.filter(function(r) { return r.section === names[s] }).sort(byPos)
      if (members.length === 0) continue
      out.push({ type: "heading", name: names[s] })
      for (i = 0; i < members.length; i++) out.push({ type: "reminder", r: members[i] })
    }
    return out
  }
  function isReminderRow(i) { return i >= 0 && i < displayRows.length && displayRows[i].type === "reminder" }
  function nearestReminderRow(i, dir) { for (var k = i; k >= 0 && k < displayRows.length; k += dir) if (displayRows[k].type === "reminder") return k; return -1 }
  onDisplayRowsChanged: if (!isReminderRow(cursor)) { var n = nearestReminderRow(cursor, 1); cursor = n >= 0 ? n : Math.max(0, nearestReminderRow(cursor, -1)) }

  function open() { cursor = 0; controller.show(); if (host) host.refresh() }
  function moveCursor(dy) {
    if (count === 0) return
    var next = nearestReminderRow(cursor + dy, dy > 0 ? 1 : -1)
    if (next >= 0) cursor = next
    listView.positionViewAtIndex(cursor, ListView.Contain)
  }
  function activateCursor() {
    if (addField.activeFocus) { submitAdd(); return }
    if (isReminderRow(cursor)) host.complete(displayRows[cursor].r)
  }
  function deleteCursor() {
    if (addField.activeFocus || !(host && host.canDelete) || !isReminderRow(cursor)) return
    host.remove(displayRows[cursor].r)
  }
  function submitAdd() {
    var t = addField.text
    addField.text = ""
    if (host && t.trim() !== "") host.add(t)
  }
  function nextList(direction) {
    if (!host) return
    var names = host.listNames()
    if (names.length < 2) return
    var i = names.indexOf(host.list)
    var n = (i + direction + names.length) % names.length
    host.switchList(names[n]); cursor = 0
  }
  function fmtDue(r) {
    if (!r.due) return ""
    return r.allday ? r.due.slice(5, 10) : r.due.slice(5, 16).replace("T", " ")
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addField.activeFocus
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.nextList(dx); else root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onReturnRequested: root.activateCursor()
      onDeleteRequested: root.deleteCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "a" || t === "/" || t === "n") addField.forceActiveFocus()
        else if (t === "r") root.host.refresh()
        else if (t === "j") root.moveCursor(1)
        else if (t === "k") root.moveCursor(-1)
        else if (t === "h") root.nextList(-1)
        else if (t === "l") root.nextList(1)
      }

      ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: Style.spacing.rowGap

        // ---- header: list name, status
        RowLayout {
          Layout.fillWidth: true
          Text {
            text: root.host ? (root.host.list || "tikk") : "tikk"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
            Layout.fillWidth: true
          }
          Text {
            text: !root.host ? "" : (!root.host.online ? "offline" : (root.host.loading ? "…" : root.count + " open"))
            color: root.host && root.host.online ? Color.muted : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Text {
          visible: root.host && root.host.lastError !== ""
          text: root.host ? root.host.lastError : ""
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          Layout.fillWidth: true
        }

        // ---- the list
        ListView {
          id: listView
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(contentHeight, Style.space(420))
          implicitHeight: Layout.preferredHeight
          clip: true
          model: root.displayRows
          spacing: Style.spacing.xxs
          delegate: Rectangle {
            required property var modelData
            required property int index
            readonly property bool isHeading: modelData.type === "heading"
            readonly property var rec: isHeading ? ({}) : modelData.r
            readonly property bool selected: !isHeading && index === root.cursor
            readonly property bool pending: !isHeading && String(rec.id).indexOf("pending-") === 0
            width: listView.width
            height: (isHeading ? headText.implicitHeight : rowText.implicitHeight) + Style.spacing.rowPaddingX
            radius: Style.cornerRadius
            color: selected ? root.selectedFill : (!isHeading && rowMouse.containsMouse ? root.hoverFill : "transparent")
            opacity: pending ? 0.5 : 1.0
            Text {   // section heading
              id: headText
              visible: isHeading
              anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.rowPaddingX / 2
              text: isHeading ? modelData.name : ""
              color: Color.muted
              font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
            }
            RowLayout {
              visible: !isHeading
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.rowPaddingX / 2
              anchors.rightMargin: Style.spacing.rowPaddingX / 2
              spacing: Style.spacing.controlGap
              Text {
                text: "☐"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                id: rowText
                Layout.fillWidth: true
                text: isHeading ? "" : rec.name
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.Wrap
              }
              Text {
                visible: text !== ""
                text: isHeading ? "" : (rec.priority === 1 ? "!!! " : rec.priority === 5 ? "!! " : rec.priority === 9 ? "! " : "") + root.fmtDue(rec)
                color: Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: !isHeading
              enabled: !isHeading
              onEntered: root.cursor = index
              onClicked: { root.cursor = index; root.activateCursor() }
            }
          }
          Text {
            anchors.centerIn: parent
            visible: root.count === 0 && root.host && root.host.online && !root.host.loading
            text: "nothing open"
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // ---- add
        TextField {
          id: addField
          Layout.fillWidth: true
          placeholderText: "add a reminder…  (a)"
          foreground: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          onAccepted: root.submitAdd()
          Keys.onEscapePressed: keyCatcher.forceActiveFocus()
        }

        Text {
          text: "enter tick · ←→ list · a add · esc close" + (root.host && root.host.canDelete ? " · del delete" : "")
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.fillWidth: true
          elide: Text.ElideRight
        }
      }
    }
  }
}
