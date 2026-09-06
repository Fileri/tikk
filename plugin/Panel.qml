import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// tikk panel — one list, tick things off, add new ones.
//   Up/Down move · Enter/click = complete · Delete = delete · a or / = add field
//   Tab = next list · Esc = leave the add field, then close.
// Reads state from the host widget (the single poller) and asks it to act.
Panel {
  id: root
  moduleName: "fileri.tikk"
  manageIpc: false   // the bar widget owns the IPC target

  property var anchorItem: null
  property var hostWidget: null
  readonly property var host: hostWidget
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property int cursor: 0
  readonly property var items: host ? host.items : []
  readonly property int count: items.length

  function open() { cursor = 0; controller.show(); if (host) host.refresh() }
  function moveCursor(dy) {
    if (count === 0) return
    cursor = Math.max(0, Math.min(count - 1, cursor + dy))
    listView.positionViewAtIndex(cursor, ListView.Contain)
  }
  function activateCursor() {
    if (addField.activeFocus) { submitAdd(); return }
    if (count === 0) return
    host.complete(items[cursor])
    cursor = Math.max(0, Math.min(cursor, count - 2))
  }
  function deleteCursor() {
    if (addField.activeFocus || count === 0) return
    host.remove(items[cursor])
    cursor = Math.max(0, Math.min(cursor, count - 2))
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
      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onReturnRequested: root.activateCursor()
      onDeleteRequested: root.deleteCursor()
      onTabRequested: function(direction) { root.nextList(direction) }
      onTextKey: function(t) {
        if (t === "a" || t === "/") addField.forceActiveFocus()
        else if (t === "r") root.host.refresh()
        else if (t === "j") root.moveCursor(1)
        else if (t === "k") root.moveCursor(-1)
      }

      ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: Style.spacing.md

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
            color: root.host && root.host.online ? Color.muted : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Text {
          visible: root.host && root.host.lastError !== ""
          text: root.host ? root.host.lastError : ""
          color: Color.urgent
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
          model: root.items
          spacing: Style.spacing.xs
          delegate: Rectangle {
            required property var modelData
            required property int index
            readonly property bool selected: index === root.cursor
            readonly property bool pending: String(modelData.id).indexOf("pending-") === 0
            width: listView.width
            height: rowText.implicitHeight + Style.spacing.lg * 2
            radius: Style.space(6)
            color: selected ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10) : "transparent"
            opacity: pending ? 0.5 : 1.0
            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.lg
              anchors.rightMargin: Style.spacing.lg
              spacing: Style.spacing.lg
              Text {
                text: "☐"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                id: rowText
                Layout.fillWidth: true
                text: modelData.name
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.Wrap
              }
              Text {
                visible: text !== ""
                text: (modelData.priority === 1 ? "!!! " : modelData.priority === 5 ? "!! " : modelData.priority === 9 ? "! " : "") + root.fmtDue(modelData)
                color: Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
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
          text: "enter tick · del delete · tab next list · a add · esc close"
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
