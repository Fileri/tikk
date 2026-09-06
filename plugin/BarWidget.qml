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
  property string list: ""            // the pill's list (setting, else first reported)
  property var lists: []              // [{name, open, group, color, emblem, shared}] every list on the Mac
  property var groups: []             // [{name, lists:[names]}] Reminders.app groups, in display order
  property var all: []                // every open reminder across lists [{id,name,body,due,allday,priority,list}]
  property var items: []              // `all` filtered to `list` (what the panel shows)
  property bool online: false
  property bool loading: false
  property string lastError: ""
  property string snapshotJson: ""
  // gateway capabilities from `check --json`: allow_verbs (null = all). Refreshed
  // at start and whenever the gateway comes back online.
  property var allowVerbs: null
  readonly property bool canDelete: allowVerbs === null || allowVerbs.indexOf("delete") >= 0
  readonly property bool canAdd: allowVerbs === null || allowVerbs.indexOf("add") >= 0
  readonly property bool canComplete: allowVerbs === null || allowVerbs.indexOf("complete") >= 0
  Process {
    id: capsProc
    command: [root.shim, "check", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { var c = JSON.parse(text); root.allowVerbs = c.allow_verbs === undefined ? null : c.allow_verbs } catch (e) {}
      }
    }
  }
  function loadCaps() { if (!demo && !capsProc.running) capsProc.running = true }
  onOnlineChanged: if (online) loadCaps()
  Component.onCompleted: loadCaps()
  // completed reminders for one list, loaded on demand by the window
  property string doneList: ""
  property var done: []
  property bool doneLoading: false
  function deriveItems() {
    var l = list
    items = all.filter(function(r) { return r.list === l })
  }

  readonly property int openCount: items.length
  readonly property string configuredList: String(setting("list", ""))
  // Demo mode: `"demo": "/path/to/fixture.json"` in the widget's shell.json
  // entry feeds the poller from a file and turns writes into local no-ops.
  // For screenshots and UI work without a Mac (scripts/demo/fixture.json).
  readonly property string demoPath: String(setting("demo", ""))
  readonly property bool demo: demoPath !== ""
  property var demoDone: ({})

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
    if (poll.running) return
    loading = true
    poll.running = true
  }
  Process {
    id: poll
    command: root.demo ? ["cat", root.demoPath] : [root.shim, "snapshot", "--json"]
    property string err: ""
    stderr: StdioCollector { onStreamFinished: poll.err = text.trim().split("\n").pop() || "" }
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var snap = JSON.parse(text)
          if (text !== root.snapshotJson) {
            root.snapshotJson = text
            root.lists = snap.lists
            root.groups = snap.groups || []
            root.all = snap.reminders
            if (root.demo) root.demoDone = snap.done || {}
            if (root.list === "" && snap.lists.length > 0)
              root.list = root.configuredList !== "" ? root.configuredList : snap.lists[0].name
            root.deriveItems()
            if (root.doneList !== "") root.loadDone(root.doneList)
          }
          root.lastError = ""
        } catch (e) { /* non-zero exit handles it */ }
      }
    }
    onExited: function(code) {
      root.loading = false
      root.online = (code === 0)
      if (code !== 0) root.lastError = code === 69 ? "gateway offline" : (poll.err || ("snapshot failed (exit " + code + ")"))
    }
  }
  function loadDone(listName) {
    doneList = listName
    if (listName === "") { done = []; return }
    if (demo) { done = demoDone[listName] || []; return }
    if (doneProc.running) return
    doneLoading = true
    doneProc.command = [shim, "show", listName, "--done", "--json"]
    doneProc.running = true
  }
  Process {
    id: doneProc
    stdout: StdioCollector {
      onStreamFinished: { try { root.done = JSON.parse(text) } catch (e) { root.done = [] } }
    }
    onExited: root.doneLoading = false
  }
  Timer {
    interval: root.online ? 30000 : 120000
    running: true; repeat: true; triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- writes: one at a time, then re-poll. Never called from a timer.
  property var actQueue: []
  function act(args) { if (demo) return; actQueue = actQueue.concat([args]); pumpAct() }
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
  function dropLocal(item) {   // optimistic removal from every derived view
    all = all.filter(function(r) { return r.id !== item.id })
    done = done.filter(function(r) { return r.id !== item.id })
    deriveItems()
  }
  function complete(item) { if (!canComplete) return; dropLocal(item); act(["complete", item.list || list, item.id]) }
  function uncomplete(item) { dropLocal(item); act(["uncomplete", item.list || list, item.id]) }
  function remove(item) { if (!canDelete) { lastError = "delete is not allowed by the gateway"; return } dropLocal(item); act(["delete", item.list || list, item.id]) }
  function add(name, listName) {
    var n = String(name).trim()
    var l = listName || list
    if (n === "" || l === "") return
    all = all.concat([{ id: "pending-" + Date.now(), name: n, body: null, due: null, allday: false, priority: 0, completed: false, list: l }])
    deriveItems()
    act(["add", l, n])
  }
  function switchList(name) { list = name; deriveItems() }
  function listNames() { return lists.map(function(l) { return l.name }) }
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
    function app(): string { return root.app() }
    function open_list(name: string): string { root.openList(name); return "ok" }
    function refresh(): string { root.refresh(); return "ok" }
    function add(name: string): string {
      if (!root.online) return "offline"
      if (String(name).trim() === "") return "empty"
      root.add(name, root.list); return "queued"
    }
    function complete(name: string): string {
      var r = root.findByName(name)
      if (!r) return "no open reminder named " + name
      root.complete(r); return r.id
    }
    function status(): string {
      return JSON.stringify({ list: root.list, open: root.openCount, online: root.online, error: root.lastError,
                              allow_verbs: root.allowVerbs, can_delete: root.canDelete })
    }
  }

  // ---- the app window: same data, Reminders.app layout. Created on open and
  // destroyed on close (like blip): a hidden FloatingWindow never maps again,
  // and tearing it down cleanly avoids leaving a dead window under the poller.
  Loader {
    id: windowLoader
    active: false
    source: Qt.resolvedUrl("TikkWindow.qml")
    onLoaded: { item.hostWidget = root; item.visible = true; root.refresh() }
  }
  Connections {
    target: windowLoader.item
    ignoreUnknownSignals: true
    function onVisibleChanged() { if (windowLoader.item && !windowLoader.item.visible) Qt.callLater(function() { windowLoader.active = false }) }
  }
  readonly property bool appOpen: windowLoader.active && windowLoader.item !== null && windowLoader.item.visible
  property string pendingList: ""      // list to show when the window comes up (IPC open_list)
  function openList(name) {
    if (appOpen) windowLoader.item.showList(name)
    else { pendingList = name; windowLoader.active = true }
  }
  function app() {
    var wasOpen = appOpen
    if (wasOpen) windowLoader.item.visible = false   // → Connections tears it down
    else windowLoader.active = true
    return wasOpen ? "closing" : "opening"
  }

  // ---- pill: click = panel, double-click = app window, middle = refresh
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  Timer { id: dblClick; interval: 320; onTriggered: root.toggle() }
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰄲 " + root.openCount
    opacity: root.online ? 1.0 : 0.45
    slotSize: Style.bar.statusSlot
    tooltipText: root.online ? (root.list + ": " + root.openCount + " open") : ("tikk: " + root.lastError)
    onPressed: function(b) {
      if (b === Qt.MiddleButton) { root.refresh(); return }
      if (b !== Qt.LeftButton) return
      if (dblClick.running) { dblClick.stop(); root.close(); root.app() }
      else dblClick.start()
    }
  }
}
