import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Workspace strip: one evenly sized panel per workspace, the focused one
// centered and lit, the rest dimmed either side of it.
//
// Each panel is a scaled model of the workspace rather than an icon: every
// window is captured through hyprland-toplevel-export and drawn at the position
// Hyprland reports for it. Toplevel export renders a window offscreen on
// demand, so workspaces that are not currently displayed still show their real
// contents.
//
// The strip is summoned deliberately and follows the workspace Hyprland has
// actually focused, so there is no selection to commit and nothing it can
// interrupt on its own.
Item {
  id: root

  property var shell: null
  property var pluginRegistry: null
  readonly property string pluginId: "io.github.iryzhkov.omadeck"
  // Handed in by the shell on load, like `shell` and `pluginRegistry`. There is
  // no fallback: until the shell has said where Omarchy lives, no helper runs.
  property string omarchyPath: ""
  // cava.conf ships beside this file, so it is resolved from here rather than
  // from an assumed install location.
  readonly property string cavaConfigPath: String(Qt.resolvedUrl("cava.conf")).replace(/^file:\/\//, "")

  property bool opened: false

  // ------------------------------------------------------ input hardening
  //
  // Everything that reaches this file from outside is bounded before it is
  // parsed, rendered or handed to a process: numbers from shell.json are
  // clamped to finite ranges, strings from helper output and Hyprland IPC are
  // capped, and dashboard ids are checked against the plugin id grammar.

  function finiteNum(value, lo, hi, fallback) {
    var n = Number(value)
    if (!isFinite(n)) return fallback
    return Math.min(hi, Math.max(lo, n))
  }

  function boundText(value, max) {
    var s = String(value === undefined || value === null ? "" : value)
    return s.length > max ? s.slice(0, max) : s
  }

  // The same grammar the plugin registry accepts for an id. Anything else in
  // `dashboard` is dropped rather than used as an object key or a path part.
  readonly property var idPattern: /^[A-Za-z0-9][A-Za-z0-9._-]*$/
  readonly property int maxDashboardCards: 12

  function sanitizeIds(list, fallback) {
    if (!Array.isArray(list)) return fallback
    var out = []
    for (var i = 0; i < list.length && out.length < maxDashboardCards; i++) {
      var id = boundText(list[i], 128)
      if (idPattern.test(id)) out.push(id)
    }
    return out
  }

  // Every helper this plugin spawns goes through BoundedHelper: a fixed
  // absolute executable, a hard deadline, a byte ceiling counted at the
  // producer, and a cleared environment rebuilt with only what the scripts
  // need. A run that fails or overflows publishes nothing, so a truncated or
  // killed read never reaches a card. See BoundedHelper.qml.

  readonly property var helperEnvironment: ({
    PATH: omarchyPath + "/bin:/usr/local/bin:/usr/bin:/bin",
    HOME: Quickshell.env("HOME"),
    USER: Quickshell.env("USER"),
    LANG: Quickshell.env("LANG") || "C.UTF-8",
    XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
    PIPEWIRE_RUNTIME_DIR: Quickshell.env("PIPEWIRE_RUNTIME_DIR") || Quickshell.env("XDG_RUNTIME_DIR"),
    OMARCHY_PATH: omarchyPath
  })

  // Only file, data and web URLs are handed to Image. MPRIS art is usually a
  // file:// path or an https:// cover; anything else stays blank.
  function safeImageUrl(url) {
    var s = boundText(url, 4096)
    return /^(file:\/\/|data:image\/|https?:\/\/)/.test(s) ? s : ""
  }

  // Layout knobs. Each one is read from this plugin's entry in shell.json and
  // clamped, so a hand-edited value cannot size a panel to nothing or to
  // something the compositor refuses:
  //   { "id": "io.github.iryzhkov.omadeck", "sliceWidth": 720, "dwellMs": 4000 }

  // Every panel is the same size at every position. Nothing grows or shrinks as
  // the selection moves; panels slide and change places in the stack.
  readonly property int sliceWidth: finiteNum(pluginSetting("sliceWidth", 660), 160, 4096, 660)
  readonly property int sliceHeight: finiteNum(pluginSetting("sliceHeight", 429), 100, 4096, 429)

  // The stack sits below the middle of the usable area. Everything above it is
  // dashboard, and the offset is what buys those cards their height.
  readonly property int stackOffset: finiteNum(pluginSetting("stackOffset", 56), -2048, 2048, 56)

  // Panels overlap into a fan seen head-on: the focused one is the top layer,
  // the rest sit behind it and peek out to either side. `overlapStep` is how
  // much of each panel stays visible past the one in front of it.
  //
  // `depthDrop` sinks each layer by that many pixels. It is 0 on purpose:
  // anything else makes a panel rise as it takes focus and the one it replaces
  // sink, and that vertical bob is far more distracting than it sounds.
  readonly property int overlapStep: finiteNum(pluginSetting("overlapStep", 140), 10, 2048, 140)
  readonly property int depthDrop: finiteNum(pluginSetting("depthDrop", 0), 0, 512, 0)

  // How many panels either side of the selection are built and captured. Each
  // one is an offscreen render per window, so this is capped low.
  readonly property int captureRadius: finiteNum(pluginSetting("captureRadius", 6), 0, 12, 6)

  // Idle auto-hide in milliseconds. 0 keeps the strip up until it is dismissed,
  // which is the right default for something opened on purpose.
  readonly property int dwellMs: finiteNum(pluginSetting("dwellMs", 0), 0, 600000, 0)

  property color dimColor: Color.background
  property color foreground: Color.imagePicker.text
  property color scrim: Color.imagePicker.scrim
  property color selectedBorder: Color.imagePicker.selectedBorder
  property color unselectedBorder: Color.imagePicker.unselectedBorder

  // [{ wsId, label, monitor, windows: [{ toplevel, x, y, width, height }] }]
  property var entries: []
  property int selectedIndex: 0

  // Hyprland's reserved area for the focused monitor, in logical pixels and in
  // [left, top, right, bottom] order. On a notched MacBook panel the top entry
  // is the camera strip the bar sits in, and an overlay that ignores exclusive
  // zones (this one does, so the stack can use the full height) has to inset
  // itself or its content lands under the cutout.
  readonly property var monitorReserved: {
    var monitor = Hyprland.focusedMonitor
    var raw = monitor ? monitor.lastIpcObject : null
    var reserved = raw ? raw.reserved : null
    return (reserved && reserved.length === 4) ? reserved : [0, 0, 0, 0]
  }
  // Cards sit over whatever is on the desktop, so their fill is forced opaque
  // rather than trusted to the theme's popup alpha: a translucent card over a
  // playing video is unreadable.
  readonly property color cardBackground: Qt.rgba(Color.popups.background.r,
    Color.popups.background.g, Color.popups.background.b, 1)

  readonly property int safeLeft: monitorReserved[0]
  readonly property int safeTop: monitorReserved[1]
  readonly property int safeRight: monitorReserved[2]
  readonly property int safeBottom: monitorReserved[3]

  readonly property int maxDepth: Math.min(captureRadius, Math.max(0, entries.length - 1))

  // Dashboard cards above the stack, in the order given. Configured on this
  // plugin's entry in ~/.config/omarchy/shell.json:
  //   { "id": "io.github.iryzhkov.omadeck",
  //     "dashboard": ["omarchy.clock", "media", "omarchy.weather"] }
  // An empty array turns the row off.
  readonly property int tileHeight: finiteNum(pluginSetting("tileHeight", 112), 60, 600, 112)

  // "panels"   other plugins' own detail panels, the big card you get from the
  //            bar, embedded live. `dashboard` holds plugin ids.
  // "widgets"  real bar-widget plugins, mounted as their bar pills. Plugin ids.
  // "tiles"    this plugin's own cards: clock, weather, media.
  readonly property string dashboardMode: {
    var mode = String(pluginSetting("dashboardMode", "panels"))
    return mode === "widgets" || mode === "tiles" ? mode : "panels"
  }
  readonly property bool hostsWidgets: dashboardMode === "widgets" || dashboardMode === "panels"
  // Bar widgets size themselves off the host's bar height, so this is what
  // makes them legible at overview scale instead of 26px bar scale.
  readonly property int widgetBarSize: finiteNum(pluginSetting("widgetBarSize", 46), 20, 200, 46)
  // Card size for "panels" mode. A plugin panel sizes itself for a popup, so
  // the host gives it a frame rather than asking it how big it wants to be.
  // One geometry for every card in the row. Panels each have their own idea of
  // how big they want to be, and letting each card follow its own leaves the
  // row looking like three unrelated popups; a single size is what makes it
  // read as one dashboard.
  readonly property int panelWidth: finiteNum(pluginSetting("panelWidth", 500), 160, 2048, 500)
  readonly property int panelHeight: finiteNum(pluginSetting("panelHeight", 340), 80, 2048, 340)

  function pluginSetting(name, fallback) {
    var config = (shell && shell.shellConfig) ? shell.shellConfig : root.fileConfig
    var list = config && Array.isArray(config.plugins) ? config.plugins : []

    for (var i = 0; i < list.length; i++) {
      var candidate = list[i]
      if (candidate && typeof candidate === "object"
          && String(candidate.id || "") === pluginId
          && Object.prototype.hasOwnProperty.call(candidate, name)
          && candidate[name] !== undefined)
        return candidate[name]
    }

    return fallback
  }

  // Where those settings are read from depends on the shell. Omarchy up to
  // 4.0.2 handed a plugin the whole shell config as `shell.shellConfig`; 4.0.3
  // narrowed what a plugin receives to a capability-scoped API that carries
  // the bar section and nothing else, so a plugin still reading the old
  // property silently gets every default. The file the shell writes is read
  // instead, and watched, so an edit applies without a restart.
  //
  // It is parsed rather than executed and only ever consulted for this
  // plugin's own entry, and every value taken from it goes through finiteNum,
  // boundText or sanitizeIds above before it reaches geometry, a key or a
  // path. A file that is absent, unreadable, oversized or not valid JSON
  // leaves the settings empty, which is the same as unset: the defaults.
  readonly property string shellConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  readonly property int maxConfigChars: 1000000

  property var fileConfig: ({})

  function parseShellConfig(raw) {
    var text = String(raw || "")
    if (text.length > maxConfigChars || text.trim() === "") return ({})
    try {
      var parsed = JSON.parse(text)
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return ({})
      return parsed
    } catch (e) {
      return ({})
    }
  }

  FileView {
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.fileConfig = root.parseShellConfig(text())
    onFileChanged: root.fileConfig = root.parseShellConfig(text())
    onLoadFailed: root.fileConfig = ({})
  }

  readonly property var dashboardTiles: sanitizeIds(pluginSetting("dashboard", null),
    dashboardMode === "panels" ? ["omarchy.clock", "media", "omarchy.weather"]
      : dashboardMode === "widgets" ? ["omarchy.clock", "omarchy.weather", "omarchy.media"]
      : ["clock", "weather", "media"])

  function widgetSourceFor(id) {
    if (!pluginRegistry || typeof pluginRegistry.entryPointUrl !== "function")
      return ""

    var installed = pluginRegistry.installedPlugins
    var key = String(id)
    if (!installed || typeof installed !== "object"
        || !Object.prototype.hasOwnProperty.call(installed, key))
      return ""

    return pluginRegistry.entryPointUrl(installed[key], "barWidget")
  }

  readonly property var mediaService: shell && typeof shell.serviceFor === "function"
    ? shell.serviceFor("omarchy.media")
    : null
  readonly property bool hasMedia: mediaService ? mediaService.hasMedia === true : false
  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null

  // MprisPlayer recomputes `position` when it is read rather than emitting on a
  // clock, so the progress bar needs its own tick.
  property real mediaPosition: 0

  function formatTime(seconds) {
    var total = Math.max(0, Math.floor(Number(seconds) || 0))
    var minutes = Math.floor(total / 60)
    var rest = total % 60
    return minutes + ":" + (rest < 10 ? "0" : "") + rest
  }

  readonly property var mediaActions: ["previous", "playPause", "next"]

  function mediaAction(action) {
    if (!mediaService || typeof mediaService.runAction !== "function"
        || typeof mediaService.playerKey !== "function")
      return
    if (mediaActions.indexOf(String(action)) === -1)
      return

    mediaService.runAction(String(action), false, mediaService.playerKey(activePlayer))
  }

  Timer {
    interval: 500
    repeat: true
    running: root.opened && root.activePlayer !== null
    triggeredOnStart: true
    onTriggered: root.mediaPosition = root.activePlayer ? root.activePlayer.position : 0
  }

  // Spectrum for the media card. Quickshell can see Pipewire's nodes but not
  // their samples, so the FFT comes from cava: it reads the output monitor and
  // prints one line of bar heights per frame, and this only parses and draws
  // them. No cava installed means no bars and nothing else changes.
  property var spectrum: []
  property bool spectrumUnavailable: false
  // cava.conf asks for 32 bars; a line carrying more than this is not from
  // that config and is dropped whole rather than allocated.
  readonly property int maxSpectrumBars: 64
  readonly property int maxSpectrumLineChars: 1024

  Process {
    id: cavaProc

    running: root.opened && root.hasMedia && !root.spectrumUnavailable
    // Fixed executable and a minimal explicit environment: cava needs the
    // Pipewire socket and nothing from the login profile. It streams for as
    // long as the card is up, so the only deadline is the `running` binding;
    // Quickshell terminates it the moment that goes false.
    command: ["/usr/bin/cava", "-p", root.cavaConfigPath]
    clearEnvironment: true
    environment: root.helperEnvironment

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var text = String(line)
        if (text.length > root.maxSpectrumLineChars)
          return

        var parts = text.split(";")
        if (parts.length > root.maxSpectrumBars + 1)
          return

        var values = []
        for (var i = 0; i < parts.length; i++) {
          if (parts[i] === "")
            continue
          values.push(root.finiteNum(parts[i], 0, 100, 0))
        }

        if (values.length > 0)
          root.spectrum = values
      }
    }

    // Any exit while the card still wants bars means no bars for this summon:
    // a missing binary or a Pipewire refusal would otherwise be respawned for
    // as long as the card is up. The flag is cleared on every summon so a
    // transient failure does not disable the spectrum for the session.
    onExited: function(code) {
      root.spectrum = []
      root.spectrumUnavailable = true
    }
  }

  onOpenedChanged: {
    if (opened)
      spectrumUnavailable = false
    else
      spectrum = []
  }

  // `omarchy weather status` returns "Fremont  ·  Temp 76°F  ·  Wind →11mph",
  // and `omarchy weather icon` the matching nerd-font glyph. Between them
  // that is a hero read-out without duplicating the stock panel's API client.
  property string weatherText: ""
  property string weatherGlyph: ""

  readonly property var weatherParts: String(weatherText).split("·").slice(0, 8).map(function(part) { return part.trim() })
  readonly property string weatherPlace: weatherParts.length > 0 ? weatherParts[0] : ""
  readonly property string weatherTemp: {
    var match = String(weatherText).match(/(-?\d+)\s*°/)
    return match ? match[1] : ""
  }
  readonly property string weatherUnit: {
    var match = String(weatherText).match(/°\s*([CF])/)
    return match ? "°" + match[1] : "°"
  }
  readonly property string weatherWind: {
    var match = String(weatherText).match(/Wind\s*\D*([\d.]+)\s*(\S+)/)
    return match ? match[1] + " " + match[2] : ""
  }

  function monitorForWorkspace(workspace) {
    return workspace && workspace.monitor ? workspace.monitor : Hyprland.focusedMonitor
  }

  // Window rectangles in monitor-local logical pixels, from the same
  // `hyprctl clients` payload the bar reads. Absolute coordinates include the
  // monitor's offset in the layout, so subtract it.
  function windowsFor(workspace, monitor) {
    var out = []
    if (!workspace || !monitor)
      return out

    var toplevels = workspace.toplevels ? workspace.toplevels.values : []

    for (var i = 0; i < toplevels.length; i++) {
      var handle = toplevels[i]
      if (!handle || !handle.wayland)
        continue

      var raw = handle.lastIpcObject || {}
      var at = Array.isArray(raw.at) && raw.at.length === 2 ? raw.at : [monitor.x, monitor.y]
      var size = Array.isArray(raw.size) && raw.size.length === 2 ? raw.size : [monitor.width, monitor.height]
      var width = finiteNum(size[0], 0, 32768, 0)
      var height = finiteNum(size[1], 0, 32768, 0)
      if (width <= 0 || height <= 0)
        continue

      out.push({
        toplevel: handle.wayland,
        x: finiteNum(at[0], -32768, 32768, 0) - monitor.x,
        y: finiteNum(at[1], -32768, 32768, 0) - monitor.y,
        width: width,
        height: height
      })

      if (out.length >= maxWindowsPerWorkspace)
        break
    }

    return out
  }

  // Each captured window is an offscreen render, so a workspace stops at this
  // many; the rest are the ones underneath anyway.
  readonly property int maxWindowsPerWorkspace: 64
  readonly property int maxWorkspaces: 64

  // Occupied workspaces on the focused monitor, plus wherever we are right now
  // even when it is empty. That is the set `workspace e+1` walks, so the strip
  // and SUPER+TAB agree on what counts as skippable.
  function buildEntries() {
    Hyprland.refreshToplevels()

    var focusedMonitor = Hyprland.focusedMonitor
    var focusedWorkspace = Hyprland.focusedWorkspace
    var values = Hyprland.workspaces.values
    var built = []

    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (!workspace || workspace.id <= 0)
        continue

      var monitor = monitorForWorkspace(workspace)
      if (focusedMonitor && monitor && monitor.id !== focusedMonitor.id)
        continue

      var occupied = workspace.toplevels && workspace.toplevels.values.length > 0
      var current = focusedWorkspace && workspace.id === focusedWorkspace.id
      if (!occupied && !current)
        continue

      built.push({
        wsId: workspace.id,
        label: workspace.name && workspace.name !== String(workspace.id)
          ? boundText(workspace.name, 128)
          : "Workspace " + workspace.id,
        monitor: monitor,
        windows: windowsFor(workspace, monitor)
      })

      if (built.length >= maxWorkspaces)
        break
    }

    built.sort(function(left, right) { return left.wsId - right.wsId })

    root.entries = built
    syncSelection(false)
  }

  function indexOfWorkspace(wsId) {
    for (var i = 0; i < entries.length; i++)
      if (entries[i].wsId === wsId)
        return i

    return -1
  }

  function screenForMonitor(monitor) {
    if (!monitor)
      return null

    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === monitor.name)
        return screens[i]

    return null
  }

  // Point the strip at whatever Hyprland has focused. Entries are rebuilt only
  // when the focused workspace is missing from them, because replacing the
  // array tears down every ScreencopyView and rebuilds it, which flickers and
  // costs an offscreen render per window.
  function syncSelection(allowRebuild) {
    var focused = Hyprland.focusedWorkspace
    if (!focused)
      return

    var index = indexOfWorkspace(focused.id)
    if (index < 0 && allowRebuild !== false) {
      buildEntries()
      index = indexOfWorkspace(focused.id)
    }

    if (index >= 0)
      root.selectedIndex = index
  }

  // Every workspace change, from wherever it came: a keybinding, a click in the
  // bar, a window pulling focus, or this strip's own jumpTo. Reports whether
  // the strip was on screen to take it.
  //
  // This used to be driven by the plugin's service half, which reached the
  // strip through the shell's callIfLoaded(). Omarchy 4.0.3 narrowed what a
  // plugin receives to a capability-scoped API with no way to call into
  // another instance, so the strip listens to Hyprland itself. It is the same
  // signal either way, one hop shorter, and it works on every shell version.
  function follow() {
    if (!opened)
      return "closed"

    syncSelection(true)
    restartDwell()
    return "ok"
  }

  Connections {
    target: Hyprland

    function onFocusedWorkspaceChanged() { root.follow() }
  }

  function jumpTo(index) {
    var entry = entries[index]
    if (!entry)
      return

    // The id came from Hyprland, but it is about to go back into a dispatch
    // string, so only a positive integer is allowed through.
    var wsId = Number(entry.wsId)
    if (!Number.isInteger(wsId) || wsId <= 0)
      return

    restartDwell()

    // This Hyprland fork parses dispatch arguments as Lua, so the plain
    // `workspace 3` form does not survive the trip. Same expression the bar's
    // workspace widget uses. The switch comes back to us through follow().
    Hyprland.dispatch("hl.dsp.focus({ workspace = \"" + wsId + "\" })")
  }

  function restartDwell() {
    if (dwellMs > 0)
      dwellTimer.restart()
  }

  function hideSelf() {
    if (!opened)
      return

    opened = false
    dwellTimer.stop()
    stopHelpers()

    if (shell && typeof shell.hide === "function")
      shell.hide(pluginId)
  }

  // Explicit teardown for every helper that may still be running: closing the
  // overview, and the plugin being unloaded, both end them rather than leaving
  // a fetch to finish on its own. Setting `running` false sends TERM to the
  // timeout wrapper, which forwards it to the helper's process group and
  // escalates to KILL after two seconds; cava's own `running` binding has
  // already gone false by the time this is called.
  function stopHelpers() {
    weatherProc.stop()
    weatherIconProc.stop()
  }

  function startWeather() {
    if (omarchyPath === "")
      return

    // start() is a no-op while a run is still in flight, so a refresh that
    // lands on top of a slow fetch does not stack a second one.
    weatherProc.start()
    weatherIconProc.start()
  }

  Component.onDestruction: stopHelpers()

  // Shell lifecycle. `omarchy-shell shell toggle <id>` drives both of these.
  function open(payload) {
    buildEntries()
    if (entries.length === 0)
      return

    opened = true
    restartDwell()

    if (dashboardTiles.indexOf("weather") !== -1)
      startWeather()
  }

  function close() {
    hideSelf()
  }

  // The weather is a shell-out to Omarchy's own scripts, so it is fetched
  // when the strip opens and refreshed only while it stays up. Both run from
  // the path the shell handed over, under the helper wrapper: a 15 second
  // deadline (the scripts' own curl timeouts are 4 and 3 seconds) and a byte
  // ceiling at the producer, so the collector can never hold more than that.
  BoundedHelper {
    id: weatherProc
    executable: root.omarchyPath + "/bin/omarchy-weather-status"
    seconds: 15
    maxBytes: 256
    maxChars: 256
    environment: root.helperEnvironment
    onReady: function(text) { root.weatherText = text }
  }

  BoundedHelper {
    id: weatherIconProc
    executable: root.omarchyPath + "/bin/omarchy-weather-icon"
    seconds: 15
    maxBytes: 64
    maxChars: 16
    environment: root.helperEnvironment
    onReady: function(text) { root.weatherGlyph = text }
  }

  Timer {
    id: weatherTimer
    interval: 600000
    repeat: true
    running: root.opened && root.dashboardTiles.indexOf("weather") !== -1
    onTriggered: root.startWeather()
  }

  Timer {
    id: clockTimer
    interval: 1000
    repeat: true
    running: root.opened && root.dashboardTiles.indexOf("clock") !== -1
    onTriggered: root.now = new Date()
  }

  property var now: new Date()

  Timer {
    id: dwellTimer
    interval: Math.max(1, root.dwellMs)
    onTriggered: root.hideSelf()
  }

  // ------------------------------------------------------------ dashboard tiles
  //
  // Chrome and typography follow the stock weather panel
  // ($OMARCHY_PATH/shell/plugins/panels/weather/Panel.qml): a rounded popup
  // card, an oversized hero read-out on the left, and a column of dim
  // letter-spaced capitals over normal-weight values on the right.

  // Stand-in for the bar host that bar widgets expect to be mounted in. It
  // answers the geometry, colours and coordinator calls they read, and reports
  // a taller `barSize` so a widget draws at overview scale rather than 26px
  // bar scale. Popout and tooltip calls are accepted and dropped: those belong
  // to a real bar surface, and there is not one here.
  QtObject {
    id: hostBar

    property string position: "top"
    readonly property bool vertical: false
    property int barSize: root.widgetBarSize
    readonly property int sizeHorizontal: root.widgetBarSize
    property string fontFamily: Style.font.resolvedFamily
    property color themeForeground: Color.bar.text
    property color foreground: Color.bar.text
    property color barForeground: Color.bar.text
    property color background: "transparent"
    property color urgent: Color.bar.active
    property var shell: root.shell
    property var activePopout: null
    property var iconSlot: null
    property var statusSlot: null
    property var clickTargets: null
    property var layoutConfig: ({})

    // Same contract as the real bar's run(): the widget hands over a command
    // line of its own and the shell runs it. Only a string of sane length is
    // accepted, the way the bar accepts it.
    function run(command) {
      if (typeof command !== "string" || command === "" || command.length > 4096)
        return
      Util.execDetached(command)
    }
    function showTooltip() {}
    function hideTooltip() {}
    function requestPopout() {}
    function releasePopout() {}
    function switchPanelFrom() {}
    function moduleWidgets(name) { return [] }
    function targetBelongsToWindow() { return false }
  }

  component Tile: Rectangle {
    default property alias content: tileBody.data

    implicitWidth: tileBody.implicitWidth + Style.space(40)
    height: root.tileHeight
    radius: Style.cornerRadius
    color: Color.popups.background
    border.color: Util.alpha(Color.popups.border, 0.55)
    border.width: 1

    Row {
      id: tileBody
      anchors.centerIn: parent
      spacing: Style.space(20)
    }

    MouseArea { anchors.fill: parent; onClicked: {} }
  }

  // A dim, letter-spaced caption over a normal-weight value. The stock panel's
  // FEELS / WIND / HUMID columns are built the same way.
  component Stat: Column {
    property string label: ""
    property string value: ""

    spacing: Style.space(4)

    Text {
      text: parent.label.toUpperCase()
      textFormat: Text.PlainText
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.resolvedFamily
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 1
    }

    Text {
      text: parent.value
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.resolvedFamily
      font.pixelSize: Style.font.title
    }
  }

  component Hero: Row {
    property string value: ""
    property string unit: ""

    spacing: Style.space(2)

    Text {
      id: heroValue
      text: parent.value
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.resolvedFamily
      // Deliberately outside the Style.font.* scale, as in the stock panel.
      font.pixelSize: 52
      font.bold: true
    }

    Text {
      text: parent.unit
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.resolvedFamily
      font.pixelSize: Style.font.display
      anchors.top: heroValue.top
      anchors.topMargin: Style.space(8)
      visible: text !== ""
    }
  }

  Component {
    id: clockTile

    Tile {
      Hero {
        anchors.verticalCenter: parent.verticalCenter
        value: Qt.formatDateTime(root.now, "HH:mm")
      }

      Stat {
        anchors.verticalCenter: parent.verticalCenter
        label: Qt.formatDateTime(root.now, "dddd")
        value: Qt.formatDateTime(root.now, "d MMMM")
      }
    }
  }

  Component {
    id: weatherTile

    Tile {
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.weatherGlyph
        textFormat: Text.PlainText
        color: root.foreground
        font.family: Style.font.resolvedFamily
        font.pixelSize: 52
        visible: text !== ""
      }

      Hero {
        anchors.verticalCenter: parent.verticalCenter
        value: root.weatherTemp || "—"
        unit: root.weatherTemp ? root.weatherUnit : ""
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(12)
        visible: root.weatherPlace !== ""

        Row {
          spacing: Style.space(6)

          Text {
            // nf-fa-map_marker, the glyph the stock panel puts on its location.
            text: "\uf041"
            color: Qt.darker(root.foreground, 1.4)
            font.family: Style.font.resolvedFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: root.weatherPlace.toUpperCase()
            textFormat: Text.PlainText
            color: Qt.darker(root.foreground, 1.4)
            font.family: Style.font.resolvedFamily
            font.pixelSize: Style.font.body
            font.letterSpacing: 1
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Stat {
          label: "Wind"
          value: root.weatherWind
        }
      }
    }
  }

  Component {
    id: mediaTile

    Tile {
      Image {
        anchors.verticalCenter: parent.verticalCenter
        width: 64
        height: 64
        source: root.safeImageUrl(root.mediaService ? root.mediaService.artUrl : "")
        sourceSize.width: 128
        sourceSize.height: 128
        fillMode: Image.PreserveAspectCrop
        smooth: true
        visible: source !== ""
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Text {
          text: "NOW PLAYING"
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
        }

        Text {
          text: root.boundText(root.mediaService ? root.mediaService.title : "", 512)
          textFormat: Text.PlainText
          color: root.foreground
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
          width: Math.min(implicitWidth, 320)
        }

        Text {
          text: root.boundText(root.mediaService ? root.mediaService.artist : "", 512)
          textFormat: Text.PlainText
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: Math.min(implicitWidth, 320)
          visible: text !== ""
        }
      }
    }
  }

  // Media player card. Omarchy ships an MPRIS service and a bar pill but no
  // panel, so this is the one card in the row with no plugin panel behind it.
  // Typography follows the embedded panels so it does not read as a guest.
  Component {
    id: mediaPanel

    Item {
      id: mediaRoot

      readonly property var player: root.activePlayer
      readonly property bool playing: player ? player.isPlaying === true : false
      // A live stream reports a length in the trillions of seconds; anything
      // past a day is taken as "no length" so the progress row hides itself
      // rather than showing a nonsense duration.
      readonly property real length: {
        var reported = player && player.lengthSupported ? Number(player.length) : 0
        return isFinite(reported) && reported > 0 && reported <= 86400 ? reported : 0
      }
      readonly property real progress: length > 0 ? Math.min(1, Math.max(0, root.mediaPosition / length)) : 0

      Text {
        anchors.centerIn: parent
        visible: !root.hasMedia
        text: "NOTHING PLAYING"
        color: Qt.darker(root.foreground, 1.4)
        font.family: Style.font.resolvedFamily
        font.pixelSize: Style.font.body
        font.letterSpacing: 1
      }

      Column {
        id: mediaContent

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)
        visible: root.hasMedia

        Row {
          width: parent.width
          spacing: Style.space(14)

          Rectangle {
            id: artFrame
            width: 104
            height: 104
            radius: Style.cornerRadius
            color: Util.alpha(root.foreground, 0.08)
            clip: true

            Image {
              anchors.fill: parent
              source: root.safeImageUrl(mediaRoot.player ? mediaRoot.player.trackArtUrl : "")
              sourceSize.width: 208
              sourceSize.height: 208
              fillMode: Image.PreserveAspectCrop
              smooth: true
            }

            Text {
              anchors.centerIn: parent
              // nf-md-music
              text: "󰝚"
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.resolvedFamily
              font.pixelSize: 34
              visible: root.safeImageUrl(mediaRoot.player ? mediaRoot.player.trackArtUrl : "") === ""
            }
          }

          Column {
            width: parent.width - artFrame.width - Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(5)

            Text {
              width: parent.width
              text: (mediaRoot.player && mediaRoot.player.identity
                ? root.boundText(mediaRoot.player.identity, 128)
                : "Now playing").toUpperCase()
              textFormat: Text.PlainText
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.resolvedFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.boundText(root.mediaService ? root.mediaService.title : "", 512)
              textFormat: Text.PlainText
              color: root.foreground
              font.family: Style.font.resolvedFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.boundText(root.mediaService ? root.mediaService.artist : "", 512)
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.75
              font.family: Style.font.resolvedFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              visible: text !== ""
            }
          }
        }

        // Transport and progress share one row so the spectrum below can have
        // the rest of the card to itself.
        Item {
          width: parent.width
          height: 38

          Row {
            id: transportRow

            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Repeater {
              // Literal glyphs rather than escapes, the way the stock media
              // widget writes them: nf-md-skip_previous, nf-md-pause /
              // nf-md-play, nf-md-skip_next.
              model: [
                { glyph: "󰒮", action: "previous", size: Style.font.heading },
                { glyph: mediaRoot.playing ? "󰏤" : "󰐊", action: "playPause", size: 26 },
                { glyph: "󰒭", action: "next", size: Style.font.heading }
              ]

              // Each control is a fixed box with its glyph centred. Laying the
              // glyphs out directly top-aligns them in the Row, and the play
              // glyph is larger than its neighbours, so it sat low.
              delegate: Item {
                id: transport

                required property var modelData

                width: 34
                height: 34

                Text {
                  anchors.centerIn: parent
                  text: transport.modelData.glyph
                  color: root.foreground
                  font.family: Style.font.resolvedFamily
                  font.pixelSize: transport.modelData.size
                  opacity: transportHover.hovered ? 1 : 0.8
                }

                HoverHandler { id: transportHover }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.mediaAction(transport.modelData.action)
                }
              }
            }
          }

          // Hidden rather than shown empty for a player that reports no track
          // length, which is most web players.
          Column {
            anchors.left: transportRow.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(5)
            visible: mediaRoot.length > 0

            Rectangle {
              width: parent.width
              height: 4
              radius: 2
              color: Util.alpha(root.foreground, 0.18)

              Rectangle {
                width: parent.width * mediaRoot.progress
                height: parent.height
                radius: parent.radius
                color: root.selectedBorder
              }
            }

            Item {
              width: parent.width
              height: elapsed.implicitHeight

              Text {
                id: elapsed
                text: root.formatTime(root.mediaPosition)
                color: Qt.darker(root.foreground, 1.4)
                font.family: Style.font.resolvedFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.right: parent.right
                text: root.formatTime(mediaRoot.length)
                color: Qt.darker(root.foreground, 1.4)
                font.family: Style.font.resolvedFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      // The spectrum owns whatever height the card has left under the content,
      // with nothing drawn over it.
      Item {
        id: spectrumStrip

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: mediaContent.bottom
        anchors.topMargin: Style.space(10)
        anchors.bottom: parent.bottom
        visible: root.hasMedia && root.spectrum.length > 0
        clip: true

        readonly property int count: root.spectrum.length
        readonly property real gap: 3
        readonly property real barWidth: count > 0
          ? Math.max(1, (width - gap * (count - 1)) / count)
          : 0

        Repeater {
          model: spectrumStrip.count

          delegate: Rectangle {
            required property int index

            readonly property real level: Math.min(1, Math.max(0, (root.spectrum[index] || 0) / 100))

            x: index * (spectrumStrip.barWidth + spectrumStrip.gap)
            width: spectrumStrip.barWidth
            height: Math.max(2, spectrumStrip.height * level)
            y: spectrumStrip.height - height
            radius: 1
            color: root.selectedBorder
            // Loud bars read brighter as well as taller, so a quiet passage
            // stays legible instead of flattening into a grey line.
            opacity: 0.3 + 0.45 * level
          }
        }
      }
    }
  }

  PanelWindow {
    id: panel

    visible: root.opened && root.entries.length > 0
    screen: root.screenForMonitor(Hyprland.focusedMonitor)
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-omadeck"
    WlrLayershell.layer: WlrLayer.Overlay
    // Never take focus. The workspace keys stay with Hyprland and with whatever
    // window is underneath. Embedded plugin panels never open their own popup
    // window, so nothing here needs a focus grab.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.hideSelf()
    }

    // Everything lives inside the screen's usable area, and the stack is
    // pinned to the middle of that rather than the middle of the output, so
    // the notch never eats a card and the gallery still reads as centred.
    Item {
      id: card

      anchors.fill: parent
      anchors.leftMargin: root.safeLeft + Style.space(8)
      anchors.topMargin: root.safeTop + Style.space(8)
      anchors.rightMargin: root.safeRight + Style.space(8)
      anchors.bottomMargin: root.safeBottom + Style.space(8)

      Row {
        id: dashboardRow

        anchors.bottom: viewport.top
        anchors.bottomMargin: Style.space(34)
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(12)
        visible: root.dashboardTiles.length > 0

        Repeater {
          model: root.hostsWidgets ? [] : root.dashboardTiles

          delegate: Loader {
            required property var modelData

            // A collapsed tile (media with nothing playing) must leave the Row
            // entirely, or its spacing still shifts the row off centre. This
            // reads the data, never `item.visible`: an Item reports its parent's
            // effective visibility, so a Loader bound to its own item's
            // visibility latches itself off and never comes back.
            visible: modelData !== "media" || root.hasMedia
            height: root.tileHeight
            sourceComponent: modelData === "clock" ? clockTile
              : modelData === "weather" ? weatherTile
              : modelData === "media" ? mediaTile
              : null
          }
        }

        // A plugin's own detail panel, its content lifted out of the popup
        // window it would normally open. See PanelHost.qml.
        Repeater {
          model: root.dashboardMode === "panels" ? root.dashboardTiles : []

          delegate: Rectangle {
            id: dashboardCard

            required property var modelData

            // Anything that is not a plugin id is one of this plugin's own
            // cards. Only media so far, because Omarchy ships no media panel.
            readonly property bool ownCard: String(modelData) === "media"

            visible: ownCard || !cardContent.item || cardContent.item.unembeddable !== true
            width: root.panelWidth
            // Uniform, and never taller than the room left above the stack:
            // the stack owns the middle of the screen.
            // The stack owns the middle of the screen; the offset that pushes
            // it down is exactly the extra room these cards get.
            height: Math.min(root.panelHeight,
              (card.height - root.sliceHeight) / 2 + root.stackOffset - Style.space(48))
            radius: Style.cornerRadius
            color: root.cardBackground
            border.color: Util.alpha(Color.popups.border, 0.55)
            border.width: 1

            Loader {
              id: cardContent

              anchors.fill: parent
              anchors.margins: Style.space(14)
              sourceComponent: dashboardCard.ownCard ? mediaPanel : embeddedPanel
            }

            Component {
              id: embeddedPanel

              PanelHost {
                pluginId: String(dashboardCard.modelData)
                bar: hostBar
                pluginRegistry: root.pluginRegistry
              }
            }
          }
        }

        // Real bar widgets, each dropped into the same card chrome so the row
        // still reads as part of the overview.
        Repeater {
          model: root.dashboardMode === "widgets" ? root.dashboardTiles : []

          delegate: Rectangle {
            required property var modelData

            visible: widgetLoader.status === Loader.Ready
            // Same width as every other card in the row, rather than each pill's
            // own, so the row stays a row of equal cards in this mode too.
            width: root.panelWidth
            height: root.widgetBarSize + Style.space(24)
            radius: Style.cornerRadius
            color: root.cardBackground
            border.color: Util.alpha(Color.popups.border, 0.55)
            border.width: 1

            Loader {
              id: widgetLoader

              anchors.centerIn: parent
              height: root.widgetBarSize
              // Mounted only while the overview is up. A plugin's detail panel
              // is its own popup window, so leaving the widget alive would
              // leave that panel on screen after the overview closes.
              active: root.opened
              source: root.widgetSourceFor(parent.modelData)

              // The bar host injects these three into every widget slot; a
              // widget mounted anywhere else has to be handed the same set.
              onLoaded: {
                if (!item)
                  return
                if ("bar" in item) item.bar = hostBar
                if ("moduleName" in item) item.moduleName = String(parent.modelData)
                if ("settings" in item) item.settings = ({})
                if ("shell" in item) item.shell = root.shell
              }
            }

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.NoButton
            }
          }
        }
      }

      Item {
        id: viewport

        anchors.centerIn: parent
        anchors.verticalCenterOffset: root.stackOffset
        width: Math.min(parent.width, root.sliceWidth + 2 * root.maxDepth * root.overlapStep + 80)
        height: root.sliceHeight + root.maxDepth * root.depthDrop
        clip: true

        // Swallow clicks that land between panels so only the backdrop
        // dismisses. Declared before the panels so it stays under them.
        MouseArea { anchors.fill: parent; onClicked: {} }

        // Panels are positioned individually rather than by sliding one
        // container, because each panel's place in the stack changes at the
        // same moment as its offset, and the two have to move together.
        Item {
          id: strip

          anchors.fill: parent

          Repeater {
            model: root.entries.length

            delegate: Item {
              id: slice

              required property int index

              readonly property var entry: root.entries[index]
              readonly property int relativeIndex: index - root.selectedIndex
              readonly property int depth: Math.abs(relativeIndex)
              readonly property bool selected: relativeIndex === 0
              readonly property bool nearby: depth <= root.captureRadius

              // Once a panel has been captured, keep the capture alive. Tearing
              // a toplevel-export session down and rebuilding it as the
              // selection moves is both slow and visibly flickery.
              property bool captureActivated: nearby
              onNearbyChanged: if (nearby) captureActivated = true

              visible: nearby
              x: (strip.width - root.sliceWidth) / 2 + relativeIndex * root.overlapStep
              y: depth * root.depthDrop
              z: root.captureRadius - depth
              width: root.sliceWidth
              height: root.sliceHeight

              Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
              Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

              Rectangle {
                anchors.fill: parent
                color: root.dimColor
                clip: true

                // The workspace at monitor scale, cropped to cover the panel,
                // so window positions stay true instead of being stretched.
                Item {
                  id: stage

                  readonly property var monitor: slice.entry ? slice.entry.monitor : null
                  // Hyprland reports monitors in physical pixels and window
                  // rects in logical ones, so the stage has to be the logical
                  // size or every window lands scaled down inside a margin.
                  readonly property real monitorScale: monitor && monitor.scale > 0 ? monitor.scale : 1
                  readonly property real monitorWidth: monitor && monitor.width > 0 ? monitor.width / monitorScale : 1920
                  readonly property real monitorHeight: monitor && monitor.height > 0 ? monitor.height / monitorScale : 1080
                  readonly property real coverScale: Math.max(parent.width / monitorWidth, parent.height / monitorHeight)

                  width: monitorWidth * coverScale
                  height: monitorHeight * coverScale
                  anchors.centerIn: parent

                  Repeater {
                    model: slice.captureActivated && slice.entry ? slice.entry.windows.length : 0

                    delegate: Item {
                      id: windowSlot

                      required property int index

                      // Not `data`: Item already owns that name as its default
                      // property, and shadowing it breaks child assignment.
                      readonly property var spec: slice.entry.windows[index]

                      x: spec.x * stage.coverScale
                      y: spec.y * stage.coverScale
                      width: spec.width * stage.coverScale
                      height: spec.height * stage.coverScale
                      z: index

                      ScreencopyView {
                        anchors.fill: parent
                        captureSource: windowSlot.spec.toplevel
                        // A still frame per summon. Live capture would keep
                        // every offscreen workspace rendering for as long as
                        // the strip is up.
                        live: false
                        paintCursor: false
                      }
                    }
                  }
                }

                Rectangle {
                  anchors.fill: parent
                  // The focused panel is lit; deeper in the stack means
                  // further from the light. Kept light enough that the panel
                  // behind still reads as a workspace rather than a shadow.
                  color: Util.alpha(root.dimColor, slice.selected ? 0 : Math.min(0.62, 0.24 + 0.08 * (slice.depth - 1)))

                  Behavior on color {
                    ColorAnimation { duration: 180 }
                  }
                }
              }

              Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.color: slice.selected ? root.selectedBorder : Util.alpha(root.foreground, 0.45)
                border.width: slice.selected ? 3 : 1
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (slice.selected)
                    root.hideSelf()
                  else
                    root.jumpTo(slice.index)
                }
              }
            }
          }
        }
      }

    }
  }
}
