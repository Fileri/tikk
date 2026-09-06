import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// tikk — Apple Reminders in the bar.
//
// Reminders live in Apple's private store; a Mac you own answers a confined
// SSH key and runs the verbs (see gateway/). This widget owns the single
// poller and every write; the panel renders its state and asks it to act.
// Left-click = panel · middle-click = refresh.
BarWidget {
  id: root
  moduleName: "fileri.tikk"

  readonly property string home: Quickshell.env("HOME")
  readonly property string shim: home + "/.local/bin/tikk"

  // ---- state
  property string list: ""            // active list name (setting, else first reported)
  property var items: []              // [{id,name,body,due,allday,priority,completed}]
  property bool online: false
  property bool loading: false
  property string lastError: ""
  property var lists: []

  readonly property int openCount: items.length
  readonly property string configuredList: String(setting("list", ""))

  // ---- panel plumbing (same contract as the first-party widgets)
  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    if ("bar" in t) t.bar = root.bar
    if ("settings" in t) t.settings = root.settings
    if ("anchorItem" in t) t.anchorItem = button
    if ("hostWidget" in t) t.hostWidget = root
  }
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  onBarChanged: injectPanel()
  onSettingsChanged: { injectPanel(); if (configuredList !== "" && configuredList !== list) { list = configuredList; refresh() } }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  // ---- poller
  function refresh() {
    if (list === "") { listsProc.running = true; return }
    if (poll.running) return
    loading = true
    poll.command = [shim, "show", list, "--json"]
    poll.running = true
  }
  Process {
    id: listsProc
    command: [root.shim, "lists", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var ls = JSON.parse(text)
          root.lists = ls
          if (root.list === "" && ls.length > 0) root.list = root.configuredList !== "" ? root.configuredList : ls[0]
        } catch (e) {}
      }
    }
    onExited: function(code) {
      root.online = (code === 0)
      if (code !== 0) root.lastError = code === 69 ? "gateway offline" : ("lists failed (exit " + code + ")")
      else if (root.list !== "") Qt.callLater(root.refresh)
    }
  }
  Process {
    id: poll
    property string err: ""
    stderr: StdioCollector { onStreamFinished: poll.err = text.trim().split("\n").pop() || "" }
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var rs = JSON.parse(text)
          if (JSON.stringify(rs) !== JSON.stringify(root.items)) root.items = rs
          root.lastError = ""
        } catch (e) { /* non-zero exit handles it */ }
      }
    }
    onExited: function(code) {
      root.loading = false
      root.online = (code === 0)
      if (code !== 0) root.lastError = code === 69 ? "gateway offline" : (poll.err || ("show failed (exit " + code + ")"))
    }
  }
  Timer {
    interval: root.online ? 30000 : 120000
    running: true; repeat: true; triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- writes: one at a time, then re-poll. Never called from a timer.
  property var actQueue: []
  function act(args) { actQueue = actQueue.concat([args]); pumpAct() }
  function pumpAct() {
    if (actProc.running || actQueue.length === 0) return
    var next = actQueue[0]; actQueue = actQueue.slice(1)
    actProc.command = [shim].concat(next)
    actProc.running = true
  }
  Process {
    id: actProc
    property string err: ""
    stderr: StdioCollector { onStreamFinished: actProc.err = text.trim().split("\n").pop() || "" }
    onExited: function(code) {
      if (code !== 0) root.lastError = actProc.err || ("action failed (exit " + code + ")")
      if (root.actQueue.length > 0) Qt.callLater(root.pumpAct)
      else Qt.callLater(root.refresh)
    }
  }
  function complete(item) {
    items = items.filter(function(r) { return r.id !== item.id })   // optimistic
    act(["complete", list, item.id])
  }
  function remove(item) {
    items = items.filter(function(r) { return r.id !== item.id })
    act(["delete", list, item.id])
  }
  function add(name) {
    var n = String(name).trim()
    if (n === "") return
    items = items.concat([{ id: "pending-" + Date.now(), name: n, body: null, due: null, allday: false, priority: 0, completed: false }])
    act(["add", list, n])
  }
  function switchList(name) { list = name; items = []; refresh() }
  function findByName(name) {
    var n = String(name).trim()
    for (var i = 0; i < items.length; i++) if (items[i].name === n) return items[i]
    return null
  }

  // ---- IPC: `omarchy-shell ipc call fileri.tikk <fn> [arg]` — for keybinds and scripts.
  IpcHandler {
    target: "fileri.tikk"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function add(name: string): string {
      if (!root.online) return "offline"
      if (String(name).trim() === "") return "empty"
      root.add(name); return "queued"
    }
    function complete(name: string): string {
      var r = root.findByName(name)
      if (!r) return "no open reminder named " + name
      root.complete(r); return r.id
    }
    function status(): string {
      return JSON.stringify({ list: root.list, open: root.openCount, online: root.online, error: root.lastError })
    }
  }

  // ---- pill
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰄲 " + root.openCount
    opacity: root.online ? 1.0 : 0.45
    slotSize: Style.bar.statusSlot
    tooltipText: root.online ? (root.list + ": " + root.openCount + " open") : ("tikk: " + root.lastError)
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.LeftButton) root.toggle()
    }
  }
}
